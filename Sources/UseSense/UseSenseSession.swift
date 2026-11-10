#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import CoreImage
import UIKit
import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

public final class UseSenseSession: @unchecked Sendable {
    // MARK: - Public Properties

    var onStateChange: ((SessionState) -> Void)?
    var onQualityUpdate: ((ImageQualityReport) -> Void)?
    /// Guided capture: the gate's state (hint, all-pass, fill light, shutter).
    /// Called from the capture queue, at most ~10 Hz unless something the
    /// user sees changed.
    var onGuideUpdate: ((GuidedCaptureUpdate) -> Void)?
    /// Guided capture: scan ring progress (called from the scan task).
    var onScanUpdate: ((ScanProgress) -> Void)?
    /// Guided extra check: what the challenge screen draws (called from the
    /// challenge task, ~20 Hz).
    var onChallengeUpdate: ((ChallengeDisplay) -> Void)?
    /// Inline step-up (suspicion engine): what the scan screen shows while it
    /// runs (RMAS action or Flash Reflection colour).
    var onInlineStepUpUpdate: ((InlineStepUpDisplay) -> Void)?
    /// The contour scan's depth texture (mesh z, smoothed).
    let contourField = ContourDepthField()
    /// COVER-v1: segmentation of the face area on its own queue (gate only).
    let coverSegmenter = FaceCoverSegmenter()
    /// Camera time of the latest frame the guide saw (for the final covered check).
    private var latestGuideFrameTime: TimeInterval = -.infinity
    /// COVER-v1 section 3: the covered-face scores sent with the upload
    /// (guarded by `guideLock`).
    private var coverReport = CoverCheckReport()
    private var coverReportScanning = false

    var previewLayer: AVCaptureVideoPreviewLayer? {
        frameCaptureManager.previewLayer
    }

    // MARK: - Private Properties

    private let config: UseSenseConfig
    /// The integrator's code-set white-label (SDK init config): the highest
    /// layer in session mode.
    var codeAppearance: FlowAppearance? { config.branding?.resolvedAppearance }

    /// Session-mode appearance, field by field: code over the dashboard branding
    /// delivered with the session ("code wins"). The capture UI themes from this
    /// when no Flow runner has already resolved one.
    var brandingAppearance: FlowAppearance? {
        BrandingResolver.resolve(code: codeAppearance, dashboard: sessionData?.branding?.resolvedAppearance)
    }

    /// Called on the main actor once the session's dashboard branding arrives
    /// (session create / token exchange / injection), so a screen that themed
    /// from code alone at load can fold the dashboard layer in underneath.
    var onBrandingAvailable: (@MainActor (FlowAppearance?) -> Void)?

    /// The org lockup for the result header: logo alone when there is one,
    /// the name only without a logo (same rule as the hosted header).
    /// Code (SDK init) logo first, then the session's dashboard branding.
    var brandLogoURL: URL? {
        (config.branding?.logoUrl ?? sessionData?.branding?.logoUrl).flatMap { URL(string: $0) }
    }
    var brandDisplayName: String? { sessionData?.branding?.displayName }

    /// A session handed in by the Flows runner or the hosted page. Its outcome
    /// is settled on the server when it completes, so the result screen offers
    /// no in-place "Try Again" (a Flow's retries follow its own policy).
    var isInjected: Bool { sessionInjected }

    private func publishBranding() {
        USTrace.log(BrandingResolver.describeSources(
            code: codeAppearance,
            dashboard: sessionData?.branding?.resolvedAppearance
        ))
        guard let callback = onBrandingAvailable else { return }
        let appearance = brandingAppearance
        Task { @MainActor in callback(appearance) }
    }
    private let sessionType: SessionType
    private let identityId: String?
    private let externalUserId: String?
    private let metadata: [String: AnyCodableValue]?
    private let clientToken: String?

    private let apiClient: UseSenseAPIClient
    private let eventEmitter: EventEmitter
    private let frameCaptureManager = FrameCaptureManager()
    private let audioCaptureManager = AudioCaptureManager()
    private let frameBuffer: FrameBuffer
    private let qualityAnalyzer = ImageQualityAnalyzer()
    private let metadataBuilder = MetadataBuilder()
    private let challengeResponseBuilder = ChallengeResponseBuilder()
    private let deviceSignalCollector = DeviceSignalCollector()
    private let screenDetectionCollector = ScreenDetectionCollector()

    // v4.1: Face mesh, geometric coherence, suspicion engine
    private let faceMeshManager = FaceMeshManager()
    private let threeDMMFitter = OnDevice3DMMFitter()
    private let verificationPackageBuilder = VerificationPackageBuilder()
    private var suspicionEngine: SuspicionEngine?

    #if canImport(DeviceCheck) && canImport(CryptoKit)
    private let appAttestManager = AppAttestManager()
    #endif

    private var appAttestTask: Task<[String: Any], Never>?

    private var sessionData: SessionData?
    private var sessionStartTime: Date?
    private var storedState: SessionState = .idle
    /// Every state write goes through here. A write from a superseded attempt
    /// (work the watchdog or a retry abandoned, still winding down) is dropped,
    /// so a late failure from the old attempt can never overwrite the new one.
    private var currentState: SessionState {
        get { storedState }
        set {
            if isStaleContext { USTrace.log("state DROPPED (stale attempt): \(newValue.debugName)"); return }
            USTrace.log("state -> \(newValue.debugName)")
            storedState = newValue
            if newValue.isTerminal || newValue.isIdle { watchdog?.disarm() }
            onStateChange?(newValue)
        }
    }

    // MARK: - Fail-safe

    /// The attempt the current task belongs to. Set by `runAttempt`, inherited
    /// by every child task, and compared with `attempt` before a state write.
    @TaskLocal static var attemptToken: Int?
    private let attemptLock = NSLock()
    private var attempt = 0
    private var attemptTasks: [Task<Void, Never>] = []
    private var watchdog: SessionWatchdog?
    var captureBudget = SessionWatchdog.captureBudget
    var uploadBudget = SessionWatchdog.uploadBudget
    /// App Attest is an Apple network call on first use. It must never hold
    /// the upload: past this, the upload goes without it (the server treats a
    /// missing attestation as unavailable, not as a failure).
    static let appAttestWaitSeconds: TimeInterval = 5
    /// Credentials were handed in (Flows / hosted page), so this object cannot
    /// mint a fresh session of its own.
    private var sessionInjected = false
    /// Signals for this session may have reached the server.
    private var uploadAttempted = false
    private var isStarted = false
    private var audioRecordingURL: URL?
    private var captureStartTime: Date?
    private var captureEndTime: Date?
    private var framesDropped: Int = 0
    private var baselineDuration: TimeInterval = 2.0
    private var latestQualityReport: ImageQualityReport?
    private var isCapturingFrames = false
    private var serverMaxFrames: Int?
    private var stepUpResult: StepUpResult?
    /// Server step-up (round 2): set while the requested challenge is captured.
    private var serverStepUp: StepUpInstruction?

    /// A finished capture, kept so a failed upload or completion can be
    /// resumed on the same session ("Retry") instead of recapturing.
    private struct PendingUpload {
        let frames: [Data]
        let metadata: Data
        let audio: Data?
    }
    private var pendingUpload: PendingUpload?
    /// The server accepted this session's signals: a retry only needs /complete.
    private var signalsAccepted = false
    /// One-shot claims for the current attempt (see `claimOnce`).
    private var claims = Set<String>()
    /// The camera has delivered at least one frame since it was (re)started.
    private let cameraLiveLock = NSLock()
    private var cameraLiveFlag = false
    /// How long the capture waits for the camera's first frame.
    var firstFrameBudget: TimeInterval = 20

    // MARK: Guided capture (capture redesign P1)

    /// The guided screen is on unless the integrator turned it off.
    var guidedCapture: Bool { config.options?.guidedCaptureEnabled ?? true }
    /// Gate state; `guide` is fed on the capture queue, read by the scan task.
    private let guideLock = NSLock()
    private var guide = CaptureGuide()
    private var latestGuide = GuideSnapshot.initial
    private var lastGuidePublished: GuidedCaptureUpdate?
    private var lastGuidePublishTime: CFAbsoluteTime = 0
    private var lastFocusTime: CFAbsoluteTime = 0
    private var guideTraceCounter = 0
    private var viewportSize = CGSize(width: 390, height: 844)
    /// The auto start has been asked for from the current align screen.
    private var autoStartRequested = false
    /// First time the align screen showed in this attempt (shutter timer).
    private var alignStartedAt: Date?
    /// Scan windows abandoned after a pause longer than `scanDiscardAfter`.
    private var pausedWindows = 0
    /// The scan was started from the shutter button: long pauses never
    /// discard frames, so shaky hands can still finish.
    private var manualStart = false
    /// Serialises "bank a frame + its mesh" against discarding them, so the
    /// frame/mesh index pairing can never be split by a discard.
    private let bankLock = NSLock()
    static let shutterAfterSeconds: TimeInterval = 20
    static let shutterAfterPausedWindows = 3
    static let scanDiscardAfter: TimeInterval = 1.5
    /// The guided passive scan (capture kit SPEC: ~3 s, as web).
    static let guidedScanDuration: TimeInterval = 3
    static let guidedMaxFps = 12

    // MARK: EVIDENCE-v1 (capture redesign Phase 2)

    /// Host time of the camera's first frame: 0 on the capture clock
    /// (guarded by `latestLock`).
    private var captureClockOrigin: CFTimeInterval?
    /// The colour sequence of this attempt (main thread only).
    private var colourPlayer: ColourSequencePlayer?
    /// The closer step's outcome for this attempt.
    private var closerEvidence: CloserEvidence?
    /// Closer step: while set, a frame banks only when its eye distance (JPEG
    /// width units) reaches this (guarded by `bankLock`).
    private var nearBankThreshold: Double?
    /// The oval's scale; above 1 during the closer step (guarded by `guideLock`).
    private var ovalScale: CGFloat = 1
    /// The screen that tints for the colour sequence (the view model).
    weak var colourTintHost: ColourTintHost?
    /// Closer step display: the oval's scale, and whether the person still
    /// needs to come closer. (1, false) when it ends.
    var onCloserUpdate: ((CGFloat, Bool) -> Void)?
    /// A gate pause restarts the sequence; this many plays at most.
    static let colourMaxRuns = 3
    /// Frames each closer phase needs (EVIDENCE-v1 section 7: 3 or more).
    static let closerPhaseFrames = 3
    /// The closer step gives up after this (section 7: 4 s) and uploads anyway.
    static let closerTimeout: TimeInterval = 4
    /// The face holds still, close enough, this long before near frames bank.
    static let closerSettle: TimeInterval = 0.4
    /// Near frames bank at most this often, so three span about 0.75 s.
    static let closerNearFps = 4
    /// Once close enough in time, this long to settle and bank.
    static let closerHoldBudget: TimeInterval = 3
    /// "Move a little closer" comes back only below this share of the threshold.
    static let closerReleaseShare = 0.95

    static func closerShowsNear(eye: Double, threshold: Double, wasNear: Bool) -> Bool {
        wasNear ? eye >= threshold * closerReleaseShare : eye >= threshold
    }

    /// What this build can do (EVIDENCE-v1 `capability`).
    var evidenceCapability: EvidenceCapability {
        var appAttest = false
        #if canImport(DeviceCheck) && canImport(CryptoKit)
        appAttest = DCAppAttestService.shared.isSupported
        #endif
        return EvidenceCapability.current(meshAvailable: faceMeshManager.available,
                                          guided: guidedCapture, appAttest: appAttest)
    }

    // MARK: Guided extra check (storyboard flows 4 and 5)

    /// The "Two quick steps" primer has been shown for this session.
    private var primerShown = false
    /// What the camera saw for the running challenge (guarded by `guideLock`).
    private var challengeFacePresent = false
    private var challengeYaw: Double?
    private var challengePitch: Double?
    private var challengeHint: GateHint?
    /// The running challenge step's gate rules (guarded by `guideLock`).
    private var challengeRules = ChallengeGateRules.digits
    /// The "Leave verification?" dialog is open: the challenge holds still.
    private var challengeHeld = false
    /// Speak Digits ran on screen: its response goes in the upload.
    private var audioChallengeResponse: [String: Any]?
    /// App Attest fields from round 1, reused by round 2's upload.
    private var attestFieldsCache: [String: Any]?
    /// Test seam: the last round-2 metadata built.
    private(set) var lastRound2MetadataForTesting: Data?
    /// The newest face mesh and camera frame, whether or not frames are being
    /// banked: the inline step-up reads them after the scan has ended.
    private let latestLock = NSLock()
    private var latestMesh: FaceMeshResult?
    private var latestPixelBuffer: CVPixelBuffer?
    private lazy var frameImageContext = CIContext()
    /// The green tick after an extra check.
    static let extraCheckDoneSeconds: TimeInterval = 0.8

    // MARK: - Init

    public convenience init(
        config: UseSenseConfig,
        sessionType: SessionType,
        identityId: String? = nil,
        externalUserId: String? = nil,
        metadata: [String: AnyCodableValue]? = nil,
        clientToken: String? = nil
    ) {
        self.init(
            config: config,
            sessionType: sessionType,
            identityId: identityId,
            externalUserId: externalUserId,
            metadata: metadata,
            clientToken: clientToken,
            eventEmitter: EventEmitter()
        )
    }

