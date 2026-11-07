#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit
import Foundation

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
    /// The contour scan's depth texture (mesh z, smoothed).
    let contourField = ContourDepthField()

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
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if micStatus == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if !granted {
                    eventEmitter.emit(.permissionsDenied, data: ["type": "microphone"])
                    handleError(UseSenseError(code: .micPermissionDenied))
                    return
                }
            } else if micStatus == .denied || micStatus == .restricted {
                eventEmitter.emit(.permissionsDenied, data: ["type": "microphone"])
                handleError(UseSenseError(code: .micPermissionDenied))
                return
            }
        }

        eventEmitter.emit(.permissionsGranted)
        await startCapturePipeline()
    }

    func proceedFromInstructions() async {
        await runAttempt { await self.startFaceGuide() }
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

    /// Seconds the guided scan banks (the shutter copy names it).
    var guidedScanSeconds: Int {
        let ms = sessionData?.upload.captureDurationMs ?? config.options?.captureDurationMs ?? 8000
        let single = sessionData?.policy.challenge == nil && config.options?.liveSenseV4Enabled != true
        return Int((baselineDuration + (single ? Double(ms) / 1000 : 0)).rounded())
    }

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
        uploadAttempted = false
        stepUpResult = nil
        serverStepUp = nil
        resetGuidedState()
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
        frameCaptureManager.start()

        if let challenge = sessionData?.policy.challenge {
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
        onScanUpdate?(ScanProgress(fraction: 0, paused: false, bankedSeconds: 0, totalSeconds: duration, completed: false))
        while banked < duration {
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
                    pausedWindows += 1
                    USTrace.log("scan: pause > \(Self.scanDiscardAfter)s, window \(pausedWindows) dropped")
                    return false
                }
            }
            onScanUpdate?(ScanProgress(fraction: min(1, banked / duration), paused: !passing,
                                       bankedSeconds: banked, totalSeconds: duration, completed: false))
        }
        onScanUpdate?(ScanProgress(fraction: 1, paused: false, bankedSeconds: duration, totalSeconds: duration, completed: true))
        return true
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
            // (the same frames as before). Challenge and v4 sessions are
            // gated at the start only: a head turn needs pose "failures".
            let singleGatedScan = guidedCapture
                && sessionData?.policy.challenge == nil
                && config.options?.liveSenseV4Enabled != true
            if singleGatedScan {
                isCapturingFrames = false
                guard try await runGatedScan(duration: baselineDuration + Double(captureDurationMs) / 1000) else {
                    await returnToAlign()
                    return
                }
            } else if guidedCapture {
                // Challenge / v4 baseline: not gated, but the ring still fills.
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

            if sessionData?.policy.challenge != nil {
                for i in stride(from: 3, through: 1, by: -1) {
                    currentState = .countdown(number: i)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            challengeResponseBuilder.markStarted()
            if let challenge = sessionData?.policy.challenge {
                eventEmitter.emit(.challengeStarted, data: ["type": challenge.challengeType.rawValue])
                frameBuffer.setCapturePhase(.challenge)
                currentState = .challenge(spec: challenge)
            } else {
                if !singleGatedScan {
                    try await Task.sleep(nanoseconds: UInt64(captureDurationMs) * 1_000_000)
                }
                isCapturingFrames = false

                // Check suspicion engine before stopping camera
                if let engine = suspicionEngine, engine.shouldTriggerStepUp() {
                    await runInlineStepUp(engine: engine)
                }

                frameCaptureManager.stop()
                captureEndTime = Date()
                deviceSignalCollector.stopSensorCollection()
                await stopAudioIfNeeded()
                try await uploadAndCompleteWithSafetyNet()
            }
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
        eventEmitter.emit(.stepUpTriggered, data: ["score": String(format: "%.1f", engine.snapshot().score)])

        // Camera stays active throughout
        let orchestrator = StepUpOrchestrator()
        stepUpResult = await orchestrator.run(
            suspicionScore: engine.snapshot().score,
            config: config,
            captureFrame: {
                // In production, capture current frame from preview
                return nil
            },
            getCurrentPose: { [weak self] in
                self?.faceMeshManager.getResults().last?.headPose
            },
            getCurrentEAR: { [weak self] in
                guard let result = self?.faceMeshManager.getResults().last else { return nil }
                return (left: result.leftEAR, right: result.rightEAR)
            }
        )

        eventEmitter.emit(.stepUpCompleted, data: ["passed": String(stepUpResult?.passed ?? false)])

        // Capture 500ms additional frames post-step-up
        try? await Task.sleep(nanoseconds: 500_000_000)
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

        let frameHashes = Array(frameBuffer.getFrameHashes().prefix(frames.count))
        let frameLuminances = frameBuffer.getFrameLuminances()

        eventEmitter.emit(.captureCompleted, data: ["frame_count": "\(frames.count)"])

        // Wait for App Attest
        var attestFields: [String: Any] = [:]
        #if canImport(DeviceCheck) && canImport(CryptoKit)
        if let attestTask = appAttestTask {
            attestFields = await Deadline.run(seconds: Self.appAttestWaitSeconds) {
                await attestTask.value
            } ?? {
                attestTask.cancel()
                return ["app_attest_supported": true, "app_attest_timed_out": true]
            }()
        }
        #endif

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
        if let challenge = session.policy.challenge {
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
            let fittingResults = meshResults.compactMap { mesh in
                threeDMMFitter.fit(landmarks: mesh.landmarks, pose: mesh.headPose)
            }
            verificationPackage = verificationPackageBuilder.build(
                meshResults: meshResults,
                fittingResults: fittingResults,
                frameHashes: frameHashes,
                // An omitted challenge decodes as ""; treat it as absent.
                meshBindingChallenge: session.geometricCoherence?.meshBindingChallenge.nilIfEmpty,
                attestFields: attestFields
            )
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
        if let result = stepUpResult {
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
        let metadataData: Data
        do {
            metadataData = try metadataBuilder.build(
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
                framePhases: config.options?.liveSenseV4Enabled == true
                    ? frameBuffer.getFramePhases()
                    : nil,
                zoomMotion: config.options?.liveSenseV4Enabled == true
                    ? buildZoomMotionStats(framePhases: frameBuffer.getFramePhases())
                    : nil
            )
        } catch {
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
        watchdog?.arm(.capture, budget: captureBudget)
        frameBuffer.reset()
        challengeResponseBuilder.reset()
        reconfigureFrameBuffer(maxFrames: stepUp.maxFrames, targetFps: sessionData?.upload.targetFps ?? 3)
        frameCaptureManager.start()
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
        let metadata: [String: Any] = [
            "session_id": session.sessionId,
            "sdk_version": UseSenseAPIClient.sdkVersion,
            "platform": "ios",
            "source": "sdk",
            "capture_channel": "ios",
            "step_up_round": 2,
            "client_capabilities": StepUpCapability.all,
            "challenge_response": challengeResponseBuilder.build(challenge: stepUp.challenge),
            "frame_hashes": Array(frameBuffer.getFrameHashes().prefix(frames.count)),
        ]
        uploadAttempted = true
        watchdog?.arm(.upload, budget: uploadBudget)
        USTrace.log("upload: start (path 2)")
        currentState = .uploading(progress: 0)
        do {
            let metadataData = try JSONSerialization.data(withJSONObject: metadata)
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
        let meshResult = faceMeshManager.processFrame(pixelBuffer, timestampMs: timestampMs)
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
    /// Stillness anchors: nose tip, eye outer corners, chin, forehead.
    static let stillnessAnchors = [1, 33, 263, 152, 10]

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
        switch state {
        case .faceGuide, .baseline: onCaptureScreen = true
        default: onCaptureScreen = false
        }
        guard onCaptureScreen else { return }

        let bufferW = Double(CVPixelBufferGetWidth(pixelBuffer))
        let bufferH = Double(CVPixelBufferGetHeight(pixelBuffer))
        guideLock.lock()
        let viewport = viewportSize
        guideLock.unlock()

        var observation = GateObservation.noFace(at: time)
        var facePoint: CGPoint?
        if let mesh, bufferW > 0, bufferH > 0 {
            let aspect = bufferH / bufferW
            let mapper = PreviewMapper(bufferSize: CGSize(width: bufferW, height: bufferH), viewSize: viewport)
            let points = mesh.landmarks.map { mapper.viewPoint(x: $0.x, y: $0.y) }
            let oval = CaptureOvalLayout.ovalRect(in: viewport)
            observation = GateObservation(
                time: time,
                faceCount: max(1, mesh.gate.faceCount),
                ovalExtent: PreviewMapper.ovalExtent(of: points, in: oval),
                faceLargerThanOval: Self.boundingBox(points).map {
                    $0.width > oval.width * 0.96 || $0.height > oval.height * 0.96
                } ?? false,
                eyeDistance: Self.eyeDistance(mesh.landmarks, aspect: aspect),
                yaw: mesh.gate.matrixPose?.yaw,
                pitch: mesh.gate.matrixPose?.pitch,
                roll: mesh.gate.matrixPose?.roll,
                face: qualityAnalyzer.analyzeFaceRegion(pixelBuffer, faceRect: mesh.bbox),
                eyeBlinkLeft: mesh.gate.eyeBlinkLeft,
                eyeBlinkRight: mesh.gate.eyeBlinkRight,
                anchors: Self.stillnessAnchors.compactMap { i in
                    i < mesh.landmarks.count
                        ? CGPoint(x: mesh.landmarks[i].x, y: mesh.landmarks[i].y * aspect) : nil
                }
            )
            contourField.update(points: points, z: mesh.landmarks.map(\.z))
            facePoint = mapper.viewPoint(x: mesh.bbox.x + mesh.bbox.w / 2, y: mesh.bbox.y + mesh.bbox.h / 2)
            if mesh.gate.faceCount > 1, latestGuide.failing.contains(.onePerson) == false {
                // Rising edge only. Not uploaded in Phase 1 (no wire change).
                USTrace.log("guide: second face in view (\(mesh.gate.faceCount) faces)")
            }
        } else {
            contourField.update(points: [], z: [])
        }

        let isAlign: Bool
        if case .faceGuide = state { isAlign = true } else { isAlign = false }
        let shutter = isAlign && (pausedWindows >= Self.shutterAfterPausedWindows
            || (alignStartedAt.map { Date().timeIntervalSince($0) >= Self.shutterAfterSeconds } ?? false))

        guideLock.lock()
        let snapshot = guide.update(observation)
        if USTrace.enabled, snapshot.failing != latestGuide.failing {
            let e = guide.lastEvaluation
            let f = observation.face
            USTrace.log("guide: failing [\(snapshot.failing.sorted().map(\.debugLabel).joined(separator: ","))]"
                + " eye=\(observation.eyeDistance.map { String(format: "%.3f", $0) } ?? "-")"
                + " oval=\(observation.ovalExtent.map { String(format: "%.2f", $0) } ?? "-")"
                + " yaw=\(observation.yaw.map { String(format: "%.1f", $0) } ?? "-")"
                + " pitch=\(observation.pitch.map { String(format: "%.1f", $0) } ?? "-")"
                + " roll=\(observation.roll.map { String(format: "%.1f", $0) } ?? "-")"
                + " luma=\(f.map { String(format: "%.0f", $0.meanLuma) } ?? "-")"
                + " sharp=\(f.map { String(format: "%.1f", $0.sharpness) } ?? "-")"
                + " jitter=\(e.jitter.map { String(format: "%.3f", $0) } ?? "-")")
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
        let startScan = isAlign && snapshot.allPass && !autoStartRequested
        if startScan { autoStartRequested = true }
        let refocus = facePoint != nil && now - lastFocusTime >= 0.5
        if refocus { lastFocusTime = now }
        guideLock.unlock()

        if publish { onGuideUpdate?(update) }
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
