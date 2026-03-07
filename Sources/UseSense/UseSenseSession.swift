#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit
import Foundation

public final class UseSenseSession: @unchecked Sendable {
    // MARK: - Public Properties

    var onStateChange: ((SessionState) -> Void)?
    var onQualityUpdate: (([QualityGuidance]) -> Void)?

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

    private var sessionData: SessionData?
    private var currentState: SessionState = .idle {
        didSet { onStateChange?(currentState) }
    }
    private var audioRecordingURL: URL?
    private var captureStartTime: Date?
    private var baselineDuration: TimeInterval = 1.5

    // MARK: - Init

    public init(
        config: UseSenseConfig,
        sessionType: SessionType,
        identityId: String? = nil,
        externalUserId: String? = nil,
        metadata: [String: AnyCodableValue]? = nil,
        eventEmitter: EventEmitter = EventEmitter()
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
        do {
            // Phase 1: App Attest (non-blocking)
            #if canImport(DeviceCheck) && canImport(CryptoKit)
            try? await appAttestManager.attestIfNeeded(apiClient: apiClient)
            #endif

            // Phase 2: Create session
            let request = CreateSessionRequest(
                sessionType: sessionType.rawValue,
                identityId: identityId,
                externalUserId: externalUserId,
                metadata: metadata
            )
            let response = try await apiClient.createSession(request: request)
            let data = SessionData(from: response)
            self.sessionData = data

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

    func challengeCompleted() async {
        eventEmitter.emit(.challengeCompleted)
        frameCaptureManager.stop()
        await stopAudioIfNeeded()
        await uploadAndComplete()
    }

    func challengeStepReached(_ index: Int) {
        challengeResponseBuilder.recordStep(index: index)
    }

    func retry() async {
        frameBuffer.reset()
        challengeResponseBuilder.reset()
        currentState = .idle
        await start()
    }

    func cancel() {
        frameCaptureManager.stop()
        audioCaptureManager.cleanup()
        frameBuffer.reset()
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
            handleError(UseSenseError(code: .cameraPermissionDenied, message: "Failed to configure camera: \(error.localizedDescription)"))
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

        // Wait briefly for face positioning
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        await startBaseline()
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

        // Wait for baseline duration
        try? await Task.sleep(nanoseconds: UInt64(baselineDuration * 1_000_000_000))

        // Countdown
        for i in stride(from: 3, through: 1, by: -1) {
            currentState = .countdown(number: i)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Start challenge phase
        challengeResponseBuilder.start()
        if let challenge = sessionData?.policy.challenge {
            eventEmitter.emit(.challengeStarted, data: ["type": challenge.challengeType.rawValue])
            currentState = .challenge(spec: challenge)
        } else {
            // No challenge, just capture for the configured duration
            let captureDurationMs = sessionData?.upload.captureDurationMs ?? config.options?.captureDurationMs ?? 2500
            try? await Task.sleep(nanoseconds: UInt64(captureDurationMs) * 1_000_000)
            frameCaptureManager.stop()
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

        // Get App Attest token
        var appAttestToken: String?
        #if canImport(DeviceCheck) && canImport(CryptoKit)
        appAttestToken = await appAttestManager.generateAssertionSafe(nonce: session.nonce)
        #endif

        let integritySignals = deviceSignalCollector.collect(appAttestToken: appAttestToken)

        // Build metadata
        let metadataData: Data
        do {
            let captureDurationMs = captureStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            metadataData = try metadataBuilder.build(
                sessionId: session.sessionId,
                nonce: session.nonce,
                challenge: session.policy.challenge,
                captureDurationMs: captureDurationMs,
                frameTimestamps: frameBuffer.getTimestamps(),
                hasAudio: audioCaptureManager.isRecording || audioRecordingURL != nil,
                integritySignals: integritySignals
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
            onQualityUpdate?(report.guidanceMessages)
            eventEmitter.emit(.imageQualityCheck, data: [
                "score": String(format: "%.1f", report.overallScore),
                "blur": String(format: "%.1f", report.laplacianVariance),
                "brightness": String(format: "%.1f", report.meanBrightness)
            ])
        }

        // Frame capture at target FPS
        if frameBuffer.shouldCapture() && !frameBuffer.isFull {
            frameBuffer.addFrame(pixelBuffer, timestamp: CMTimeGetSeconds(timestamp))
            eventEmitter.emit(.frameCaptured, data: ["count": "\(frameBuffer.count)"])
        }
    }

    func frameCaptureManager(_ manager: FrameCaptureManager, didFailWithError error: Error) {
        handleError(UseSenseError(code: .unknownError, message: "Camera error: \(error.localizedDescription)"))
    }
}
#endif
