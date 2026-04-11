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
    private var isCapturingFrames = false
    private var serverMaxFrames: Int?
    private var stepUpResult: StepUpResult?

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
    }

    // MARK: - Public Event Listener

    public func addEventListener(_ callback: @escaping EventCallback) -> () -> Void {
        eventEmitter.addListener(callback)
    }

    // MARK: - Hosted Page Injection

    func injectHostedSessionData(_ response: CreateSessionResponse) {
        let data = SessionData(from: response)
        self.sessionData = data
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

    func faceReady() async {
        await startBaseline()
    }

    func challengeCompleted() async {
        isCapturingFrames = false
        challengeResponseBuilder.markCompleted()
        eventEmitter.emit(.challengeCompleted)

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

    func retry() async {
        isCapturingFrames = false
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

        frameCaptureManager.start()

        if let challenge = sessionData?.policy.challenge {
            currentState = .instructions(challenge: challenge)
        } else {
            await startFaceGuide()
        }
    }

    private func startFaceGuide() async {
        currentState = .faceGuide
    }

    private func reconfigureFrameBuffer(maxFrames: Int, targetFps: Int) {
        serverMaxFrames = maxFrames
        frameBuffer.reconfigure(maxFrames: maxFrames, targetFps: targetFps)
    }

    private func startBaseline() async {
        do {
            eventEmitter.emit(.captureStarted)
            captureStartTime = Date()
            frameBuffer.reset()
            faceMeshManager.reset()
            suspicionEngine?.reset()
            isCapturingFrames = true
            currentState = .baseline(remaining: baselineDuration)

            if needsAudio {
                startAudioRecording()
            }

            try await Task.sleep(nanoseconds: UInt64(baselineDuration * 1_000_000_000))

            if sessionData?.policy.challenge != nil {
                for i in stride(from: 3, through: 1, by: -1) {
                    currentState = .countdown(number: i)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            challengeResponseBuilder.markStarted()
            if let challenge = sessionData?.policy.challenge {
                eventEmitter.emit(.challengeStarted, data: ["type": challenge.challengeType.rawValue])
                currentState = .challenge(spec: challenge)
            } else {
                let captureDurationMs = sessionData?.upload.captureDurationMs ?? config.options?.captureDurationMs ?? 8000
                try await Task.sleep(nanoseconds: UInt64(captureDurationMs) * 1_000_000)
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
            handleError(UseSenseError(code: .unknownError, message: "No frames captured."))
            return
        }

        let frameHashes = Array(frameBuffer.getFrameHashes().prefix(frames.count))
        let frameLuminances = frameBuffer.getFrameLuminances()

        eventEmitter.emit(.captureCompleted, data: ["frame_count": "\(frames.count)"])

        // Wait for App Attest
        var attestFields: [String: Any] = [:]
        #if canImport(DeviceCheck) && canImport(CryptoKit)
        attestFields = await appAttestTask?.value ?? [:]
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

        // Verification package (Geometric Coherence)
        var verificationPackage: [String: Any]?
        if session.geometricCoherence?.dualPathEnabled == true, !meshResults.isEmpty {
            let fittingResults = meshResults.compactMap { mesh in
                threeDMMFitter.fit(landmarks: mesh.landmarks, pose: mesh.headPose)
            }
            verificationPackage = verificationPackageBuilder.build(
                meshResults: meshResults,
                fittingResults: fittingResults,
                frameHashes: frameHashes,
                meshBindingChallenge: session.geometricCoherence?.meshBindingChallenge,
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

        // Build frames manifest
        let timestamps = frameBuffer.getTimestamps()
        let framesManifest: [[String: Any]] = (0..<frames.count).map { i in
            [
                "frame_index": i,
                "capture_timestamp_ms": i < timestamps.count ? Int(timestamps[i] * 1000) : 0,
                "resolution_w": 1280,
                "resolution_h": 720
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
                inlineStepUp: inlineStepUpData
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
        faceMeshManager.teardown()
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
#endif