    init(
        config: UseSenseConfig,
        sessionType: SessionType,
        identityId: String? = nil,
        externalUserId: String? = nil,
        metadata: [String: AnyCodableValue]? = nil,
        clientToken: String? = nil,
        eventEmitter: EventEmitter
    ) {
        self.config = config
        self.sessionType = sessionType
        self.identityId = identityId
        self.externalUserId = externalUserId
        self.metadata = metadata
        self.clientToken = clientToken
        self.apiClient = UseSenseAPIClient(config: config)
        self.eventEmitter = eventEmitter

        let maxFrames = config.options?.maxFrames ?? 30
        let targetFps = config.options?.targetFps ?? 3
        self.frameBuffer = FrameBuffer(maxFrames: maxFrames, targetFps: targetFps)

        frameCaptureManager.delegate = self

        // Surface real upload progress. The signals request is the only one
        // that carries megabytes, and on a slow uplink it is minutes long;
        // without this the host has no way to tell slow from stuck.
        self.apiClient.onUploadProgress = { [weak self, weak eventEmitter] sent, total in
            guard total > 0 else { return }
            let percent = Int((Double(sent) / Double(total)) * 100)
            // Bytes moving = the upload is alive; push back the stall window.
            self?.watchdog?.kick()
            eventEmitter?.emit(.uploadProgress, data: [
                "bytes_sent": String(sent),
                "bytes_total": String(total),
                "percent": String(percent)
            ])
        }

        // A retry starting is the upload still trying: it pushes back the
        // stall window too, so every retry gets its full idle window.
        self.apiClient.onUploadAttempt = { [weak self] _ in self?.watchdog?.kick() }

        watchdog = SessionWatchdog(onTimeout: { [weak self] phase in
            self?.handleWatchdogTimeout(phase)
        })
    }

    // MARK: - Public Event Listener

    public func addEventListener(_ callback: @escaping EventCallback) -> () -> Void {
        eventEmitter.addListener(callback)
    }

    // MARK: - Hosted / Flows Session Injection

    /// Inject pre-minted session credentials returned by a server-side init
    /// step (the hosted enrollment page and the Flows `/sdk/flow-runs/:id/init-session`
    /// endpoint both produce a CreateSessionResponse). `start()` then sees
    /// `sessionData != nil` and skips the createSession/exchangeToken path.
    ///
    /// Made public for the Flows runner; the dashboard hosted page calls it
    /// internally too via UseSenseSession's framework-internal init path.
    public func injectHostedSessionData(_ response: CreateSessionResponse) {
        USTrace.log("injected hosted/Flows session \(response.sessionId)")
        let data = SessionData(from: response)
        self.sessionData = data
        publishBranding()
        self.sessionInjected = true
        self.apiClient.sessionToken = data.sessionToken
        self.apiClient.nonce = data.nonce
        frameBuffer.reconfigure(maxFrames: data.upload.maxFrames, targetFps: data.upload.targetFps)
        serverMaxFrames = data.upload.maxFrames
        initSuspicionEngine(policy: data.policy)
    }

