#if canImport(UIKit) && canImport(AVFoundation)
import Foundation
import UIKit
import AVFoundation

public struct VerificationRequest: Sendable {
    public let sessionType: SessionType
    public let externalUserId: String?
    public let identityId: String?
    public let metadata: [String: AnyCodableValue]?

    public init(
        sessionType: SessionType = .enrollment,
        externalUserId: String? = nil,
        identityId: String? = nil,
        metadata: [String: AnyCodableValue]? = nil
    ) {
        self.sessionType = sessionType
        self.externalUserId = externalUserId
        self.identityId = identityId
        self.metadata = metadata
    }
}

@MainActor
final class UseSenseSessionManager: NSObject, ObservableObject {
    @Published var state: SessionState = .idle
    @Published var currentCapturePhase: CapturePhase = .instructions
    @Published var currentWaypointIndex: Int = 0
    @Published var currentStepIndex: Int = 0
    @Published var countdownNumber: Int = 3

    private let config: UseSenseConfig
    private let theme: UseSenseTheme
    private let request: VerificationRequest
    private let apiClient: UseSenseAPIClient

    let frameCaptureManager = FrameCaptureManager()
    private let audioCaptureManager = AudioCaptureManager()
    private let deviceSignalCollector = DeviceSignalCollector()
    private let frameBuffer = FrameBuffer(maxCapacity: 30)

    private var sessionData: SessionData?
    private var challengeResponseBuilder: ChallengeResponseBuilder?
    private var captureStartTime: Date?
    private var captureEndTime: Date?

    private var challengeTimer: Timer?
    private var baselineTimer: Timer?

    var onResult: ((Result<UseSenseResult, UseSenseError>) -> Void)?
    var onCancelled: (() -> Void)?

    init(config: UseSenseConfig, theme: UseSenseTheme, request: VerificationRequest) {
        self.config = config
        self.theme = theme
        self.request = request
        self.apiClient = UseSenseAPIClient(config: config)
        super.init()
        frameCaptureManager.delegate = self
    }

    // MARK: - Public Flow

