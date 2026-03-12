#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit
import Foundation

public final class UseSenseSession: @unchecked Sendable {
    // MARK: - Public Properties

    var onStateChange: ((SessionState) -> Void)?
    var onQualityUpdate: ((ImageQualityReport) -> Void)?

    var previewLayer: AVCaptureVideoPreviewLayer? {
        frameCaptureManager.previewLayer
    }

    // MARK: - Private Properties

    private let config: UseSenseConfig
    private let sessionType: SessionType
    private let identityId: String?
    private let externalUserId: String?
    private let metadata: [String: AnyCodableValue]?

    private let apiClient: UseSenseAPIClient
    private let eventEmitter: EventEmitter
    private let frameCaptureManager = FrameCaptureManager()
    private let audioCaptureManager = AudioCaptureManager()
    private let frameBuffer: FrameBuffer
    private let qualityAnalyzer = ImageQualityAnalyzer()
    private let metadataBuilder = MetadataBuilder()
    private let challengeResponseBuilder = ChallengeResponseBuilder()
    private let deviceSignalCollector = DeviceSignalCollector()

    #if canImport(DeviceCheck) && canImport(CryptoKit)
    private let appAttestManager = AppAttestManager()
    #endif

    /// App Attest fields fetched concurrently during session creation (like Android's integrityJob)
    private var appAttestTask: Task<[String: Any], Never>?

    private var sessionData: SessionData?
    private var currentState: SessionState = .idle {
        didSet { onStateChange?(currentState) }
    }
    private var isStarted = false
    private var audioRecordingURL: URL?
    private var captureStartTime: Date?
    private var captureEndTime: Date?
    private var framesDropped: Int = 0
    private var baselineDuration: TimeInterval = 2.0
    private var latestQualityReport: ImageQualityReport?
    /// Gates frame storage so we only capture during baseline/countdown/challenge.
    private var isCapturingFrames = false
    /// Server-provided frame limit; used as a hard cap at upload time.
    private var serverMaxFrames: Int?

    // MARK: - Init

    public convenience init(
        config: UseSenseConfig,
        sessionType: SessionType,
        identityId: String? = nil,
        externalUserId: String? = nil,
        metadata: [String: AnyCodableValue]? = nil
    ) {
        self.init(
            config: config,
            sessionType: sessionType,
            identityId: identityId,
            externalUserId: externalUserId,
            metadata: metadata,
            eventEmitter: EventEmitter()
        )
    }

    init(
        config: UseSenseConfig,
        sessionType: SessionType,
        identityId: String? = nil,
        externalUserId: String? = nil,
        metadata: [String: AnyCodableValue]? = nil,
        eventEmitter: EventEmitter
    ) {
        self.config = config
        self.sessionType = sessionType
        self.identityId = identityId
        self.externalUserId = externalUserId
        self.metadata = metadata
        self.apiClient = UseSenseAPIClient(config: config)
        self.eventEmitter = eventEmitter

        let maxFrames = config.options?.maxFrames ?? 40
        let targetFps = config.options?.targetFps ?? 15
        self.frameBuffer = FrameBuffer(maxFrames: maxFrames, targetFps: targetFps)

        frameCaptureManager.delegate = self
    }

    // MARK: - Public Event Listener

    public func addEventListener(_ callback: @escaping EventCallback) -> () -> Void {
        eventEmitter.addListener(callback)
    }

    // MARK: - Hosted Page Injection

    /// Inject session credentials from a hosted page init-session response.
    /// This bypasses the normal createSession call and jumps directly into the capture pipeline.
    func injectHostedSessionData(_ response: CreateSessionResponse) {
        let data = SessionData(from: response)
        self.sessionData = data
        self.apiClient.sessionToken = data.sessionToken
        self.apiClient.nonce = data.nonce

        // Reconfigure frame buffer with server limits
        frameBuffer.reconfigure(maxFrames: data.upload.maxFrames, targetFps: data.upload.targetFps)
        serverMaxFrames = data.upload.maxFrames
    }

    // MARK: - Session Lifecycle

