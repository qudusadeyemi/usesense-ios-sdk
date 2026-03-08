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

    // MARK: - Session Lifecycle

    func start() async {
        guard !isStarted else { return }
        isStarted = true

        do {
            // Phase 1: Create session + start sensor collection
            deviceSignalCollector.startSensorCollection()

            let request = CreateSessionRequest(
                sessionType: sessionType.rawValue,
                identityId: identityId,
                externalUserId: externalUserId,
                metadata: metadata
            )
            let response = try await apiClient.createSession(request: request)
            let data = SessionData(from: response)
            self.sessionData = data

            // Phase 2: Start App Attest fields fetch concurrently (bound to session nonce)
            // Fetches key + attestation + per-session assertion in parallel with UI setup
            #if canImport(DeviceCheck) && canImport(CryptoKit)
            appAttestTask = Task {
                await appAttestManager.getAttestFields(sessionNonce: data.nonce)
            }
            #endif

            eventEmitter.emit(.sessionCreated, data: ["session_id": data.sessionId])
            currentState = .created(session: data)

            // Phase 3: Check permissions
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
        challengeResponseBuilder.markCompleted()
        eventEmitter.emit(.challengeCompleted)
        frameCaptureManager.stop()
        captureEndTime = Date()
        deviceSignalCollector.stopSensorCollection()
        await stopAudioIfNeeded()
        await uploadAndComplete()
    }

    func challengeStepReached(_ index: Int) {
        challengeResponseBuilder.setCurrentStep(index)
    }

    func onFrameCapturedForChallenge(frameIndex: Int, timestampMs: Int64) {
        challengeResponseBuilder.recordFrame(frameIndex: frameIndex, timestampMs: timestampMs)
    }

    func retry() async {
        frameBuffer.reset()
        challengeResponseBuilder.reset()
        deviceSignalCollector.release()
        apiClient.clearSession()
        isStarted = false
        currentState = .idle
        await start()
    }

    func cancel() {
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
            handleError(UseSenseError(code: .cameraUnavailable, message: "Failed to configure camera: \(error.localizedDescription)"))
            return
        }

        // Show instructions if there's a challenge
        if let challenge = sessionData?.policy.challenge {
            currentState = .instructions(challenge: challenge)
        } else {
            await startFaceGuide()
        }
    }

    private func startFaceGuide() async {
        frameCaptureManager.start()
        currentState = .faceGuide
        // The view will show a "My face is ready" button which calls faceReady()
    }

    private func startBaseline() async {
        eventEmitter.emit(.captureStarted)
        captureStartTime = Date()
        frameBuffer.reset()
        currentState = .baseline(remaining: baselineDuration)

        // Start audio if needed
        if needsAudio {
            startAudioRecording()
        }

        // Wait for baseline duration (2 seconds matching Android)
        try? await Task.sleep(nanoseconds: UInt64(baselineDuration * 1_000_000_000))

        // Countdown (3 seconds matching Android)
        for i in stride(from: 3, through: 1, by: -1) {
            currentState = .countdown(number: i)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Start challenge phase
        challengeResponseBuilder.markStarted()
        if let challenge = sessionData?.policy.challenge {
            eventEmitter.emit(.challengeStarted, data: ["type": challenge.challengeType.rawValue])
            currentState = .challenge(spec: challenge)
        } else {
            // No challenge, just capture for the configured duration
            let captureDurationMs = sessionData?.upload.captureDurationMs ?? config.options?.captureDurationMs ?? 2500
            try? await Task.sleep(nanoseconds: UInt64(captureDurationMs) * 1_000_000)
            frameCaptureManager.stop()
            captureEndTime = Date()
            deviceSignalCollector.stopSensorCollection()
            await stopAudioIfNeeded()
            await uploadAndComplete()
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

    private func uploadAndComplete() async {
        guard let session = sessionData else {
            handleError(UseSenseError(code: .unknownError, message: "No session data available."))
            return
        }

        guard !session.isExpired else {
            handleError(UseSenseError(code: .sessionExpired))
            return
        }

        // Build signals
        let frames = frameBuffer.getFrames()
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