    func start() async {
        do {
            try frameCaptureManager.configure()
        } catch {
            state = .error(error as? UseSenseError ?? UseSenseError(code: .cameraUnavailable, message: error.localizedDescription))
            return
        }

        // Check permissions
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                state = .error(.cameraPermissionDenied())
                return
            }
        } else if cameraStatus != .authorized {
            state = .error(.cameraPermissionDenied())
            return
        }

        // Create session
        do {
            let apiRequest = CreateSessionRequest(
                sessionType: request.sessionType.rawValue,
                identityId: request.identityId,
                externalUserId: request.externalUserId,
                metadata: request.metadata
            )
            let response = try await apiClient.createSession(request: apiRequest)
            let session = SessionData(from: response)
            sessionData = session
            state = .created(session: session)

            frameCaptureManager.setCaptureParameters(
                maxFrames: session.upload.maxFrames,
                targetFps: session.upload.targetFps
            )

            // Check if audio permission needed
            if session.policy.requiresAudio == true {
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                if micStatus == .notDetermined {
                    let granted = await AVCaptureDevice.requestAccess(for: .audio)
                    if !granted {
                        state = .error(.microphonePermissionDenied())
                        return
                    }
                } else if micStatus != .authorized {
                    state = .error(.microphonePermissionDenied())
                    return
                }
            }

            frameCaptureManager.startPreview()

            // If there's a challenge, show instructions; otherwise go directly to baseline
            if let challenge = session.policy.challenge, session.policy.requiresStepup == true {
                state = .instructions(challenge: challenge)
                currentCapturePhase = .instructions
            } else {
                startBaseline()
            }
        } catch {
            let useSenseError = error as? UseSenseError ?? UseSenseError(code: .sessionCreationFailed, message: error.localizedDescription)
            state = .error(useSenseError)
            onResult?(.failure(useSenseError))
        }
    }

    func didTapInstructionsButton() {
        state = .faceGuide
        currentCapturePhase = .faceGuide
    }

    func didTapFaceReady() {
        startBaseline()
    }

    func cancel() {
        cleanup()
        onCancelled?()
    }

    // MARK: - Capture Flow

    private func startBaseline() {
        currentCapturePhase = .baseline
        state = .baseline(remaining: 2.0)
        captureStartTime = Date()
        frameCaptureManager.startCapture()
        deviceSignalCollector.startSensorCapture()

        // Start audio recording if required
        if sessionData?.policy.requiresAudio == true {
            if let audioDuration = sessionData?.policy.audioChallenge?.totalDurationMs {
                try? audioCaptureManager.startRecording(durationMs: audioDuration)
            }
        }

        // After 2 seconds, move to countdown or challenge
        baselineTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.baselineComplete()
            }
        }
    }

    private func baselineComplete() {
        guard let session = sessionData else { return }

        if session.policy.challenge != nil && session.policy.requiresStepup == true {
            startCountdown()
        } else {
            captureComplete()
        }
    }

    private func startCountdown() {
        currentCapturePhase = .countdown
        countdownNumber = 3
        state = .countdown(number: 3)

        let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

        var count = 3
        challengeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }
                count -= 1
                if count > 0 {
                    self.countdownNumber = count
                    self.state = .countdown(number: count)
                    feedbackGenerator.impactOccurred()
                } else {
                    timer.invalidate()
                    self.startChallenge()
                }
            }
        }
        feedbackGenerator.impactOccurred()
    }

    private func startChallenge() {
        guard let session = sessionData, let challenge = session.policy.challenge else {
            captureComplete()
            return
        }

        currentCapturePhase = .challenge
        state = .challenge(spec: challenge)
        challengeResponseBuilder = ChallengeResponseBuilder(spec: challenge)
        challengeResponseBuilder?.markStarted()
        currentWaypointIndex = 0
        currentStepIndex = 0
        challengeResponseBuilder?.setCurrentStep(0)

        let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

        switch challenge.type {
        case .followDot:
            guard let waypoints = challenge.waypoints, !waypoints.isEmpty else {
                captureComplete()
                return
            }
            runWaypoints(waypoints, durationPerStep: waypoints.first?.durationMs ?? 1500, feedback: feedbackGenerator)

        case .headTurn:
            guard let sequence = challenge.sequence, !sequence.isEmpty else {
                captureComplete()
                return
            }
            runHeadTurnSequence(sequence, feedback: feedbackGenerator)

        case .speakPhrase:
            let duration = TimeInterval(challenge.totalDurationMs) / 1000.0
            challengeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.challengeResponseBuilder?.markCompleted()
                    self?.captureComplete()
                }
            }
        }
    }

    private func runWaypoints(_ waypoints: [Waypoint], durationPerStep: Int, feedback: UIImpactFeedbackGenerator) {
        var stepIndex = 0
        let stepDuration = TimeInterval(durationPerStep) / 1000.0

        challengeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }
                stepIndex += 1
                if stepIndex < waypoints.count {
                    self.currentWaypointIndex = stepIndex
                    self.challengeResponseBuilder?.setCurrentStep(stepIndex)
                    feedback.impactOccurred()
                } else {
                    timer.invalidate()
                    self.challengeResponseBuilder?.markCompleted()
                    self.captureComplete()
                }
            }
        }
    }

    private func runHeadTurnSequence(_ sequence: [HeadTurnStep], feedback: UIImpactFeedbackGenerator) {
        var stepIndex = 0

        func runStep() {
            guard stepIndex < sequence.count else {
                challengeResponseBuilder?.markCompleted()
                captureComplete()
                return
            }

            let step = sequence[stepIndex]
            currentStepIndex = stepIndex
            challengeResponseBuilder?.setCurrentStep(stepIndex)
            feedback.impactOccurred()

            let duration = TimeInterval(step.durationMs) / 1000.0
            challengeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    stepIndex += 1
                    self?.runHeadTurnStep(sequence: sequence, currentIndex: stepIndex, feedback: feedback)
                }
            }
        }

        runStep()
    }

    private func runHeadTurnStep(sequence: [HeadTurnStep], currentIndex: Int, feedback: UIImpactFeedbackGenerator) {
        guard currentIndex < sequence.count else {
            challengeResponseBuilder?.markCompleted()
            captureComplete()
            return
        }

        let step = sequence[currentIndex]
        currentStepIndex = currentIndex
        challengeResponseBuilder?.setCurrentStep(currentIndex)
        feedback.impactOccurred()

        let duration = TimeInterval(step.durationMs) / 1000.0
        challengeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.runHeadTurnStep(sequence: sequence, currentIndex: currentIndex + 1, feedback: feedback)
            }
        }
    }

    private func captureComplete() {
        currentCapturePhase = .done
        frameCaptureManager.stopCapture()
        captureEndTime = Date()
        deviceSignalCollector.stopSensorCapture()

        let audioData = audioCaptureManager.stopRecording()

        let feedbackGenerator = UINotificationFeedbackGenerator()
        feedbackGenerator.notificationOccurred(.success)

        Task {
            await uploadAndComplete(audioData: audioData)
        }
    }

    // MARK: - Upload & Complete

    private func uploadAndComplete(audioData: Data?) async {
        guard let session = sessionData else { return }

        state = .uploading(progress: 0.5)

        let frames = frameBuffer.allFrames()
        let timestamps = frameBuffer.allTimestamps()

        guard !frames.isEmpty else {
            let error = UseSenseError(code: .noFramesCaptured, message: "No frames were captured during the session.")
            state = .error(error)
            onResult?(.failure(error))
            return
        }

        // Build challenge response
        let challengePayload = challengeResponseBuilder?.build(frameTimestamps: timestamps)

        // Build metadata
        let webIntegrity = deviceSignalCollector.collectSignals()
        let deviceTelemetry = deviceSignalCollector.collectDeviceTelemetry()

        guard let metadataJSON = MetadataBuilder.build(
            challengeResponse: challengePayload,
            webIntegrity: webIntegrity,
            deviceTelemetry: deviceTelemetry,
            captureStartTime: captureStartTime ?? Date(),
            captureEndTime: captureEndTime ?? Date(),
            framesCount: frames.count,
            frameTimestamps: timestamps
        ) else {
            let error = UseSenseError(code: .encodingFailed, message: "Failed to build metadata.")
            state = .error(error)
            onResult?(.failure(error))
            return
        }

        // Upload signals
        do {
            _ = try await apiClient.uploadSignals(
                sessionId: session.sessionId,
                sessionData: session,
                frames: frames,
                metadata: metadataJSON,
                audio: audioData
            )
        } catch {
            let useSenseError = error as? UseSenseError ?? UseSenseError(code: .uploadFailed, message: error.localizedDescription)
            state = .error(useSenseError)
            onResult?(.failure(useSenseError))
            return
        }

        // Complete session
        state = .completing

        do {
            let verdict = try await apiClient.completeSession(sessionId: session.sessionId, sessionData: session)
            let result = makeResult(from: verdict)
            state = .done(result: result)
            onResult?(.success(result))
        } catch {
            let useSenseError = error as? UseSenseError ?? UseSenseError(code: .sessionCreationFailed, message: error.localizedDescription)
            state = .error(useSenseError)
            onResult?(.failure(useSenseError))
        }
    }

    private func makeResult(from verdict: VerdictResponse) -> UseSenseResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return UseSenseResult(
            sessionId: verdict.sessionId,
            sessionType: SessionType(rawValue: verdict.sessionType) ?? .enrollment,
            identityId: verdict.identityId,
            decision: Decision(rawValue: verdict.decision) ?? .error,
            channelTrustScore: verdict.channelTrustScore,
            livenessScore: verdict.livenessScore,
            dedupeRiskScore: verdict.dedupeRiskScore,
            pillarVerdicts: verdict.pillarVerdicts,
            reasons: verdict.reasons,
            timestamp: formatter.date(from: verdict.timestamp) ?? Date(),
            signature: verdict.signature,
            rawResponse: verdict
        )
    }

    private func cleanup() {
        challengeTimer?.invalidate()
        challengeTimer = nil
        baselineTimer?.invalidate()
        baselineTimer = nil
        frameCaptureManager.stopCapture()
        frameCaptureManager.stopPreview()
        deviceSignalCollector.stopSensorCapture()
        _ = audioCaptureManager.stopRecording()
        frameBuffer.reset()
    }

    deinit {
        challengeTimer?.invalidate()
        baselineTimer?.invalidate()
    }
}

// MARK: - FrameCaptureDelegate

extension UseSenseSessionManager: FrameCaptureDelegate {
    nonisolated func frameCaptureManager(_ manager: FrameCaptureManager, didCaptureFrame data: Data, index: Int, timestampMs: Int) {
        frameBuffer.append(frame: data, timestampMs: timestampMs)
        Task { @MainActor in
            challengeResponseBuilder?.recordFrame(index: index)
        }
    }

    nonisolated func frameCaptureManagerDidReachFrameLimit(_ manager: FrameCaptureManager) {
        // Frame limit reached - capture will stop naturally
    }
}
#endif