    func start() async {
        guard !isStarted else { return }
        isStarted = true

        do {
            // Start sensor collection
            deviceSignalCollector.startSensorCollection()

            // If session data was injected by a hosted page flow, skip createSession
            if sessionData == nil {
                let request = CreateSessionRequest(
                    sessionType: sessionType.rawValue,
                    identityId: identityId,
                    externalUserId: externalUserId,
                    metadata: metadata
                )
                let response = try await apiClient.createSession(request: request)
                let data = SessionData(from: response)
                self.sessionData = data
            }

            guard let data = sessionData else {
                handleError(UseSenseError(code: .unknownError, message: "No session data available."))
                return
            }

            // Start App Attest fields fetch concurrently (bound to session nonce)
            #if canImport(DeviceCheck) && canImport(CryptoKit)
            appAttestTask = Task {
                await appAttestManager.getAttestFields(sessionNonce: data.nonce)
            }
            #endif

            eventEmitter.emit(.sessionCreated, data: ["session_id": data.sessionId])
            currentState = .created(session: data)

            // Check permissions
            await checkPermissions()
        } catch let error as UseSenseError {
            handleError(error)
        } catch {
            handleError(UseSenseError(code: .networkError, message: error.localizedDescription))
        }
    }

    func requestPermissions() async {
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
        await startFaceGuide()
    }

    /// Called by the face guide "My face is ready" button
    func faceReady() async {
        await startBaseline()
    }

    func challengeCompleted() async {
        isCapturingFrames = false
        challengeResponseBuilder.markCompleted()
        eventEmitter.emit(.challengeCompleted)
        frameCaptureManager.stop()
        captureEndTime = Date()
        deviceSignalCollector.stopSensorCollection()
        await stopAudioIfNeeded()

        // Safety net wraps upload + complete
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

    func retry() async {
        isCapturingFrames = false
        frameBuffer.reset()
        challengeResponseBuilder.reset()
        deviceSignalCollector.release()
        apiClient.clearSession()
        isStarted = false
        currentState = .idle
        await start()
    }

    func cancel() {
        isCapturingFrames = false
        frameCaptureManager.stop()
        audioCaptureManager.cleanup()
        frameBuffer.reset()
        deviceSignalCollector.release()
        appAttestTask?.cancel()
        currentState = .error(UseSenseError(code: .userCancelled))
    }

    // MARK: - Private Flow

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
            // Spec: camera errors show retry UI, NOT onError
            let message: String
            if let senseError = error as? UseSenseError {
                message = senseError.message
            } else {
                message = "Camera error: \(error.localizedDescription)"
            }
            currentState = .cameraError(message: message)
            return
        }

        // Reconfigure frame buffer with server-provided limits so we never
        // exceed the server's allowed budget.
        if let upload = sessionData?.upload {
            reconfigureFrameBuffer(maxFrames: upload.maxFrames, targetFps: upload.targetFps)
        }

        // Start camera immediately so the preview layer has frames by the
        // time the face guide screen renders (avoids initial black flash).
        frameCaptureManager.start()