    // MARK: - Session Lifecycle

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await runAttempt { await self.runStart() }
    }

    private func runStart() async {
        sessionStartTime = Date()

        do {
            deviceSignalCollector.startSensorCollection()
            faceMeshManager.setup()
            if guidedCapture { coverSegmenter.setup() }

            if sessionData == nil {
                if let clientToken = clientToken {
                    // Server-Side Init: exchange token for session credentials
                    let response = try await apiClient.exchangeToken(clientToken: clientToken)
                    let data = SessionData(from: response)
                    self.sessionData = data
                    publishBranding()
                } else {
                    // Standard Init: create session directly
                    let request = CreateSessionRequest(
                        sessionType: sessionType.rawValue,
                        identityId: identityId,
                        externalUserId: externalUserId,
                        metadata: metadata
                    )
                    let response = try await apiClient.createSession(request: request)
                    let data = SessionData(from: response)
                    self.sessionData = data
                    publishBranding()
                }
            }

            guard let data = sessionData else {
                handleError(UseSenseError(code: .unknownError, message: "No session data available."))
                return
            }

            // Initialize suspicion engine from policy
            initSuspicionEngine(policy: data.policy)

            // Start App Attest concurrently
            #if canImport(DeviceCheck) && canImport(CryptoKit)
            appAttestTask = Task {
                await appAttestManager.getAttestFields(sessionNonce: data.nonce)
            }
            #endif

            eventEmitter.emit(.sessionCreated, data: ["session_id": data.sessionId])
            currentState = .created(session: data)
            // Guided: a check known before the scan is announced up front
            // ("Two quick steps"), before the camera permission prompt.
            if guidedCapture, !primerShown, let check = beforeScanCheck {
                currentState = .instructions(challenge: check)
                return
            }
            await checkPermissions()
        } catch let error as UseSenseError {
            handleError(error)
        } catch {
            handleError(UseSenseError(code: .networkError, message: error.localizedDescription))
        }
    }

    func requestPermissions() async {
        await runAttempt { await self.runRequestPermissions() }
    }

    private func runRequestPermissions() async {
        eventEmitter.emit(.permissionsRequested)

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                eventEmitter.emit(.permissionsDenied, data: ["type": "camera"])
                handleError(UseSenseError(code: .cameraPermissionDenied))
                return
            }
        } else if cameraStatus == .denied || cameraStatus == .restricted {
            eventEmitter.emit(.permissionsDenied, data: ["type": "camera"])
            handleError(UseSenseError(code: .cameraPermissionDenied))
            return
        }

        if needsAudio {
            // Guided Speak Digits never dead-ends on the microphone: no input
            // or a refusal offers Settings or a head movement instead.
            let offerMovement = guidedSpeakDigits
            if offerMovement, !AVAudioSession.sharedInstance().isInputAvailable {
                USTrace.log("mic: no audio input available")
                currentState = .micUnavailable
                return
            }
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            var micGranted = micStatus == .authorized
            if micStatus == .notDetermined {
                micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            }
            if !micGranted {
                eventEmitter.emit(.permissionsDenied, data: ["type": "microphone"])
                if offerMovement {
                    currentState = .micUnavailable
                } else {
                    handleError(UseSenseError(code: .micPermissionDenied))
                }
                return
            }
        }

        eventEmitter.emit(.permissionsGranted)
        await startCapturePipeline()
    }

    func proceedFromInstructions() async {
        if guidedCapture {
            // The guided primer comes before the permission prompts.
            primerShown = true
            await runAttempt { await self.checkPermissions() }
        } else {
            await runAttempt { await self.startFaceGuide() }
        }
    }

    // MARK: Guided extra check: entry points

    /// The check this session runs on the scan screen right after the scan
    /// (the policy's challenge, or Speak Digits), if any.
    var beforeScanCheck: ChallengeSpecWrapper? {
        guard let policy = sessionData?.policy else { return nil }
        if let challenge = policy.challenge { return challenge }
        return policy.audioChallenge.map { .speakPhrase($0) }
    }

    /// Guided Speak Digits (an audio challenge and no visual one).
    private var guidedSpeakDigits: Bool {
        guard guidedCapture, let policy = sessionData?.policy else { return false }
        return policy.challenge == nil && policy.audioChallenge != nil
    }

    /// Integrator options for the end of the flow.
    var showsResultScreen: Bool { config.options?.showsResultScreen ?? true }
    var ownsSession: Bool { !sessionInjected && clientToken == nil }
    var retriesAfterReject: Int { sessionInjected ? 0 : (config.options?.retriesAfterReject ?? 0) }

    /// The extra check runs on the scan screen (guided, not LiveSense v4).
    var guidedExtraCheck: Bool {
        guidedCapture && config.options?.liveSenseV4Enabled != true
    }

    /// "Continue" on the "One more quick check" sheet.
    func extraCheckContinue() async {
        await runAttempt { await self.runExtraCheck() }
    }

    /// The person came back from Settings with the microphone allowed.
    func retryMicrophone() async {
        guard case .micUnavailable = storedState else { return }
        await runAttempt { await self.runRequestPermissions() }
    }

    /// "Do a head movement instead": the server swaps Speak Digits for
    /// Follow Dot, then the capture carries on without the microphone.
    func useMovementInstead() async {
        await runAttempt { await self.runMovementFallback() }
    }

    private func runMovementFallback() async {
        guard claimOnce("challenge-fallback"), let data = sessionData else { return }
        do {
            let response = try await apiClient.requestChallengeFallback(
                sessionId: data.sessionId, sessionToken: data.sessionToken, nonce: data.nonce)
            sessionData?.policy = response.policy
            USTrace.log("mic: challenge fallback -> \(response.policy.challengeType)")
            await runRequestPermissions()
        } catch let error as UseSenseError {
            releaseClaim("challenge-fallback")
            handleError(Self.fallbackError(error))
        } catch {
            releaseClaim("challenge-fallback")
            handleError(UseSenseError(code: .networkError, message: error.localizedDescription, isRetryable: true))
        }
    }

    /// The fallback's 409s (`capture_already_uploaded`, `fallback_not_allowed`)
    /// are not "token already used": nothing about them is the person's
    /// connection or session age, so they read as a plain error.
    static func fallbackError(_ error: UseSenseError) -> UseSenseError {
        switch error.details {
        case "capture_already_uploaded", "fallback_not_allowed":
            return UseSenseError(code: .invalidRequest, message: error.message, details: error.details, isRetryable: false)
        default:
            return error
        }
    }

    /// The "Leave verification?" dialog holds the running challenge.
    func setChallengeHeld(_ held: Bool) {
        guideLock.lock(); challengeHeld = held; guideLock.unlock()
    }

    func faceReady() async {
        await runAttempt { await self.startBaseline() }
    }

    /// Shutter fallback: start the same scan by hand. The quality bar is the
    /// same; only the start is manual.
    func shutterTapped() async {
        manualStart = true
        await faceReady()
    }

    /// The capture screen's size in points, so the gate tests landmarks
    /// against the oval the user actually sees.
    func setViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guideLock.lock(); viewportSize = size; guideLock.unlock()
    }

    /// Seconds the guided scan banks.
    var guidedScanSeconds: Int {
        let single = sessionData?.policy.challenge == nil && config.options?.liveSenseV4Enabled != true
        return Int((single ? Self.guidedScanDuration : baselineDuration).rounded())
    }

    #if DEBUG
    /// Debug rig: the fake camera's current frame (forced upload backdrop).
    func debugCurrentFrame() -> UIImage? { frameCaptureManager.fake?.currentImage() }
    #endif

    /// The last banked frame (for the blurred backdrop behind the upload sheet).
    func lastCapturedFrame() -> Data? { frameBuffer.getFrames().last }

    func challengeCompleted() async {
        await runAttempt { await self.runChallengeCompleted() }
    }

    private func runChallengeCompleted() async {
        USTrace.log("challenge completed (capturing=\(storedState.isCaptureInProgress))")
        // Once per capture round. A second completion (a challenge view firing
        // twice, a duplicate tap) used to pass the state check below while the
        // first was still awaiting, and run a second upload/complete.
        guard claimOnce("challenge-complete:\(serverStepUp == nil ? 1 : 2)") else { return }
        guard storedState.isCaptureInProgress else { return }
        isCapturingFrames = false
        challengeResponseBuilder.markCompleted()
        eventEmitter.emit(.challengeCompleted)

        if let stepUp = serverStepUp {
            serverStepUp = nil
            await finishServerStepUpRound(stepUp)
            return
        }

        // Check suspicion engine for inline step-up BEFORE stopping camera
        if let engine = suspicionEngine, engine.shouldTriggerStepUp() {
            await runInlineStepUp(engine: engine)
        }

        frameCaptureManager.stop()
        captureEndTime = Date()
        deviceSignalCollector.stopSensorCollection()
        await stopAudioIfNeeded()

        do {
            try await uploadAndCompleteWithSafetyNet()
        } catch {
            handleError(UseSenseError(code: .unknownError, message: "Unexpected error: \(error.localizedDescription)"))
        }
    }

    func challengeStepReached(_ index: Int) {
        challengeResponseBuilder.setCurrentStep(index)
    }

    func onFrameCapturedForChallenge(frameIndex: Int, timestampMs: Int64) {
        challengeResponseBuilder.recordFrame(frameIndex: frameIndex, timestampMs: timestampMs)
    }

    /// Whether "Try again" can run a clean attempt inside this object. Once
    /// signals may have reached the server, a clean attempt needs a new
    /// session, which only a self-created session can mint; an injected one
    /// (Flows / hosted page) hands the error back to its host to re-init.
    var canRestartInPlace: Bool {
        !uploadAttempted || (!sessionInjected && clientToken == nil)
    }

    /// Whether "Retry" can finish this attempt on the same session: the capture
    /// is in hand (or already on the server) and the session is still valid.
    /// Then nothing is recaptured: if the signals were accepted only /complete
    /// runs again (the server replays a decision it already made); otherwise
    /// the same frames are uploaded again (the server replaces the earlier
    /// upload, and acknowledges one to a completed session as a no-op).
    var canResumeFinalization: Bool {
        guard let session = sessionData, !session.isExpired else { return false }
        return signalsAccepted || pendingUpload != nil
    }

    /// "Retry" after an upload or completion failure: same session, same capture.
    func resumeFinalization() async {
        guard canResumeFinalization else {
            await retry()
            return
        }
        invalidateAttempt()
        await runAttempt { await self.runResumeFinalization() }
    }

    private func runResumeFinalization() async {
        guard let session = sessionData else { return }
        if signalsAccepted {
            watchdog?.arm(.upload, budget: uploadBudget)
            await completeSessionWithSafetyNet(session)
        } else {
            await uploadPendingAndComplete(session)
        }
    }

    /// "Start over": a new capture (and, when signals may be on the server and
    /// this object owns the session, a new session).
    func retry() async {
        invalidateAttempt()
        pendingUpload = nil
        signalsAccepted = false
        isCapturingFrames = false
        frameCaptureManager.stop()
        audioCaptureManager.cleanup()
        if uploadAttempted && !sessionInjected && clientToken == nil {
            // The old session may already hold this attempt's signals.
            sessionData = nil
        }
        if sessionData?.isExpired == true && !sessionInjected && clientToken == nil {
            // An expired session can't be used again: mint a new one.
            sessionData = nil
        }
        uploadAttempted = false
        stepUpResult = nil
        serverStepUp = nil
        primerShown = false
        audioChallengeResponse = nil
        resetGuidedState()
        resetEvidence()
        framesDropped = 0
        frameBuffer.reset()
        challengeResponseBuilder.reset()
        faceMeshManager.reset()
        suspicionEngine?.reset()
        deviceSignalCollector.release()
        apiClient.clearSession()
        isStarted = false
        currentState = .idle
        await start()
    }

    func cancel() {
        invalidateAttempt()
        isCapturingFrames = false
        frameCaptureManager.stop()
        audioCaptureManager.cleanup()
        frameBuffer.reset()
        faceMeshManager.teardown()
        coverSegmenter.release()
        deviceSignalCollector.release()
        appAttestTask?.cancel()
        currentState = .error(UseSenseError(code: .userCancelled))
    }

    // MARK: - Private Flow

    private func initSuspicionEngine(policy: SessionPolicy) {
        let config = policy.inlineStepUp ?? InlineStepUpConfig(
            enabled: true,
            suspicionThreshold: 55,
            preferredChallenge: "auto"
        )
        suspicionEngine = SuspicionEngine(config: config)
    }

    private func checkPermissions() async {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        var needed: [PermissionType] = []

        if cameraStatus != .authorized { needed.append(.camera) }
        if needsAudio {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if micStatus != .authorized { needed.append(.microphone) }
        }

        if needed.isEmpty {
            eventEmitter.emit(.permissionsGranted)
            await startCapturePipeline()
        } else if guidedCapture {
            // Guided: straight to the system prompt (no extra screen first).
            await runRequestPermissions()
        } else {
            currentState = .permissionsRequired(permissions: needed)
        }
    }

    private func startCapturePipeline() async {
        do {
            try frameCaptureManager.configure()
        } catch {
            let message: String
            if let senseError = error as? UseSenseError {
                message = senseError.message
            } else {
                message = "Camera error: \(error.localizedDescription)"
            }
            currentState = .cameraError(message: message)
            return
        }

        if let upload = sessionData?.upload {
            reconfigureFrameBuffer(maxFrames: upload.maxFrames, targetFps: upload.targetFps)
        }

        setCameraLive(false)
        latestLock.withLock { captureClockOrigin = nil }
        frameCaptureManager.start()

        if !guidedCapture, let challenge = sessionData?.policy.challenge {
            currentState = .instructions(challenge: challenge)
        } else {
            await startFaceGuide()
        }
    }

    private func startFaceGuide() async {
        if alignStartedAt == nil { alignStartedAt = Date() }
        rearmAutoStart()
        currentState = .faceGuide
    }

    /// A fresh align screen: the gate starts over (the fill light stays on)
    /// and may auto start again.
    private func rearmAutoStart() {
        guideLock.lock()
        autoStartRequested = false
        guide.reset(keepFillLight: true)
        guideLock.unlock()
    }

    private func resetGuidedState() {
        alignStartedAt = nil
        pausedWindows = 0
        manualStart = false
        guideLock.lock()
        guide.reset()
        latestGuide = .initial
        lastGuidePublished = nil
        autoStartRequested = false
        guideLock.unlock()
        contourField.clear()
    }

    private var guideAllPass: Bool {
        guideLock.lock(); defer { guideLock.unlock() }
        return latestGuide.allPass
    }

    /// Drop the frames banked so far (a pause outlasted `scanDiscardAfter`).
    private func discardBankedFrames() {
        bankLock.lock()
        frameBuffer.reset()
        faceMeshManager.reset()
        bankLock.unlock()
        frameBuffer.setCapturePhase(.baseline)
        captureStartTime = Date()
    }

    /// The guided scan: frames bank only while every check passes; any
    /// failure pauses the ring, which resumes when the face is good again.
    /// Banked frames are kept unless a pause lasts more than 1.5 s; then the
    /// window is dropped and this returns false, so the caller goes back to
    /// the align screen (the shutter shows after 3 dropped windows). In
    /// shutter mode a pause never drops the window.
    private func runGatedScan(duration: TimeInterval) async throws -> Bool {
        var banked: TimeInterval = 0
        var pausedFor: TimeInterval = 0
        var last = Date()
        var shown: Double = 0
        // EVIDENCE-v1 section 6: the server's colours play inside the scan; a
        // pause stops them and the scan holds until a full replay has run.
        let player = await prepareColourPlayer()
        let colourNeeds = player.map { TimeInterval($0.sequence.totalMs) / 1000 + 0.15 } ?? 0
        var colourFrom: TimeInterval?
        onScanUpdate?(ScanProgress(fraction: 0, paused: false, bankedSeconds: 0, totalSeconds: duration, completed: false))
        while true {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            let now = Date()
            let dt = min(0.25, now.timeIntervalSince(last))
            last = now
            let passing = guideAllPass
            isCapturingFrames = passing
            if passing {
                banked += dt
                pausedFor = 0
            } else {
                pausedFor += dt
                if !manualStart, pausedFor > Self.scanDiscardAfter {
                    isCapturingFrames = false
                    // The frames go, so their colour segments go too.
                    if let player { await MainActor.run { player.resetForNewWindow() } }
                    pausedWindows += 1
                    USTrace.log("scan: pause > \(Self.scanDiscardAfter)s, window \(pausedWindows) dropped")
                    recordScanDrop()
                    return false
                }
            }
            var needed = duration
            if let player {
                let state = await MainActor.run { (player.isPlaying, player.finished, player.runs) }
                if !passing, state.0 {
                    await stopColour(player, reason: "gate_pause")
                    colourFrom = nil
                } else if passing, !state.0, !state.1, state.2 < Self.colourMaxRuns {
                    await MainActor.run { player.play() }
                    colourFrom = banked
                    USTrace.log("colour: play \(state.2 + 1) at \(String(format: "%.2f", banked))s")
                }
                let playing = await MainActor.run { player.isPlaying }
                if playing, let from = colourFrom { needed = max(duration, from + colourNeeds) }
            }
            shown = max(shown, min(1, banked / needed))
            if banked >= needed { break }
            onScanUpdate?(ScanProgress(fraction: shown, paused: !passing,
                                       bankedSeconds: banked, totalSeconds: needed, completed: false))
        }
        isCapturingFrames = false
        if let player { await stopColour(player, reason: "scan_ended") }
        if let player {
            let r = await MainActor.run { player.record }
            USTrace.log("colour: completed=\(r.completed) segments=\(r.segments.count) awb=\(r.awbLocked)")
        }
        onScanUpdate?(ScanProgress(fraction: 1, paused: false, bankedSeconds: banked, totalSeconds: banked, completed: true))
        return try await finalCoverCheck()
    }

    // MARK: - EVIDENCE-v1: colour sequence and closer step

    /// The colour player for this attempt, made on first use (nil when the
    /// server sent no sequence). One sequence id per session.
    private func prepareColourPlayer() async -> ColourSequencePlayer? {
        guard guidedCapture, let sequence = sessionData?.evidence?.colourSequence else { return nil }
        return await MainActor.run { () -> ColourSequencePlayer in
            if let p = colourPlayer { return p }
            let p = ColourSequencePlayer(sequence: sequence) { [weak self] t in self?.captureMs(host: t) }
            p.host = colourTintHost
            let camera = frameCaptureManager
            p.lockWhiteBalance = { camera.lockWhiteBalance($0) }
            colourPlayer = p
            return p
        }
    }

    private func stopColour(_ player: ColourSequencePlayer?, reason: String) async {
        guard let player else { return }
        await MainActor.run { player.interrupt(reason: reason) }
    }

    /// Host time (CACurrentMediaTime base) on the capture clock.
    func captureMs(host: CFTimeInterval) -> Int? {
        guard let origin = latestLock.withLock({ captureClockOrigin }) else { return nil }
        return max(0, Int(((host - origin) * 1000).rounded()))
    }

    private func currentCaptureMs() -> Int? { captureMs(host: CACurrentMediaTime()) }

    private func resetEvidence() {
        let player = colourPlayer
        DispatchQueue.main.async { player?.cancel() }
        colourPlayer = nil
        closerEvidence = nil
        bankLock.withLock { nearBankThreshold = nil }
        guideLock.withLock { ovalScale = 1 }
    }

    /// Frames the scan leaves free for the closer step's near frames.
    private var closerReserve: Int { sessionData?.evidence?.closerEnabled == true ? Self.closerPhaseFrames : 0 }

    /// EVIDENCE-v1 section 7, step 5 of the scan: the oval grows by the
    /// server's `target_scale` and the person follows it. Far frames are the
    /// last banked scan frames; near frames bank once the eye distance reaches
    /// `min_scale` times the far median and the gate passes. Never blocks: a
    /// timeout records `skipped_reason: "timeout"` and the capture goes on.
    private func runCloserStep() async throws {
        guard let evidence = sessionData?.evidence else { return }
        guard let step = evidence.closerStep, step.enabled else {
            closerEvidence = .skipped(.disabled)
            return
        }
        let banked = faceMeshManager.getResults()
        let total = frameBuffer.count
        guard banked.count >= Self.closerPhaseFrames, total == banked.count else {
            USTrace.log("closer: \(banked.count) banked frames, skipped")
            closerEvidence = .skipped(.timeout)
            return
        }
        let far = Array(banked.suffix(Self.closerPhaseFrames))
        let aspect: Double = {
            let r = frameBuffer.getResolutions().last
            return r.map { Double($0.height) / Double(max(1, $0.width)) } ?? 16.0 / 9.0
        }()
        let farEyes = far.compactMap { Self.eyeDistance($0.landmarks, aspect: aspect) }
        guard farEyes.count == far.count, let farMedian = Self.median(farEyes), farMedian > 0 else {
            closerEvidence = .skipped(.timeout)
            return
        }
        var record = CloserEvidence()
        record.farFrames = far.map(\.frameIndex)
        record.startedAtMs = currentCaptureMs()
        let threshold = farMedian * step.minScale
        let startCount = frameBuffer.count
        // Near frames spread over the hold, not one burst as the face arrives.
        frameBuffer.reconfigure(maxFrames: serverMaxFrames ?? sessionData?.upload.maxFrames ?? 30,
                                targetFps: Self.closerNearFps)
        guideLock.withLock { ovalScale = CGFloat(step.targetScale) }
        onCloserUpdate?(CGFloat(step.targetScale), true)
        bankLock.withLock { nearBankThreshold = threshold }
        defer {
            isCapturingFrames = false
            bankLock.withLock { nearBankThreshold = nil }
            guideLock.withLock { ovalScale = 1 }
            onCloserUpdate?(1, false)
        }
        USTrace.log(String(format: "closer: far median eye %.4f, need %.4f", farMedian, threshold))
        let started = Date()
        var deadline = started.addingTimeInterval(Self.closerTimeout)
        var shownNear = false
        var holdingSince: Date?
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            let now = Date()
            let eye = latestMeshResult().flatMap { Self.eyeDistance($0.landmarks, aspect: aspect) } ?? 0
            // The copy switches at the threshold and only goes back to
            // "Move a little closer" a little below it, so it doesn't flicker.
            let showNear = Self.closerShowsNear(eye: eye, threshold: threshold, wasNear: shownNear)
            if showNear != shownNear {
                shownNear = showNear
                onCloserUpdate?(CGFloat(step.targetScale), !showNear)
                if showNear, holdingSince == nil {
                    // Reached in time: allow the hold and the frames.
                    deadline = max(deadline, now.addingTimeInterval(Self.closerHoldBudget))
                }
            }
            // Bank only after the face has held still, close enough, for a
            // moment (device run: three frames in 0.26 s while still moving).
            if eye >= threshold && closerGatePasses {
                holdingSince = holdingSince ?? now
            } else {
                holdingSince = nil
            }
            isCapturingFrames = holdingSince.map { now.timeIntervalSince($0) >= Self.closerSettle } ?? false
            if frameBuffer.count - startCount >= Self.closerPhaseFrames || frameBuffer.isFull { break }
        }
        isCapturingFrames = false
        let nearMeshes = faceMeshManager.getResults().dropFirst(startCount)
        record.endedAtMs = currentCaptureMs()
        if nearMeshes.count >= Self.closerPhaseFrames {
            record.nearFrames = nearMeshes.map(\.frameIndex)
            let nearEyes = nearMeshes.compactMap { Self.eyeDistance($0.landmarks, aspect: aspect) }
            record.achievedScale = Self.median(nearEyes).map { $0 / farMedian }
            record.completed = true
        } else {
            // A timeout uploads no closer frames (section 8: "closer:none").
            record.farFrames = []
            record.nearFrames = []
            record.skippedReason = .timeout
        }
        USTrace.log("closer: completed=\(record.completed) near=\(nearMeshes.count)"
            + " scale=\(record.achievedScale.map { String(format: "%.2f", $0) } ?? "-")")
        closerEvidence = record
    }

    /// The near phase's gate (EVIDENCE-v1 section 7: pose, stillness,
    /// sharpness, with a face and one person). Left out: distance and in-frame
    /// (coming closer is the point, and a near face can overflow the oval;
    /// device run: 1.45x the far eye distance read "Move back a little"), and
    /// covered (the scan's change watch compares regions with the scan's
    /// baseline, which all change as the face grows; device run: it fired at
    /// 1.27x and no near frame banked; the final cover check already ran).
    private var closerGatePasses: Bool {
        guideLock.lock(); defer { guideLock.unlock() }
        return Self.closerGatePasses(failing: latestGuide.failing)
    }

    static func closerGatePasses(failing: Set<GateCheck>) -> Bool {
        failing.subtracting([.distance, .inFrame, .light, .covered]).isEmpty
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// COVER-v1 final check: segmentation lags (~1 s on slow phones), so a
    /// hand arriving in the last second could slip through. Wait (up to 2.5 s)
    /// for a result from a frame at or after the scan's end: covered drops the
    /// window back to align, clear (or no result in time) finishes.
    private func finalCoverCheck() async throws -> Bool {
        guard coverSegmenter.available else {
            recordFinalCover(nil, waited: 0, outcome: .skipped)
            return true
        }
        let since = guideFrameTime()
        let started = Date()
        while Date().timeIntervalSince(started) < Self.finalCoverWait {
            if coverSegmenter.latestAt >= since {
                let cover = coverSegmenter.latest(at: coverSegmenter.latestAt)
                let covered = cover?.covered == true
                recordFinalCover(cover, waited: Date().timeIntervalSince(started), outcome: covered ? .covered : .clear)
                USTrace.log("scan: final cover check covered=\(covered)"
                    + " body=\(cover.map { String(format: "%.2f", $0.bodySkin) } ?? "-")"
                    + " other=\(cover.map { String(format: "%.2f", $0.other) } ?? "-")")
                return !covered
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
        }
        USTrace.log("scan: final cover check timed out, finishing")
        recordFinalCover(nil, waited: Date().timeIntervalSince(started), outcome: .timeout)
        return true
    }

    private func recordFinalCover(_ cover: FaceCover?, waited: TimeInterval, outcome: CoverCheckReport.FinalOutcome) {
        guideLock.lock(); defer { guideLock.unlock() }
        coverReport.finalCheck(cover: cover, waitedMs: Int((waited * 1000).rounded()), outcome: outcome)
        if outcome == .covered { coverReport.scanDroppedForCover() }
    }

    /// A paused scan was dropped: count it when cover was what held it.
    private func recordScanDrop() {
        guideLock.lock(); defer { guideLock.unlock() }
        // Covered was the reason only when stillness wasn't failing too.
        if CoverCheckReport.isCoverDrop(failing: latestGuide.failing) { coverReport.scanDroppedForCover() }
    }

    /// The `covered_check` metadata object (guided capture only).
    private func coveredCheckJSON() -> [String: Any]? {
        guard guidedCapture else { return nil }
        let stats = coverSegmenter.stats
        guideLock.lock(); defer { guideLock.unlock() }
        let json = coverReport.json(segmenter: stats)
        USTrace.log("cover: covered_check runs=\(stats.runMs.count)"
            + " final=\(coverReport.finalOutcome?.rawValue ?? "-") drops=\(coverReport.scanDrops)"
            + " trips=\(coverReport.watchTrips) align_covered_ms=\(Int(coverReport.alignCoveredMs))")
        return json
    }

    private func guideFrameTime() -> TimeInterval {
        guideLock.lock(); defer { guideLock.unlock() }
        return latestGuideFrameTime
    }

    /// Back to the align screen after a dropped scan window.
    private func returnToAlign() async {
        isCapturingFrames = false
        discardBankedFrames()
        if audioCaptureManager.isRecording { _ = audioCaptureManager.stopRecording() }
        releaseClaim("baseline")
        await startFaceGuide()
    }

    private func reconfigureFrameBuffer(maxFrames: Int, targetFps: Int) {
        serverMaxFrames = maxFrames
        frameBuffer.reconfigure(maxFrames: maxFrames, targetFps: targetFps)
    }

    /// Build a small summary block describing the zoom phase for the upload
    /// payload. The server cross-checks SDK-reported counts against the SfM
    /// reconstruction (PRD section 4.6 motion_coherence).
    private func buildZoomMotionStats(framePhases: [String]) -> [String: Any] {
        let total = framePhases.count
        let zoomCount = framePhases.filter { $0 == FrameBuffer.CapturePhase.zoom.rawValue }.count
        return [
            "frames_total": total,
            "frames_in_zoom": zoomCount,
            "expected_duration_ms": 1500,
            "sdk_version": UseSenseAPIClient.sdkVersion
        ]
    }

    /// LiveSense v4 zoom phase. The user is prompted to move the camera
    /// closer (~30cm to ~18cm over 1.5s) so the server's perspective
    /// validator can reconstruct 3D face geometry from the frame sequence.
    /// Frames captured during this window are tagged `phase: "zoom"` so the
    /// SfM service can filter to the coherent-motion subset.
    private func runZoomPhase() async {
        let zoomDurationMs: UInt64 = 1500
        let stepMs: UInt64 = 50
        let steps = zoomDurationMs / stepMs

        frameBuffer.setCapturePhase(.zoom)
        eventEmitter.emit(.zoomStarted, data: ["expected_duration_ms": "\(zoomDurationMs)"])

        for step in 0..<steps {
            let progress = Double(step) / Double(steps)
            currentState = .zoom(progressFraction: progress)
            do {
                try await Task.sleep(nanoseconds: stepMs * 1_000_000)
            } catch is CancellationError {
                return
            } catch {
                break
            }
        }
        currentState = .zoom(progressFraction: 1.0)
        eventEmitter.emit(.zoomCompleted)
        // Subsequent frames revert to whatever phase the next state sets.
    }

    private func startBaseline() async {
        // Once per attempt: a double tap on "I'm Ready" used to run two
        // baselines, and on the no-challenge path two uploads.
        guard claimOnce("baseline") else { return }
        do {
            watchdog?.arm(.capture, budget: captureBudget)
            // The capture clock starts on the camera's first frame, not on the
            // tap. On a slow camera the window used to close before frames
            // arrived (Android, Galaxy A03: 0-13 frames, 0 = NO_FRAMES_CAPTURED).
            guard try await waitForFirstFrame() else {
                handleError(UseSenseError(
                    code: .noFramesCaptured,
                    details: "camera delivered no frame within \(Int(firstFrameBudget))s",
                    isRetryable: true
                ))
                return
            }
            eventEmitter.emit(.captureStarted)
            captureStartTime = Date()
            frameBuffer.reset()
            faceMeshManager.reset()
            suspicionEngine?.reset()
            isCapturingFrames = true
            // v4: tag frames captured during baseline.
            frameBuffer.setCapturePhase(.baseline)
            currentState = .baseline(remaining: baselineDuration)

            if needsAudio {
                startAudioRecording()
            }

            let captureDurationMs = sessionData?.upload.captureDurationMs ?? config.options?.captureDurationMs ?? 8000
            // Guided passive scan: one gated window covers baseline + capture
            // (the same frames as before). A session with a challenge gates
            // its baseline-length scan the same way, then runs the movement
            // ungated (a head turn needs pose "failures"). v4 is gated at the
            // start only.
            let singleGatedScan = guidedCapture
                && sessionData?.policy.challenge == nil
                && config.options?.liveSenseV4Enabled != true
            if singleGatedScan {
                isCapturingFrames = false
                // ~3 s scan (as web). Bank the same number of frames as the
                // old 2 s + captureDurationMs window by raising the rate.
                let maxFrames = serverMaxFrames ?? sessionData?.upload.maxFrames ?? 30
                let oldWindow = baselineDuration + Double(captureDurationMs) / 1000
                let serverFps = sessionData?.upload.targetFps ?? 3
                let fps = min(Self.guidedMaxFps, max(serverFps,
                    Int((Double(min(maxFrames, Int(oldWindow * Double(serverFps)))) / Self.guidedScanDuration).rounded(.up))))
                // The closer step's near frames come out of the same budget.
                frameBuffer.reconfigure(maxFrames: max(1, maxFrames - closerReserve), targetFps: fps)
                guard try await runGatedScan(duration: Self.guidedScanDuration) else {
                    await returnToAlign()
                    return
                }
                try await runCloserStep()
            } else if guidedExtraCheck {
                // A check known before the scan: the same gated scan (the
                // baseline's length, frames as before), then the movement
                // follows on the same screen with no countdown. The scan's
                // frames are no step's evidence (step -1 until it starts).
                challengeResponseBuilder.setCurrentStep(-1)
                guard try await runGatedScan(duration: baselineDuration) else {
                    await returnToAlign()
                    return
                }
                try await runCloserStep()
            } else if guidedCapture {
                // v4 baseline: not gated, but the ring still fills.
                let start = Date()
                while Date().timeIntervalSince(start) < baselineDuration {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    let done = min(baselineDuration, Date().timeIntervalSince(start))
                    onScanUpdate?(ScanProgress(fraction: done / baselineDuration, paused: false, bankedSeconds: done,
                                               totalSeconds: baselineDuration, completed: done >= baselineDuration))
                }
            } else {
                try await Task.sleep(nanoseconds: UInt64(baselineDuration * 1_000_000_000))
            }

            // v4: insert a constitutive zoom phase between baseline and the
            // active challenge. Additive -- existing challenges still run.
            // ZoomMotionController + ZoomPromptView observe `currentState`.
            if config.options?.liveSenseV4Enabled == true {
                await runZoomPhase()
            }

            if sessionData?.policy.challenge != nil && !guidedExtraCheck {
                for i in stride(from: 3, through: 1, by: -1) {
                    currentState = .countdown(number: i)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            challengeResponseBuilder.markStarted()
            if let challenge = sessionData?.policy.challenge {
                eventEmitter.emit(.challengeStarted, data: ["type": challenge.challengeType.rawValue])
                frameBuffer.setCapturePhase(.challenge)
                guard guidedExtraCheck else {
                    // Legacy: the challenge view drives it and calls challengeCompleted().
                    currentState = .challenge(spec: challenge)
                    return
                }
                isCapturingFrames = false
                currentState = .challenge(spec: challenge)
                try await runGuidedChallenge(challenge)
                challengeResponseBuilder.markCompleted()
                eventEmitter.emit(.challengeCompleted)
                try await finishCaptureAndUpload()
            } else {
                if !singleGatedScan {
                    try await Task.sleep(nanoseconds: UInt64(captureDurationMs) * 1_000_000)
                }
                isCapturingFrames = false
                if guidedExtraCheck, let audio = sessionData?.policy.audioChallenge {
                    try await runGuidedSpeakDigits(audio)
                }
                try await finishCaptureAndUpload()
            }
        } catch is CancellationError {
            return
        } catch {
            handleError(UseSenseError(code: .unknownError, message: "Unexpected error: \(error.localizedDescription)"))
        }
    }

    /// The capture is over: stop the camera, mic and sensors, then upload.
    /// The client-side suspicion step-up runs first when the
    /// engine fires and the policy enables it (dashboard: "Unusual movement
    /// during the scan"). A server round 2, if asked for, comes after the upload.
    private func finishCaptureAndUpload() async throws {
        isCapturingFrames = false
        if let engine = suspicionEngine, engine.shouldTriggerStepUp() {
            await runInlineStepUp(engine: engine)
        }
        frameCaptureManager.stop()
        captureEndTime = Date()
        deviceSignalCollector.stopSensorCollection()
        await stopAudioIfNeeded()
        try await uploadAndCompleteWithSafetyNet()
    }

    // MARK: - Guided extra check

    /// Speak Digits on the scan screen: the digits, a live level meter, and
    /// the audio already recording since the scan began.
    private func runGuidedSpeakDigits(_ spec: SpeakPhraseChallenge) async throws {
        let wrapper = ChallengeSpecWrapper.speakPhrase(spec)
        let started = Self.isoNow()
        eventEmitter.emit(.challengeStarted, data: ["type": ChallengeType.speakPhrase.rawValue])
        currentState = .challenge(spec: wrapper)
        try await runGuidedChallenge(wrapper, banksFrames: false)
        eventEmitter.emit(.challengeCompleted)
        audioChallengeResponse = [
            "type": ChallengeType.speakPhrase.rawValue,
            "seed": spec.seed,
            "completed": true,
            "started_at": started,
            "completed_at": Self.isoNow(),
        ]
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Runs a challenge on the scan screen until its timeline completes. It
    /// pauses while the face is out of the oval (or the leave dialog is open)
    /// and never fails on the device; the server judges the frames.
    /// `banksFrames`: frames go into the upload while the gate passes (the
    /// movement); Speak Digits banks none (the scan filled the buffer).
    private func runGuidedChallenge(_ spec: ChallengeSpecWrapper, banksFrames: Bool = true) async throws {
        guard var runner = ChallengeRunner(spec: spec) else { return }
        guideLock.lock()
        challengeFacePresent = false
        challengeHint = nil
        challengeYaw = nil
        challengePitch = nil
        challengeHeld = false
        challengeRules = runner.gateRules
        guideLock.unlock()
        defer { isCapturingFrames = false }
        let isDigits = runner.plan.isDigits
        if isDigits { audioCaptureManager.enableMetering() }
        let clock = Date()
        var lastStep = -1
        // Every step gets its share of the frames left (device run: a 30-frame
        // budget ran out by the third of four steps, and the server failed the
        // last step, which had no frames).
        let cap = serverMaxFrames ?? sessionData?.upload.maxFrames ?? 30
        var stepStartCount = frameBuffer.count
        var stepQuota = cap
        while true {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            guideLock.lock()
            var obs = ChallengeObservation(time: Date().timeIntervalSince(clock), facePresent: challengeFacePresent,
                                           yaw: challengeYaw, pitch: challengePitch, held: challengeHeld,
                                           hint: challengeHint)
            guideLock.unlock()
            // As in the scan: frames bank only while every check passes.
            if runner.specStepIndex != lastStep {
                lastStep = runner.specStepIndex
                challengeResponseBuilder.setCurrentStep(lastStep)
                stepStartCount = frameBuffer.count
                stepQuota = Self.stepFrameQuota(remaining: cap - stepStartCount,
                                                stepsLeft: runner.stepCount - runner.stepIndex)
            }
            if isDigits { obs.level = audioCaptureManager.level() }
            let display = runner.advance(obs)
            // Bank while the gate passes, within the step's share, and (Head
            // Turn) only while the asked pose is held.
            let framesThisStep = frameBuffer.count - stepStartCount
            let reason = runner.bankReason
            let allowed = reason == .onTarget || (reason == .settled && framesThisStep < Self.settledFramesPerStep)
            isCapturingFrames = banksFrames && obs.facePresent && !obs.held && allowed
                && framesThisStep < stepQuota
            guideLock.lock(); challengeRules = runner.gateRules; guideLock.unlock()
            onChallengeUpdate?(display)
            if display.finished { break }
        }
        challengeResponseBuilder.setStepEvents(runner.stepLog, start: clock)
        let steps = runner.stepLog.map { e -> String in
            let reaction = e.reachedAt.map { String(format: " %.0fms", ($0 - e.promptedAt) * 1000) } ?? ""
            return "\(e.index):\(e.reached.map { $0 ? "reached" : "timed_out" } ?? "timed")\(reaction)"
        }
        USTrace.log("challenge: \(spec.challengeType.rawValue) finished, retries left \(runner.retriesLeft),"
            + " steps [\(steps.joined(separator: ", "))]")
    }

    /// Follow Dot: frames a waypoint banks after the dot settles even when
    /// the phone thinks the head isn't on it (the server judges them).
    static let settledFramesPerStep = 2

    /// Frames one challenge step may bank so every later step still gets
    /// its share of what is left (at least `minimum`, the server's
    /// `frames_per_step`, while any remain).
    static func stepFrameQuota(remaining: Int, stepsLeft: Int, minimum: Int = 2) -> Int {
        let remaining = max(0, remaining)
        guard stepsLeft > 0 else { return remaining }
        return max(min(minimum, remaining), remaining / stepsLeft)
    }

    /// Round 2, after "Continue": the challenge on the scan screen, a short
    /// tick, then its upload and the result.
    private func runExtraCheck() async {
        guard claimOnce("extra-check"), let stepUp = serverStepUp else { return }
        do {
            watchdog?.arm(.capture, budget: captureBudget)
            guard try await waitForFirstFrame() else {
                handleError(UseSenseError(code: .noFramesCaptured,
                                          details: "camera delivered no frame within \(Int(firstFrameBudget))s",
                                          isRetryable: true))
                return
            }
            captureStartTime = Date()
            // A fresh gate for round 2 (the fill light, if on, stays on).
            guideLock.lock(); guide.reset(keepFillLight: true); guideLock.unlock()
            challengeResponseBuilder.markStarted()
            frameBuffer.setCapturePhase(.challenge)
            eventEmitter.emit(.challengeStarted, data: ["type": stepUp.challenge.challengeType.rawValue, "round": "2"])
            isCapturingFrames = true
            currentState = .challenge(spec: stepUp.challenge)
            try await runGuidedChallenge(stepUp.challenge)
            isCapturingFrames = false
            challengeResponseBuilder.markCompleted()
            eventEmitter.emit(.challengeCompleted)
            currentState = .extraCheckDone
            try await Task.sleep(nanoseconds: UInt64(Self.extraCheckDoneSeconds * 1_000_000_000))
            serverStepUp = nil
            await finishServerStepUpRound(stepUp)
        } catch is CancellationError {
            return
        } catch {
            handleError(UseSenseError(code: .unknownError, message: "Unexpected error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Inline Step-Up

    private func runInlineStepUp(engine: SuspicionEngine) async {
        guard let config = sessionData?.policy.inlineStepUp, config.enabled else { return }

        currentState = .inlineStepUp(phase: "preparing")
        onInlineStepUpUpdate?(.preparing)
        eventEmitter.emit(.stepUpTriggered, data: ["score": String(format: "%.1f", engine.snapshot().score)])

        // Camera stays active throughout. The challenges read the newest
        // mesh and frame (the banked results stop when the scan ends, so the
        // micro-actions used to be judged on a stale face), and their prompts
        // go to the screen as they open.
        let orchestrator = StepUpOrchestrator()
        stepUpResult = await orchestrator.run(
            suspicionScore: engine.snapshot().score,
            config: config,
            captureFrame: { [weak self] in self?.latestFrameImage() },
            getCurrentPose: { [weak self] in self?.latestMeshResult()?.headPose },
            getCurrentEAR: { [weak self] in
                guard let result = self?.latestMeshResult() else { return nil }
                return (left: result.leftEAR, right: result.rightEAR)
            },
            onPrompt: { [weak self] prompt in
                self?.onInlineStepUpUpdate?(InlineStepUpDisplay(prompt))
            }
        )

        eventEmitter.emit(.stepUpCompleted, data: ["passed": String(stepUpResult?.passed ?? false)])

        // Capture 500ms additional frames post-step-up
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func latestMeshResult() -> FaceMeshResult? {
        latestLock.lock(); defer { latestLock.unlock() }
        return latestMesh
    }

    /// The camera's newest frame as an image (Flash Reflection samples it).
    private func latestFrameImage() -> UIImage? {
        latestLock.lock()
        let buffer = latestPixelBuffer
        latestLock.unlock()
        guard let buffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = frameImageContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func startAudioRecording() {
        eventEmitter.emit(.audioRecordStarted)
        do {
            audioRecordingURL = try audioCaptureManager.startRecording()
        } catch {
            // Audio failure should not block verification
        }
    }

    private func stopAudioIfNeeded() async {
        if audioCaptureManager.isRecording {
            _ = audioCaptureManager.stopRecording()
            eventEmitter.emit(.audioRecordCompleted)
        }
    }

    // MARK: - Upload & Complete

    private func uploadAndCompleteWithSafetyNet() async throws {
        guard let session = sessionData else {
            handleError(UseSenseError(code: .unknownError, message: "No session data available."))
            return
        }

        guard !session.isExpired else {
            handleError(UseSenseError(code: .sessionExpired))
            return
        }

        // Hard-cap frames to server maxFrames
        var frames = frameBuffer.getFrames()
        if let cap = serverMaxFrames ?? sessionData?.upload.maxFrames, frames.count > cap {
            frames = Array(frames.prefix(cap))
        }
        guard !frames.isEmpty else {
            handleError(UseSenseError(code: .noFramesCaptured, isRetryable: true))
            return
        }

        eventEmitter.emit(.captureCompleted, data: ["frame_count": "\(frames.count)"])
        guard let metadataData = await buildCaptureMetadata(session: session, frames: frames) else {
            handleError(UseSenseError(code: .unknownError, message: "Failed to build metadata."))
            return
        }

        // Audio data
        let audioData: Data?
        if let url = audioRecordingURL {
            audioData = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
        } else {
            audioData = audioCaptureManager.stopRecording()
        }

        // Keep the finished capture: a failed upload or completion resumes
        // from here instead of recapturing.
        pendingUpload = PendingUpload(frames: frames, metadata: metadataData, audio: audioData)
        signalsAccepted = false
        await uploadPendingAndComplete(session)
    }

    /// The upload's metadata: every signal round 1 sends (channel integrity,
    /// device telemetry, screen detection, face mesh, verification package,
    /// suspicion, on-device classifier, frame hashes). Round 2 sends the same
    /// blocks for its own frames, so the server can run the same checks on it,
    /// with its challenge response and `step_up_round: 2`; the round-1-only
    /// blocks (inline step-up, covered check, Speak Digits, v4 phases) stay out.
    private func buildCaptureMetadata(session: SessionData, frames: [Data],
                                      round2: StepUpInstruction? = nil) async -> Data? {
        let frameHashes = Array(frameBuffer.getFrameHashes().prefix(frames.count))
        let frameLuminances = frameBuffer.getFrameLuminances()

        // App Attest: waited for once (round 1); round 2 reuses the same fields.
        var attestFields: [String: Any] = attestFieldsCache ?? [:]
        #if canImport(DeviceCheck) && canImport(CryptoKit)
        if attestFieldsCache == nil, let attestTask = appAttestTask {
            attestFields = await Deadline.run(seconds: Self.appAttestWaitSeconds) {
                await attestTask.value
            } ?? {
                attestTask.cancel()
                return ["app_attest_supported": true, "app_attest_timed_out": true]
            }()
        }
        #endif
        attestFieldsCache = attestFields

        // Collect channel integrity and device telemetry
        let channelIntegrity = deviceSignalCollector.collectChannelIntegrity(attestFields: attestFields)
        let deviceTelemetry = deviceSignalCollector.collectDeviceTelemetry()

        // Screen detection signals
        let screenSignals = screenDetectionCollector.collect(frames: frames, luminances: frameLuminances)
        let screenDetection: [String: Any] = [
            "luminance_histogram_spread": screenSignals.luminanceHistogramSpread,
            "edge_energy_ratio": screenSignals.edgeEnergyRatio,
            "frame_luminance_cv": screenSignals.frameLuminanceCv,
            "color_channel_uniformity": screenSignals.colorChannelUniformity
        ]

        // Challenge response
        var challengeResponse: [String: Any]?
        if let challenge = round2?.challenge ?? session.policy.challenge {
            challengeResponse = challengeResponseBuilder.build(challenge: challenge)
        }

        // Face mesh signals
        let meshResults = faceMeshManager.getResults()
        var faceMeshSignals: [String: Any]?
        if !meshResults.isEmpty {
            faceMeshSignals = [
                "model": MediaPipeModelInfo.versionLabel,
                "model_sha256": MediaPipeModelInfo.sha256,
                "model_source": MediaPipeModelInfo.sourceUrl,
                "frame_count": meshResults.count,
                "frames": meshResults.map { result -> [String: Any] in
                    [
                        "frame_index": result.frameIndex,
                        "timestamp_ms": result.timestampMs,
                        "headPose": ["yaw": result.headPose.yaw, "pitch": result.headPose.pitch, "roll": result.headPose.roll],
                        "leftEAR": result.leftEAR,
                        "rightEAR": result.rightEAR,
                        "bbox": ["x": result.bbox.x, "y": result.bbox.y, "w": result.bbox.w, "h": result.bbox.h]
                    ]
                }
            ]
        }

        // Verification package (Geometric Coherence).
        // Build whenever the server asks for on-device mesh — either via the
        // full dual-path flow (dualPathEnabled) or the lighter mesh-only signal
        // (onDevice3dmmRequired). The two were previously conflated: the gate only
        // honoured dualPathEnabled, so flow-run sessions that set
        // on_device_3dmm_required=true (mesh wanted, dual-path off) never built the
        // package and scored a server-side "mesh absent" penalty. Decouple them.
        let meshRequested = session.geometricCoherence?.dualPathEnabled == true
            || session.geometricCoherence?.onDevice3dmmRequired == true
        var verificationPackage: [String: Any]?
        if meshRequested, !meshResults.isEmpty {
            // One fit per mesh, by position: a failed fit leaves its frame
            // without an entry instead of shifting every later frame.
            let fittingResults = meshResults.map { mesh in
                threeDMMFitter.fit(landmarks: mesh.landmarks, pose: mesh.headPose)
            }
            verificationPackage = verificationPackageBuilder.build(
                meshResults: meshResults,
                fittingResults: fittingResults,
                frameHashes: frameHashes,
                // An omitted challenge decodes as ""; treat it as absent.
                meshBindingChallenge: session.geometricCoherence?.meshBindingChallenge.nilIfEmpty,
                attestFields: attestFields,
                evidence: session.evidence != nil
            )
        }

        // EVIDENCE-v1 `metadata.evidence` (round 1; absent when the server
        // issued no contract, so old servers see the upload as before).
        var evidenceBlock: [String: Any]?
        if round2 == nil, let issued = session.evidence {
            evidenceBlock = await buildEvidenceBlock(issued: issued, session: session,
                                                     verificationPackage: verificationPackage,
                                                     attestFields: attestFields)
        }

        // Suspicion engine data (ALWAYS included per spec)
        var suspicionData: [String: Any]?
        if let engine = suspicionEngine {
            let snapshot = engine.snapshot()
            suspicionData = [
                "final_score": snapshot.score,
                "triggered": engine.triggered,
                "snapshot": [
                    "score": snapshot.score,
                    "signals": snapshot.signals.map { signal -> [String: Any] in
                        ["name": signal.name, "score": signal.score, "weight": signal.weight, "detail": signal.detail]
                    },
                    "framesAnalyzed": snapshot.framesAnalyzed,
                    "reliable": snapshot.reliable,
                    "timestamp": snapshot.timestamp
                ] as [String: Any]
            ]
        }

        // v4.2: On-device antispoof classifier.
        // When opted in AND the model artifact is available, score each captured
        // frame within the MediaPipe face bbox and attach per-frame spoof
        // probabilities to the metadata upload. When disabled or unavailable,
        // the server path remains authoritative.
        var deepClassifierOnDevice: [String: Any]?
        if config.options?.antispoofOnDeviceEnabled == true {
            let classifier = AntiSpoofClassifier(enabled: true)
            if classifier.isAvailable, !meshResults.isEmpty {
                var samples: [[String: Any]] = []
                var modelVersion = "v1"
                for (frameIdx, frameData) in frames.enumerated() {
                    guard frameIdx < meshResults.count else { break }
                    guard let image = UIImage(data: frameData) else { continue }
                    let mesh = meshResults[frameIdx]
                    // bbox is in normalised [0,1] image coords with top-left origin;
                    // convert to Vision's bottom-left origin for the classifier.
                    let vx = CGFloat(mesh.bbox.x)
                    let vw = CGFloat(mesh.bbox.w)
                    let vh = CGFloat(mesh.bbox.h)
                    let vy = 1.0 - CGFloat(mesh.bbox.y) - vh
                    let visionBbox = CGRect(x: vx, y: vy, width: vw, height: vh)
                    if let sample = classifier.predict(image: image, frameIndex: frameIdx, boundingBox: visionBbox) {
                        samples.append([
                            "frameIndex": sample.frameIndex,
                            "spoofProbability": sample.spoofProbability,
                            "latencyMs": sample.latencyMs,
                            "modelVersion": sample.modelVersion,
                            "backbone": sample.backbone
                        ])
                        modelVersion = sample.modelVersion
                    }
                }
                if !samples.isEmpty {
                    deepClassifierOnDevice = [
                        "modelVersion": modelVersion,
                        "backbone": "efficientnet_b0",
                        "threshold": 0.5,
                        "samples": samples
                    ]
                }
            } else if let err = classifier.availabilityError {
                print("[UseSense] antispoof classifier unavailable -- falling back to server: \(err)")
            }
        }

        // Inline step-up data (only when triggered, per spec)
        var inlineStepUpData: [String: Any]?
        if round2 == nil, let result = stepUpResult {
            var isuData: [String: Any] = [
                "challengesRun": result.challengesRun,
                "triggerSuspicionScore": result.triggerSuspicionScore,
                "passed": result.passed,
                "hardReject": result.hardReject,
                "timestamp": result.timestamp
            ]
            if let flash = result.flashReflection {
                isuData["flashReflection"] = [
                    "type": "flash_reflection",
                    "flashes": flash.flashes.map { f -> [String: Any] in
                        [
                            "color": f.color,
                            "durationMs": f.durationMs,
                            "baselineRgb": [f.baselineRgb.r, f.baselineRgb.g, f.baselineRgb.b],
                            "flashRgb": [f.flashRgb.r, f.flashRgb.g, f.flashRgb.b],
                            "colorDelta": f.colorDelta,
                            "reflectionDetected": f.reflectionDetected
                        ]
                    },
                    "passed": flash.passed,
                    "confidence": flash.confidence,
                    "overallColorDelta": flash.overallColorDelta
                ] as [String: Any]
            }
            if let rmas = result.rmas {
                isuData["rmas"] = [
                    "type": "rmas",
                    "actions": rmas.actions.map { a -> [String: Any] in
                        var action: [String: Any] = [
                            "actionType": a.actionType,
                            "label": a.label,
                            "windowMs": a.windowMs,
                            "completed": a.completed
                        ]
                        if let rt = a.reactionTimeMs { action["reactionTimeMs"] = rt }
                        return action
                    },
                    "passed": rmas.passed,
                    "confidence": rmas.confidence,
                    "actionsCompleted": rmas.actionsCompleted,
                    "actionsTotal": rmas.actionsTotal
                ] as [String: Any]
            }
            inlineStepUpData = isuData
        }

        // Build capture config
        let captureConfig: [String: Any] = [
            "captureDurationMs": session.upload.captureDurationMs,
            "targetFps": session.upload.targetFps,
            "maxFrames": session.upload.maxFrames
        ]

        // Build frames manifest.
        //
        // The resolution was hardcoded to 1280x720 here regardless of what the
        // camera produced or what was actually encoded. The server scales its
        // sharpness thresholds off these values (captureLongEdgeFrom in
        // screen-replay-detector.tsx), so it now reports the real encoded size.
        let timestamps = frameBuffer.getTimestamps()
        let resolutions = frameBuffer.getResolutions()
        let framesManifest: [[String: Any]] = (0..<frames.count).map { i in
            [
                "frame_index": i,
                "capture_timestamp_ms": i < timestamps.count ? Int(timestamps[i] * 1000) : 0,
                "resolution_w": i < resolutions.count ? resolutions[i].width : 0,
                "resolution_h": i < resolutions.count ? resolutions[i].height : 0
            ]
        }

        let startTime = captureStartTime ?? Date()
        let endTime = captureEndTime ?? Date()
        let avgInterval: Int
        if timestamps.count > 1,
           let lastTime = timestamps.last,
           let firstTime = timestamps.first {
            let totalInterval = lastTime - firstTime
            avgInterval = Int((totalInterval / Double(timestamps.count - 1)) * 1000)
        } else {
            avgInterval = 0
        }

        // Build metadata
        do {
            return try metadataBuilder.build(
                sessionId: session.sessionId,
                captureConfig: captureConfig,
                captureStartTime: startTime,
                captureEndTime: endTime,
                sessionStartTime: sessionStartTime,
                framesManifest: framesManifest,
                frameHashes: frameHashes,
                framesCaptured: frames.count,
                framesDropped: framesDropped,
                avgFrameIntervalMs: avgInterval,
                challengeResponse: challengeResponse,
                channelIntegrity: channelIntegrity,
                deviceTelemetry: deviceTelemetry,
                screenDetection: screenDetection,
                faceMeshSignals: faceMeshSignals,
                verificationPackage: verificationPackage,
                suspicion: suspicionData,
                inlineStepUp: inlineStepUpData,
                deepClassifierOnDevice: deepClassifierOnDevice,
                framePhases: round2 == nil && config.options?.liveSenseV4Enabled == true
                    ? frameBuffer.getFramePhases()
                    : nil,
                zoomMotion: round2 == nil && config.options?.liveSenseV4Enabled == true
                    ? buildZoomMotionStats(framePhases: frameBuffer.getFramePhases())
                    : nil,
                coveredCheck: round2 == nil ? coveredCheckJSON() : nil,
                audioChallengeResponse: round2 == nil ? audioChallengeResponse : nil,
                extra: round2 == nil
                    ? (evidenceBlock.map { ["evidence": $0] } ?? [:])
                    : ["step_up_round": 2, "capture_channel": "ios"]
            )
        } catch {
            return nil
        }
    }

    /// `metadata.evidence`: capability, the colour and closer records, and
    /// binding v2 (an App Attest assertion over the evidence digest).
    private func buildEvidenceBlock(issued: EvidenceConfig, session: SessionData,
                                    verificationPackage: [String: Any]?,
                                    attestFields: [String: Any]) async -> [String: Any] {
        let capability = evidenceCapability
        let colour: ColourEvidence? = await MainActor.run { colourPlayer?.record }
        let digestFrames = EvidenceDigest.frames(fromPackage: verificationPackage)
        // Closer frames must point at uploaded frames with a mesh entry.
        var closer = closerEvidence
        // The step was not part of this flow (flag off, or the v4 zoom flow).
        if guidedCapture, closer == nil { closer = .skipped(.disabled) }
        if let c = closer { closer = c.restricted(to: Set(digestFrames.map(\.frameIndex))) }
        var block = EvidenceUploadBlock(capability: capability, colour: colour, closer: closer, binding: nil)

        #if canImport(DeviceCheck) && canImport(CryptoKit)
        if issued.bindingV2Enabled, capability.bindingV2, verificationPackage != nil,
           let challenge = session.geometricCoherence?.meshBindingChallenge.nilIfEmpty {
            let digest = EvidenceDigest.digest(sessionId: session.sessionId, challenge: challenge,
                                               frames: digestFrames, colour: colour, closer: closer)
            var binding = BindingV2Evidence(digest: digest)
            if let keyId = attestFields["app_attest_key_id"] as? String {
                let manager = appAttestManager
                let result: Result<String, Error>? = await Deadline.run(seconds: Self.appAttestWaitSeconds) {
                    do { return .success(try await manager.generateAssertion(keyId: keyId, clientData: digest)) }
                    catch { return .failure(error) }
                }
                switch result {
                case .success(let assertion)?:
                    binding.keyId = keyId
                    binding.assertion = assertion
                case .failure(let error)?:
                    let ns = error as NSError
                    binding.error = (name: "\(ns.domain)#\(ns.code)", message: ns.localizedDescription)
                case nil:
                    binding.error = (name: "Timeout", message: "App Attest assertion took over \(Int(Self.appAttestWaitSeconds))s")
                }
            } else {
                binding.error = (name: "NoAttestedKey", message: "App Attest key unavailable for this session")
            }
            USTrace.log("evidence: binding v2 digest=\(digest.prefix(12)) signed=\(binding.assertion != nil)"
                + (binding.error.map { " error=\($0.name)" } ?? ""))
            block.binding = binding
        }
        #endif
        USTrace.log("evidence: frames=\(digestFrames.count) colour=\(colour?.segments.count ?? -1)"
            + " closer=\(closer.map { $0.completed ? "done" : ($0.skippedReason?.rawValue ?? "-") } ?? "nil")")
        return block.json
    }

    /// Upload the kept capture (round 1), then complete. Also the "Retry" path.
    private func uploadPendingAndComplete(_ session: SessionData) async {
        guard let pending = pendingUpload else {
            handleError(UseSenseError(code: .noFramesCaptured, isRetryable: true))
            return
        }
        uploadAttempted = true
        watchdog?.arm(.upload, budget: uploadBudget)
        USTrace.log("upload: start (path 1)")
        currentState = .uploading(progress: 0)
        eventEmitter.emit(.uploadStarted)

        let uploadResponse: UploadSignalsResponse
        do {
            USTrace.log("upload: calling apiClient.uploadSignals")
            uploadResponse = try await apiClient.uploadSignals(
                sessionId: session.sessionId,
                sessionToken: session.sessionToken,
                nonce: session.nonce,
                frames: pending.frames,
                metadata: pending.metadata,
                audio: pending.audio
            )
            eventEmitter.emit(.uploadCompleted)
            USTrace.log("upload: accepted")
            currentState = .uploading(progress: 1.0)
        } catch let error as UseSenseError {
            USTrace.log("upload: failed \(error.code.rawValue) \(error.message)")
            handleError(error)
            return
        } catch {
            handleError(UseSenseError(code: .networkError, message: error.localizedDescription, isRetryable: true))
            return
        }
        signalsAccepted = true

        // A server Step-up rule may ask for one more challenge in this session.
        // Round 2 is a new capture, so round 1's frames are no longer the
        // thing to resend.
        if let stepUp = StepUpInstruction(payload: uploadResponse.stepUp) {
            pendingUpload = nil
            signalsAccepted = false
            await startServerStepUpRound(stepUp)
            return
        }

        await completeSessionWithSafetyNet(session)
    }

    // MARK: - Server step-up (round 2)

    /// Round 1 uploaded and a server Step-up rule asked for one more
    /// challenge. The camera was stopped before the upload, so restart it; the
    /// 3-2-1 countdown covers the warm-up. Then present the requested
    /// challenge on a fresh frame buffer; the challenge view calls
    /// `challengeCompleted()`, which hands off to `finishServerStepUpRound`.
    private func startServerStepUpRound(_ stepUp: StepUpInstruction) async {
        serverStepUp = stepUp
        frameBuffer.reset()
        challengeResponseBuilder.reset()
        // Round 2 reports its own signals: its mesh, suspicion score, sensors
        // and dropped frames start over (round 1's are already on the server).
        faceMeshManager.reset()
        suspicionEngine?.reset()
        framesDropped = 0
        deviceSignalCollector.startSensorCollection()
        reconfigureFrameBuffer(maxFrames: stepUp.maxFrames, targetFps: sessionData?.upload.targetFps ?? 3)
        setCameraLive(false)
        frameCaptureManager.start()
        if guidedExtraCheck {
            // "One more quick check": one sentence, one button. The camera
            // warms up behind the sheet; the watchdog arms on Continue, so a
            // person reading the sheet is never timed out.
            watchdog?.disarm()
            eventEmitter.emit(.stepUpTriggered, data: ["round": "2", "type": stepUp.challenge.challengeType.rawValue])
            currentState = .extraCheckIntro(spec: stepUp.challenge)
            return
        }
        watchdog?.arm(.capture, budget: captureBudget)
        captureStartTime = Date()
        isCapturingFrames = true
        do {
            for i in stride(from: 3, through: 1, by: -1) {
                currentState = .countdown(number: i)
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            return
        }
        challengeResponseBuilder.markStarted()
        frameBuffer.setCapturePhase(.challenge)
        eventEmitter.emit(.challengeStarted, data: ["type": stepUp.challenge.challengeType.rawValue, "round": "2"])
        currentState = .challenge(spec: stepUp.challenge)
    }

    /// Upload the step-up round (`?round=2`): its frames and challenge response only. Then complete.
    private func finishServerStepUpRound(_ stepUp: StepUpInstruction) async {
        frameCaptureManager.stop()
        guard let session = sessionData else {
            handleError(UseSenseError(code: .unknownError, message: "No session data available."))
            return
        }
        let frames = Array(frameBuffer.getFrames().prefix(stepUp.maxFrames))
        guard !frames.isEmpty else {
            handleError(UseSenseError(code: .noFramesCaptured, isRetryable: true))
            return
        }
        captureEndTime = Date()
        deviceSignalCollector.stopSensorCollection()
        guard let metadataData = await buildCaptureMetadata(session: session, frames: frames, round2: stepUp) else {
            handleError(UseSenseError(code: .unknownError, message: "Failed to build metadata."))
            return
        }
        lastRound2MetadataForTesting = metadataData
        uploadAttempted = true
        watchdog?.arm(.upload, budget: uploadBudget)
        USTrace.log("upload: start (path 2)")
        currentState = .uploading(progress: 0)
        do {
            _ = try await apiClient.uploadSignals(
                sessionId: session.sessionId,
                sessionToken: session.sessionToken,
                nonce: session.nonce,
                frames: frames,
                metadata: metadataData,
                audio: nil,
                round: 2
            )
            currentState = .uploading(progress: 1.0)
            signalsAccepted = true
        } catch let error as UseSenseError {
            handleError(error)
            return
        } catch {
            handleError(UseSenseError(code: .networkError, message: error.localizedDescription))
            return
        }
        await completeSessionWithSafetyNet(session)
    }

    private func completeSessionWithSafetyNet(_ session: SessionData) async {
        // Complete
        currentState = .completing
        eventEmitter.emit(.completeStarted)

        do {
            let fullDecision = try await apiClient.completeSession(
                sessionId: session.sessionId,
                sessionToken: session.sessionToken,
                nonce: session.nonce
            )
            let redacted = fullDecision.redacted()
            eventEmitter.emit(.decisionReceived, data: ["decision": redacted.decision])
            currentState = .done(decision: redacted)
        } catch let error as UseSenseError {
            handleError(error)
        } catch {
            handleError(UseSenseError(code: .serverError, message: error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private var needsAudio: Bool {
        guard let policy = sessionData?.policy else {
            switch config.options?.audioEnabled {
            case .always: return true
            case .never: return false
            default: return false
            }
        }
        if policy.requiresAudio { return true }
        if policy.audioChallenge != nil { return true }
        switch config.options?.audioEnabled {
        case .always: return true
        case .never: return false
        default: return policy.requiresAudio
        }
    }

    private func handleError(_ error: UseSenseError) {
        USTrace.log("handleError \(error.code.rawValue): \(error.message) [state \(storedState.debugName)]")
        if isStaleContext { return }
        // Stop the camera and mic too: an error screen over a live camera is
        // a capture that never ended.
        isCapturingFrames = false
        frameCaptureManager.stop()
        if audioCaptureManager.isRecording { _ = audioCaptureManager.stopRecording() }
        deviceSignalCollector.release()
        faceMeshManager.teardown()
        coverSegmenter.release()
        eventEmitter.emit(.error, data: ["code": error.code.rawValue, "message": error.message])
        currentState = .error(error)
    }
}

// MARK: - Attempts + watchdog

extension UseSenseSession {
    private var currentAttempt: Int {
        attemptLock.lock(); defer { attemptLock.unlock() }
        return attempt
    }

    /// True when running inside a task that belongs to a superseded attempt.
    private var isStaleContext: Bool {
        guard let token = Self.attemptToken else { return false }
        return token != currentAttempt
    }

    /// Runs one unit of session work as part of the current attempt, so the
    /// watchdog, a retry or a cancel can cancel it and mute its late writes.
    private func runAttempt(_ body: @escaping @Sendable () async -> Void) async {
        let token = currentAttempt
        let task = Task { await Self.$attemptToken.withValue(token) { await body() } }
        trackAttemptTask(task, add: true)
        await task.value
        trackAttemptTask(task, add: false)
    }

    private func trackAttemptTask(_ task: Task<Void, Never>, add: Bool) {
        attemptLock.lock(); defer { attemptLock.unlock() }
        if add { attemptTasks.append(task) } else { attemptTasks.removeAll { $0 == task } }
    }

    /// Abandon the attempt in flight: cancel its work and mute its writes.
    private func invalidateAttempt() {
        attemptLock.lock()
        attempt += 1
        let tasks = attemptTasks
        attemptTasks.removeAll()
        attemptLock.unlock()
        tasks.forEach { $0.cancel() }
        appAttestTask?.cancel()
        watchdog?.disarm()
    }

    /// The watchdog's verdict: the phase ran out of time. End the attempt in a
    /// retryable error with a stable code, never a spinner or a silent close.
    func handleWatchdogTimeout(_ phase: SessionWatchdog.Phase) {
        // The watchdog's timer task is created inside an attempt and inherits
        // its task-local attempt token. invalidateAttempt() below makes that
        // token stale, so without clearing it the timeout's own error was
        // dropped as a "late write from an old attempt": the fail-safe fired
        // and the screen stayed on its spinner forever (seen on an iPhone in a
        // Flows face step, 2026-11-07).
        Self.$attemptToken.withValue(nil) {
            USTrace.log("watchdog FIRED: \(phase.rawValue) in state \(storedState.debugName), terminal=\(storedState.isTerminal)")
            guard !storedState.isTerminal else { return }
            let stateName = storedState.debugName
            invalidateAttempt()
            handleError(UseSenseError(
                code: phase.errorCode,
                details: "watchdog: \(phase.rawValue) phase exceeded its budget in state \(stateName)",
                isRetryable: true
            ))
        }
    }

    /// True once per attempt for `key`: the first caller wins, later callers
    /// (a duplicate tap, a second completion) get false. Claimed under the
    /// attempt lock before any await, so two racing tasks can't both pass.
    func claimOnce(_ key: String) -> Bool {
        attemptLock.lock(); defer { attemptLock.unlock() }
        let owner = Self.attemptToken ?? attempt
        let inserted = claims.insert("\(owner):\(key)").inserted
        if !inserted { USTrace.log("claimOnce REJECTED duplicate: \(key) (owner \(owner))") }
        return inserted
    }

    /// Undo `claimOnce(key)` for the current attempt, so the step can run
    /// again (the guided scan going back to the align screen).
    func releaseClaim(_ key: String) {
        attemptLock.lock(); defer { attemptLock.unlock() }
        let owner = Self.attemptToken ?? attempt
        claims.remove("\(owner):\(key)")
    }

    var isCameraLive: Bool {
        cameraLiveLock.lock(); defer { cameraLiveLock.unlock() }
        return cameraLiveFlag
    }

    func setCameraLive(_ live: Bool) {
        cameraLiveLock.lock(); cameraLiveFlag = live; cameraLiveLock.unlock()
    }

    /// Waits for the camera's first frame. False if none came within
    /// `firstFrameBudget`; throws if the attempt was cancelled.
    func waitForFirstFrame() async throws -> Bool {
        let deadline = Date().addingTimeInterval(firstFrameBudget)
        while !isCameraLive {
            try Task.checkCancellation()
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// Test seam: the state the UI is showing.
    var stateForTesting: SessionState { storedState }

    /// Test seam: put the session into a capture state without a camera.
    func enterStateForTesting(_ state: SessionState) { currentState = state }

    /// Test seam: arm the session's own watchdog with its configured budget.
    func armWatchdogForTesting(_ phase: SessionWatchdog.Phase) {
        watchdog?.arm(phase, budget: phase == .capture ? captureBudget : uploadBudget)
    }

    var watchdogPhaseForTesting: SessionWatchdog.Phase? { watchdog?.armedPhase }

    /// Test seam: arm the watchdog from inside the current attempt, the way the
    /// real upload does, so its timer task inherits the attempt token.
    func armWatchdogInsideAttemptForTesting(_ phase: SessionWatchdog.Phase) {
        Self.$attemptToken.withValue(currentAttempt) { armWatchdogForTesting(phase) }
    }

    /// Test seam: run the inline step-up as the capture does (policy permitting).
    func runInlineStepUpForTesting(engine: SuspicionEngine) async -> StepUpResult? {
        await runInlineStepUp(engine: engine)
        return stepUpResult
    }

    /// Test seam: hand the delegate a face as if the camera had seen it.
    func setLatestMeshForTesting(_ mesh: FaceMeshResult?) {
        latestLock.lock(); latestMesh = mesh; latestLock.unlock()
    }

    /// Test seam: the metadata an upload would carry for these frames.
    func captureMetadataForTesting(frames: [Data], round2: StepUpInstruction?) async -> [String: Any]? {
        guard let session = sessionData,
              let data = await buildCaptureMetadata(session: session, frames: frames, round2: round2) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Test seam: a round-1 upload came back asking for a step-up.
    func startServerStepUpRoundForTesting(_ stepUp: StepUpInstruction) async {
        await startServerStepUpRound(stepUp)
    }

    /// Test seam: "Do a head movement instead" without the permission prompts
    /// that follow it (no camera in a unit test).
    func applyMovementFallbackForTesting() async throws -> SessionPolicy {
        guard let data = sessionData else { throw UseSenseError(code: .unknownError) }
        do {
            let response = try await apiClient.requestChallengeFallback(
                sessionId: data.sessionId, sessionToken: data.sessionToken, nonce: data.nonce)
            sessionData?.policy = response.policy
            return response.policy
        } catch let error as UseSenseError {
            throw Self.fallbackError(error)
        }
    }

    /// Test seam: put the session where a finalization failure leaves it.
    func setFinalizationCheckpointForTesting(pendingFrames: [Data]?, signalsAccepted accepted: Bool) {
        pendingUpload = pendingFrames.map { PendingUpload(frames: $0, metadata: Data("{}".utf8), audio: nil) }
        signalsAccepted = accepted
    }
}

// MARK: - FrameCaptureDelegate

extension UseSenseSession: FrameCaptureDelegate {
    func frameCaptureManager(_ manager: FrameCaptureManager, didCapture pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        if !isCameraLive { setCameraLive(true) }
        // Quality analysis at 4Hz
        if qualityAnalyzer.shouldAnalyze() {
            let report = qualityAnalyzer.analyze(pixelBuffer)
            latestQualityReport = report
            onQualityUpdate?(report)
            eventEmitter.emit(.imageQualityCheck, data: [
                "score": String(format: "%.1f", report.overallScore),
                "quality": report.qualityLevel.rawValue,
                "acceptable": report.isAcceptable ? "true" : "false",
                "blur": String(format: "%.1f", report.laplacianVariance),
                "brightness": String(format: "%.1f", report.meanBrightness)
            ])
        }

        // Run face mesh analysis on every camera frame — the suspicion
        // engine consumes per-frame telemetry during the face guide stage
        // as well as active capture. The returned result is also the
        // input the verification package needs, but only for frames that
        // are ALSO being buffered to the JPEG upload buffer below. See
        // `FaceMeshManager.recordResult` for the full rationale.
        let timestampMs = Int64(CMTimeGetSeconds(timestamp) * 1000)
        // EVIDENCE-v1 capture clock: ms since the camera's first frame, on the
        // host clock the colour sequence's display link also uses.
        let host = manager.hostSeconds(for: timestamp)
        latestLock.lock()
        if captureClockOrigin == nil { captureClockOrigin = host }
        let captureMs = max(0, Int(((host - (captureClockOrigin ?? host)) * 1000).rounded()))
        latestLock.unlock()
        let meshResult = faceMeshManager.processFrame(pixelBuffer, timestampMs: timestampMs, captureMs: captureMs)
        latestLock.lock()
        latestMesh = meshResult
        latestPixelBuffer = pixelBuffer
        latestLock.unlock()
        if let meshResult = meshResult {
            // Feed suspicion engine (runs on every 2nd frame internally)
            let luminance = latestQualityReport.map { Double($0.meanBrightness) } ?? 128.0
            let sharpness = latestQualityReport.map { Double($0.laplacianVariance) } ?? 50.0
            suspicionEngine?.analyzeFrame(pose: meshResult.headPose, luminance: luminance, sharpness: sharpness)
        }

        if guidedCapture {
            updateGuide(pixelBuffer: pixelBuffer, mesh: meshResult, time: CMTimeGetSeconds(timestamp))
        }

        // Only store frames during active capture phases
        guard isCapturingFrames else { return }

        // If face mesh failed for this camera frame (face not detected,
        // MediaPipe throw, etc.), skip capture entirely — do NOT even
        // consult `frameBuffer.shouldCapture()`, because that method
        // mutates `lastCaptureTime` as a side effect and would burn the
        // throttle slot on a frame we cannot pair. Waiting for the next
        // frame with a valid mesh result keeps the capture cadence
        // aligned and preserves the invariant that `meshResults[i]`
        // and `frameHashes[i]` are always the same camera frame.
        guard let meshResult = meshResult else { return }

        bankLock.lock()
        defer { bankLock.unlock() }
        // Re-checked under the lock: the guided scan may have paused.
        guard isCapturingFrames else { return }
        // Closer step: only frames close enough count as near frames.
        if let near = nearBankThreshold {
            let aspect = Double(CVPixelBufferGetHeight(pixelBuffer)) / Double(max(1, CVPixelBufferGetWidth(pixelBuffer)))
            guard let eye = Self.eyeDistance(meshResult.landmarks, aspect: aspect), eye >= near else { return }
        }
        if frameBuffer.shouldCapture() && !frameBuffer.isFull {
            let frameIndex = frameBuffer.count
            frameBuffer.addFrame(pixelBuffer, timestamp: CMTimeGetSeconds(timestamp))
            // Record the mesh result in the SAME delegate callback that
            // buffers the JPEG, so array indices line up 1:1 downstream.
            faceMeshManager.recordResult(meshResult)
            challengeResponseBuilder.recordFrame(frameIndex: frameIndex, timestampMs: timestampMs)
            eventEmitter.emit(.frameCaptured, data: ["count": "\(frameBuffer.count)"])
        } else if frameBuffer.isFull {
            framesDropped += 1
        }
    }

    func frameCaptureManager(_ manager: FrameCaptureManager, didFailWithError error: Error) {
        handleError(UseSenseError(code: .captureFailed, message: "Camera error: \(error.localizedDescription)"))
    }
}

// MARK: - Guided capture gate

/// What the capture screen needs from the gate each update.
struct GuidedCaptureUpdate: Equatable, Sendable {
    var snapshot: GuideSnapshot
    /// Show the shutter button (20 s on the align screen, or 3 abandoned scans).
    var shutterAvailable: Bool
}

/// Ring progress of the guided scan.
struct ScanProgress: Equatable, Sendable {
    var fraction: Double
    var paused: Bool
    var bankedSeconds: TimeInterval
    var totalSeconds: TimeInterval
    var completed: Bool
}

extension UseSenseSession {
    /// Longest wait for the final covered-face check before finishing anyway.
    static let finalCoverWait: TimeInterval = 2.5

    /// Stillness anchors: nose tip, eye outer corners, chin, forehead.
    static let stillnessAnchors = [1, 33, 263, 152, 10]
    /// Speak Digits: the same without the chin, which moves when speaking.
    static let speakingStillnessAnchors = [1, 33, 263, 10]

    /// Iris-centre distance / frame width (eye-corner midpoints without iris points).
    static func eyeDistance(_ lm: [(x: Double, y: Double, z: Double)], aspect: Double) -> Double? {
        let l: (Double, Double), r: (Double, Double)
        if lm.count >= 478 {
            l = (lm[468].x, lm[468].y); r = (lm[473].x, lm[473].y)
        } else if lm.count >= 468 {
            l = ((lm[33].x + lm[133].x) / 2, (lm[33].y + lm[133].y) / 2)
            r = ((lm[362].x + lm[263].x) / 2, (lm[362].y + lm[263].y) / 2)
        } else {
            return nil
        }
        // y is normalised by height: scale to width units (aspect = H / W).
        return hypot(r.0 - l.0, (r.1 - l.1) * aspect)
    }

    /// Iris-centre distance in screen points (eye-corner midpoints without iris points).
    static func screenEyeDistance(_ p: [CGPoint]) -> CGFloat? {
        if p.count >= 478 { return hypot(p[473].x - p[468].x, p[473].y - p[468].y) }
        guard p.count >= 468 else { return nil }
        let l = CGPoint(x: (p[33].x + p[133].x) / 2, y: (p[33].y + p[133].y) / 2)
        let r = CGPoint(x: (p[362].x + p[263].x) / 2, y: (p[362].y + p[263].y) / 2)
        return hypot(r.x - l.x, r.y - l.y)
    }

    /// MediaPipe FACEMESH_FACE_OVAL: the face silhouette ring.
    static let faceOvalIndices = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378,
                                  400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21,
                                  54, 103, 67, 109]

    /// Spec v1.2.1: face centre (mean of 10, 152, 234, 454) relative to the
    /// expected face centre (oval cx, oval cy + 0.25 ry), in units of (rx, ry).
    static func faceCentreOffset(_ points: [CGPoint], oval: CGRect) -> CGPoint? {
        guard points.count > 454, oval.width > 0, oval.height > 0 else { return nil }
        let ids = [10, 152, 234, 454]
        let cx = ids.reduce(0) { $0 + points[$1].x } / 4
        let cy = ids.reduce(0) { $0 + points[$1].y } / 4
        let rx = oval.width / 2, ry = oval.height / 2
        return CGPoint(x: (cx - oval.midX) / rx, y: (cy - (oval.midY + 0.25 * ry)) / ry)
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var r = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// Runs on the capture queue for every camera frame of a guided session.
    fileprivate func updateGuide(pixelBuffer: CVPixelBuffer, mesh: FaceMeshResult?, time: TimeInterval) {
        let state = storedState
        let onCaptureScreen: Bool
        let inChallenge: Bool
        switch state {
        case .faceGuide, .baseline: onCaptureScreen = true; inChallenge = false
        // The same quality gate runs during a challenge (before the scan or
        // round 2), with the step's pose allowance.
        case .challenge where guidedExtraCheck: onCaptureScreen = true; inChallenge = true
        default: onCaptureScreen = false; inChallenge = false
        }
        guard onCaptureScreen else { return }

        let bufferW = Double(CVPixelBufferGetWidth(pixelBuffer))
        let bufferH = Double(CVPixelBufferGetHeight(pixelBuffer))
        guideLock.lock()
        let viewport = viewportSize
        let rules = inChallenge ? challengeRules : nil
        let scale = ovalScale
        guideLock.unlock()

        let isScanning: Bool
        if case .baseline = state { isScanning = true } else { isScanning = false }
        var observation = GateObservation.noFace(at: time)
        var facePoint: CGPoint?
        if let mesh, bufferW > 0, bufferH > 0 {
            let mapper = PreviewMapper(bufferSize: CGSize(width: bufferW, height: bufferH), viewSize: viewport)
            let points = mesh.landmarks.map { mapper.viewPoint(x: $0.x, y: $0.y) }
            let oval = CaptureOvalLayout.ovalRect(in: viewport, scale: scale)
            // Spec v1.2.2: eye ratio = eye distance / (oval width / 0.72), in
            // screen space (= screen width on a phone). Stillness anchors use
            // the same unit so jitter / eye distance stays consistent.
            let unit = max(1, oval.width / 0.72)
            observation = GateObservation(
                time: time,
                faceCount: max(1, mesh.gate.faceCount),
                ovalExtent: PreviewMapper.ovalExtent(
                    of: Self.faceOvalIndices.compactMap { $0 < points.count ? points[$0] : nil }, in: oval),
                faceCentreOffset: Self.faceCentreOffset(points, oval: oval),
                eyeDistance: Self.screenEyeDistance(points).map { Double($0 / unit) },
                yaw: mesh.gate.matrixPose?.yaw,
                pitch: mesh.gate.matrixPose?.pitch,
                roll: mesh.gate.matrixPose?.roll,
                face: qualityAnalyzer.analyzeFaceRegion(pixelBuffer, faceRect: mesh.bbox),
                eyeBlinkLeft: mesh.gate.eyeBlinkLeft,
                eyeBlinkRight: mesh.gate.eyeBlinkRight,
                anchors: (rules?.checksStillness == true ? Self.speakingStillnessAnchors : Self.stillnessAnchors).compactMap { i in
                    i < points.count ? CGPoint(x: points[i].x / unit, y: points[i].y / unit) : nil
                }
            )
            // COVER-v1: segmentation off this thread whenever it is free; the
            // change watch on the scan's frames (image pixels for both).
            if coverSegmenter.available || isScanning {
                let px = mesh.landmarks.map { CGPoint(x: $0.x * bufferW, y: $0.y * bufferH) }
                if coverSegmenter.available {
                    coverSegmenter.offer(pixelBuffer, points: px, time: time)
                    observation.cover = coverSegmenter.latest(at: time)
                    observation.coverPending = observation.cover == nil
                }
                if isScanning { observation.regions = FaceRegions.measure(pixelBuffer, points: px) }
            }
            contourField.submit(points: points, z: mesh.landmarks.map(\.z), viewSize: viewport, time: time)
            facePoint = mapper.viewPoint(x: mesh.bbox.x + mesh.bbox.w / 2, y: mesh.bbox.y + mesh.bbox.h / 2)
            if mesh.gate.faceCount > 1, latestGuide.failing.contains(.onePerson) == false {
                // Rising edge only. Not uploaded in Phase 1 (no wire change).
                USTrace.log("guide: second face in view (\(mesh.gate.faceCount) faces)")
            }
        } else {
            contourField.noFace(at: time)
            coverSegmenter.clear()
        }

        let isAlign: Bool
        if case .faceGuide = state { isAlign = true } else { isAlign = false }
        var shutter = isAlign && (pausedWindows >= Self.shutterAfterPausedWindows
            || (alignStartedAt.map { Date().timeIntervalSince($0) >= Self.shutterAfterSeconds } ?? false))
        #if DEBUG
        // Debug rig: a forced screen holds still (no shutter fallback).
        if DebugCaptureRig.forcedState != nil { shutter = false }
        #endif

        guideLock.lock()
        let dt = latestGuideFrameTime.isFinite ? min(0.25, max(0, time - latestGuideFrameTime)) : 0
        latestGuideFrameTime = time
        let snapshot = guide.update(observation, scanning: isScanning, challenge: rules)
        if inChallenge {
            challengeFacePresent = snapshot.allPass
            challengeHint = snapshot.hint
            challengeYaw = mesh?.gate.matrixPose?.yaw
            challengePitch = mesh?.gate.matrixPose?.pitch
        }
        if isScanning && !coverReportScanning {
            let at = coverSegmenter.latestAt
            coverReport.scanStarted(cover: coverSegmenter.latest(at: time),
                                    ageMs: at.isFinite ? Int(((time - at) * 1000).rounded()) : nil)
        }
        if isScanning {
            coverReport.scanFrame(cover: observation.cover, watch: guide.gate.coverWatch,
                                  watchRan: guide.gate.watchRan, rebaselined: guide.gate.rebaselined,
                                  baselineWait: guide.gate.baselineWait)
        }
        if case .faceGuide = state, snapshot.hint == .uncovered { coverReport.alignCovered(seconds: dt) }
        coverReportScanning = isScanning
        guideTraceCounter &+= 1
        if USTrace.enabled, snapshot.failing != latestGuide.failing || guideTraceCounter % 15 == 0 {
            let e = guide.lastEvaluation
            let f = observation.face
            USTrace.log("guide: failing [\(snapshot.failing.sorted().map(\.debugLabel).joined(separator: ","))]"
                + " eye=\(observation.eyeDistance.map { String(format: "%.3f", $0) } ?? "-")"
                + " oval=\(observation.ovalExtent.map { String(format: "%.2f", $0) } ?? "-")"
                + " centreOff=\(observation.faceCentreOffset.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? "-")"
                + " hint=\(snapshot.hint?.title ?? "-")"
                + " yaw=\(observation.yaw.map { String(format: "%.1f", $0) } ?? "-")"
                + " pitch=\(observation.pitch.map { String(format: "%.1f", $0) } ?? "-")"
                + " roll=\(observation.roll.map { String(format: "%.1f", $0) } ?? "-")"
                + " luma=\(f.map { String(format: "%.0f", $0.meanLuma) } ?? "-")"
                + " sharp=\(f.map { String(format: "%.1f", $0.sharpness) } ?? "-")"
                + " jitter=\(e.jitter.map { String(format: "%.3f", $0) } ?? "-")"
                + " cover=\(observation.cover.map { String(format: "%.2f/%.2f", $0.bodySkin, $0.other) } ?? (observation.coverPending ? "pending" : "-"))"
                + (isScanning ? String(format: " watch=%.2f@%@", guide.gate.coverWatch.lastScore,
                                        guide.gate.coverWatch.lastRegion.map { FaceRegions.names[$0] } ?? "-") : ""))
        }
        latestGuide = snapshot
        let update = GuidedCaptureUpdate(snapshot: snapshot, shutterAvailable: shutter)
        let now = CFAbsoluteTimeGetCurrent()
        let previous = lastGuidePublished
        let visibleChange = previous == nil
            || previous?.snapshot.hint != update.snapshot.hint
            || previous?.snapshot.allPass != update.snapshot.allPass
            || previous?.snapshot.fillLight != update.snapshot.fillLight
            || previous?.shutterAvailable != update.shutterAvailable
        let publish = visibleChange || (update != previous && now - lastGuidePublishTime >= 0.1)
        if publish {
            lastGuidePublished = update
            lastGuidePublishTime = now
        }
        var startScan = isAlign && snapshot.allPass && !autoStartRequested
        #if DEBUG
        // Debug rig: a forced screen holds still for screenshots.
        if DebugCaptureRig.forcedState != nil { startScan = false }
        #endif
        if startScan { autoStartRequested = true }
        let refocus = facePoint != nil && now - lastFocusTime >= 0.5
        if refocus { lastFocusTime = now }
        guideLock.unlock()

        if publish && !inChallenge { onGuideUpdate?(update) }
        if startScan {
            USTrace.log("guide: all checks pass, auto start")
            Task { await self.faceReady() }
        }
        if refocus, let facePoint {
            let layer = previewLayer
            let manager = frameCaptureManager
            DispatchQueue.main.async {
                guard let layer, layer.bounds.width > 0 else { return }
                manager.setPointOfInterest(layer.captureDevicePointConverted(fromLayerPoint: facePoint))
            }
        }
    }
}
#endif