        // Show instructions if there's a challenge
        if let challenge = sessionData?.policy.challenge {
            currentState = .instructions(challenge: challenge)
        } else {
            await startFaceGuide()
        }
    }

    private func startFaceGuide() async {
        currentState = .faceGuide
        // The view will show a "My face is ready" button which calls faceReady()
    }

    /// Re-create the frame buffer with server-provided limits.
    private func reconfigureFrameBuffer(maxFrames: Int, targetFps: Int) {
        serverMaxFrames = maxFrames
        frameBuffer.reconfigure(maxFrames: maxFrames, targetFps: targetFps)
    }

    private func startBaseline() async {
        // Spec Section 13.1: Global safety net wraps entire post-camera pipeline
        do {
            eventEmitter.emit(.captureStarted)
            captureStartTime = Date()
            frameBuffer.reset()
            isCapturingFrames = true
            currentState = .baseline(remaining: baselineDuration)

            // Start audio if needed
            if needsAudio {
                startAudioRecording()
            }

            // Wait for baseline duration (2 seconds per spec)
            try await Task.sleep(nanoseconds: UInt64(baselineDuration * 1_000_000_000))

            // Countdown (3 seconds: 3, 2, 1 per spec) with continued frame capture
            if sessionData?.policy.challenge != nil {
                for i in stride(from: 3, through: 1, by: -1) {
                    currentState = .countdown(number: i)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            // Start challenge phase
            challengeResponseBuilder.markStarted()
            if let challenge = sessionData?.policy.challenge {
                eventEmitter.emit(.challengeStarted, data: ["type": challenge.challengeType.rawValue])
                currentState = .challenge(spec: challenge)
                // Challenge completion is handled by challengeCompleted() callback
            } else {
                // No challenge, just capture for the configured duration
                let captureDurationMs = sessionData?.upload.captureDurationMs ?? config.options?.captureDurationMs ?? 2500
                try await Task.sleep(nanoseconds: UInt64(captureDurationMs) * 1_000_000)
                isCapturingFrames = false
                frameCaptureManager.stop()
                captureEndTime = Date()
                deviceSignalCollector.stopSensorCollection()
                await stopAudioIfNeeded()
                try await uploadAndCompleteWithSafetyNet()
            }
        } catch is CancellationError {
            // Task was cancelled (e.g. user navigated away)
            return
        } catch {
            // Safety net: catch any unexpected error
            handleError(UseSenseError(code: .unknownError, message: "Unexpected error: \(error.localizedDescription)"))
        }
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

    private func uploadAndCompleteWithSafetyNet() async throws {
        guard let session = sessionData else {
            handleError(UseSenseError(code: .unknownError, message: "No session data available."))
            return
        }

        guard !session.isExpired else {
            handleError(UseSenseError(code: .sessionExpired))
            return
        }

        // Build signals – hard-cap to server's maxFrames so we never exceed
        // the allowed budget, regardless of how many the buffer collected.
        var frames = frameBuffer.getFrames()
        if let cap = serverMaxFrames ?? sessionData?.upload.maxFrames, frames.count > cap {
            frames = Array(frames.prefix(cap))
        }
        guard !frames.isEmpty else {
            handleError(UseSenseError(code: .unknownError, message: "No frames captured."))
            return
        }

        eventEmitter.emit(.captureCompleted, data: ["frame_count": "\(frames.count)"])

        // Wait for App Attest fields (started concurrently during session creation)
        var attestFields: [String: Any] = [:]
        #if canImport(DeviceCheck) && canImport(CryptoKit)
        attestFields = await appAttestTask?.value ?? [:]
        #endif

        // Collect channel integrity and device telemetry
        let channelIntegrity = deviceSignalCollector.collectChannelIntegrity(attestFields: attestFields)
        let deviceTelemetry = deviceSignalCollector.collectDeviceTelemetry()

        // Build challenge response if applicable
        var challengeResponse: [String: Any]?
        if let challenge = session.policy.challenge {
            challengeResponse = challengeResponseBuilder.build(challenge: challenge)
        }

        // Build metadata (channel_integrity + device_telemetry structure)
        let metadataData: Data
        let startTime = captureStartTime ?? Date()
        let endTime = captureEndTime ?? Date()
        let timestamps = frameBuffer.getTimestamps()
        let avgInterval: Int
        if timestamps.count > 1 {
            let totalInterval = timestamps.last! - timestamps.first!
            avgInterval = Int((totalInterval / Double(timestamps.count - 1)) * 1000)
        } else {
            avgInterval = 0
        }

        do {
            metadataData = try metadataBuilder.build(
                sessionId: session.sessionId,
                challengeResponse: challengeResponse,
                channelIntegrity: channelIntegrity,
                deviceTelemetry: deviceTelemetry,
                captureStartTime: startTime,
                captureEndTime: endTime,
                framesCaptured: frames.count,
                framesDropped: framesDropped,
                avgFrameIntervalMs: avgInterval
            )
        } catch {
            handleError(UseSenseError(code: .unknownError, message: "Failed to build metadata."))
            return
        }

        // Get audio data
        let audioData: Data?
        if let url = audioRecordingURL {
            audioData = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
        } else {
            audioData = audioCaptureManager.stopRecording()
        }

        // Upload
        currentState = .uploading(progress: 0)
        eventEmitter.emit(.uploadStarted)

        do {
            _ = try await apiClient.uploadSignals(
                sessionId: session.sessionId,
                sessionToken: session.sessionToken,
                nonce: session.nonce,
                frames: frames,
                metadata: metadataData,
                audio: audioData
            )
            eventEmitter.emit(.uploadCompleted)
            currentState = .uploading(progress: 1.0)
        } catch let error as UseSenseError {
            handleError(error)
            return
        } catch {
            handleError(UseSenseError(code: .networkError, message: error.localizedDescription))
            return
        }

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
        deviceSignalCollector.release()
        eventEmitter.emit(.error, data: ["code": error.code.rawValue, "message": error.message])
        currentState = .error(error)
    }
}

// MARK: - FrameCaptureDelegate

extension UseSenseSession: FrameCaptureDelegate {
    func frameCaptureManager(_ manager: FrameCaptureManager, didCapture pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        // Quality analysis at 4Hz (always runs, even during face guide)
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

        // Only store frames during active capture phases (baseline / countdown / challenge).
        // During face guide, the camera runs for preview + quality analysis only.
        guard isCapturingFrames else { return }

        // Frame capture at target FPS
        if frameBuffer.shouldCapture() && !frameBuffer.isFull {
            let frameIndex = frameBuffer.count
            let timestampMs = Int64(CMTimeGetSeconds(timestamp) * 1000)
            frameBuffer.addFrame(pixelBuffer, timestamp: CMTimeGetSeconds(timestamp))

            // Record frame for challenge response
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
#endif
