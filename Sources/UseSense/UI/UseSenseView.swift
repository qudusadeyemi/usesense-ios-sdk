#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import AVFoundation

public struct UseSenseView: View {
    @StateObject private var viewModel: UseSenseViewModel
    private let onComplete: (Result<RedactedDecisionObject, UseSenseError>) -> Void
    private let onCancel: (() -> Void)?

    public init(
        session: UseSenseSession,
        onComplete: @escaping (Result<RedactedDecisionObject, UseSenseError>) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self._viewModel = StateObject(wrappedValue: UseSenseViewModel(session: session))
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.state {
            case .idle:
                ProgressView()
                    .tint(.white)
                    .onAppear { viewModel.start() }

            case .created:
                ProgressView("Creating session...")
                    .tint(.white)
                    .foregroundColor(.white)

            case .permissionsRequired:
                permissionsView

            case .cameraError(let message):
                cameraErrorView(message: message)

            case .instructions(let challenge):
                InstructionsView(challenge: challenge) {
                    viewModel.continueFromInstructions()
                }

            case .faceGuide:
                cameraWithFaceGuide

            case .baseline:
                cameraWithBaseline

            case .countdown(let number):
                ZStack {
                    cameraLayer
                    BaselineOvalView()
                    CountdownOverlay(number: number)
                    captureOverlayChrome(phase: "VERIFYING")
                }

            case .challenge(let spec):
                ZStack {
                    cameraLayer
                    BaselineOvalView()
                    challengeOverlay(spec)
                    captureOverlayChrome(phase: "VERIFYING")
                }

            case .uploading:
                // Spec: dark bg (95% opacity), spinner, specific text
                ZStack {
                    Color.black.opacity(0.95).ignoresSafeArea()
                    ProcessingView(
                        title: "Verifying your presence",
                        subtitle: "Please wait while we securely process your session..."
                    )
                }

            case .completing:
                ZStack {
                    Color.black.opacity(0.95).ignoresSafeArea()
                    ProcessingView(
                        title: "Almost done",
                        subtitle: "Finishing up - this will only take a moment."
                    )
                }

            case .done(let decision):
                ResultView(decision: decision, onDismiss: {
                    onComplete(.success(decision))
                }, onRetry: {
                    viewModel.retry()
                })

            case .error(let error):
                FailureView(error: error, onRetry: {
                    if error.isRetryable {
                        viewModel.retry()
                    } else {
                        onComplete(.failure(error))
                    }
                }, onCancel: onCancel)
            }
        }
        .statusBarHidden(viewModel.isCameraActive)
    }

    // MARK: - Camera Views

    private var cameraLayer: some View {
        Group {
            if let previewLayer = viewModel.previewLayer {
                CameraPreviewView(previewLayer: previewLayer)
                    .ignoresSafeArea()
            } else {
                Color.black
            }
        }
    }

    private var cameraWithFaceGuide: some View {
        ZStack {
            cameraLayer
            FaceGuideOverlay(
                qualityGuidance: viewModel.qualityGuidance,
                qualityLevel: viewModel.qualityLevel,
                showReadyButton: true,
                onReady: { viewModel.faceReady() }
            )

            // Close button + quality dot
            VStack {
                HStack {
                    QualityIndicatorView(
                        mode: .compact,
                        qualityLevel: viewModel.qualityLevel,
                        message: nil
                    )
                    .padding(.leading, 16)

                    Spacer()
                    closeButton
                }
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    private var cameraWithBaseline: some View {
        ZStack {
            cameraLayer
            BaselineOvalView()

            // Spec: red pulsing dot + "Verifying" text badge
            VStack {
                HStack {
                    VerifyingBadge()
                        .padding(.leading, 16)
                    Spacer()
                    closeButton
                }
                Spacer()
            }
            .padding(.top, 8)

            // Instruction text per spec
            VStack {
                Spacer()
                Text("Hold still - looking at the camera")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.bottom, 8)

                if let guidance = viewModel.qualityGuidance.first {
                    QualityWarningBanner(guidance: guidance, qualityLevel: viewModel.qualityLevel)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                }
            }
        }
    }

    /// Chrome overlay for countdown and challenge phases.
    private func captureOverlayChrome(phase: String) -> some View {
        VStack {
            HStack {
                VerifyingBadge()
                    .padding(.leading, 16)
                Spacer()
                closeButton
            }
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 8) {
                if let guidance = viewModel.qualityGuidance.first {
                    QualityWarningBanner(guidance: guidance, qualityLevel: viewModel.qualityLevel)
                        .padding(.horizontal, 16)
                }

                ChallengeProgressBar(progress: viewModel.challengeProgress)
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Camera Error View (retry UI, NOT onError)

    private func cameraErrorView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Color.UseSense.error)

                Text("Camera Error")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color.UseSense.textPrimary)

                Text(message)
                    .font(.system(size: 16))
                    .foregroundColor(Color.UseSense.textSecondary)
                    .multilineTextAlignment(.center)

                Button(action: { viewModel.retry() }) {
                    Text("Try Again")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.UseSense.primary)
                        .cornerRadius(12)
                }
            }
            .padding(32)
            .background(Color.UseSense.surface)
            .cornerRadius(24)
            .shadow(color: .black.opacity(0.1), radius: 16, y: 4)
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(Color.UseSense.background.ignoresSafeArea())
    }

    // MARK: - Challenge Overlay

    @ViewBuilder
    private func challengeOverlay(_ spec: ChallengeSpecWrapper) -> some View {
        switch spec {
        case .followDot(let challenge):
            FollowDotChallengeView(
                challenge: challenge,
                onComplete: { viewModel.challengeCompleted() },
                onStepReached: { viewModel.challengeStepReached($0) },
                onProgress: { viewModel.challengeProgress = $0 }
            )
            .id(challenge.seed)
        case .headTurn(let challenge):
            HeadTurnChallengeView(
                challenge: challenge,
                onComplete: { viewModel.challengeCompleted() },
                onStepReached: { viewModel.challengeStepReached($0) },
                onProgress: { viewModel.challengeProgress = $0 }
            )
            .id(challenge.seed)
        case .speakPhrase(let challenge):
            SpeakPhraseChallengeView(
                challenge: challenge,
                onComplete: { viewModel.challengeCompleted() }
            )
            .id(challenge.seed)
        }
    }

    // MARK: - Permissions View

    private var permissionsView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Color.UseSense.primary)

                Text("Camera Access Required")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color.UseSense.textPrimary)

                Text("We need camera access to verify your identity. Your privacy is protected.")
                    .font(.system(size: 16))
                    .foregroundColor(Color.UseSense.textSecondary)
                    .multilineTextAlignment(.center)

                Button(action: { viewModel.requestPermissions() }) {
                    Text("Grant Access")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.UseSense.primary)
                        .cornerRadius(12)
                }
            }
            .padding(32)
            .background(Color.UseSense.surface)
            .cornerRadius(24)
            .shadow(color: .black.opacity(0.1), radius: 16, y: 4)
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(Color.UseSense.background.ignoresSafeArea())
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button(action: {
            viewModel.cancel()
            onCancel?()
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .padding(.trailing, 16)
    }
}

// MARK: - Verifying Badge (red pulsing dot + "Verifying" per spec)

struct VerifyingBadge: View {
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .opacity(isPulsing ? 0.7 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            Text("Verifying")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.5))
        .cornerRadius(12)
        .onAppear { isPulsing = true }
    }
}

// MARK: - ViewModel

final class UseSenseViewModel: ObservableObject {
    @Published var state: SessionState = .idle
    @Published var qualityGuidance: [QualityGuidance] = []
    @Published var qualityLevel: QualityLevel = .good
    @Published var challengeProgress: Double = 0
    @Published var completionResult: Result<RedactedDecisionObject, UseSenseError>?

    private let session: UseSenseSession

    var previewLayer: AVCaptureVideoPreviewLayer? {
        session.previewLayer
    }

    var isCameraActive: Bool {
        switch state {
        case .faceGuide, .baseline, .countdown, .challenge: return true
        default: return false
        }
    }

    init(session: UseSenseSession) {
        self.session = session
        session.onStateChange = { [weak self] newState in
            DispatchQueue.main.async {
                self?.state = newState
            }
        }
        session.onQualityUpdate = { [weak self] report in
            DispatchQueue.main.async {
                self?.qualityGuidance = report.guidanceMessages
                self?.qualityLevel = report.qualityLevel
            }
        }
    }

    func start() {
        Task { await session.start() }
    }

    func continueFromInstructions() {
        Task { await session.proceedFromInstructions() }
    }

    func faceReady() {
        Task { await session.faceReady() }
    }

    func requestPermissions() {
        Task { await session.requestPermissions() }
    }

    func challengeCompleted() {
        Task { await session.challengeCompleted() }
    }

    func challengeStepReached(_ index: Int) {
        session.challengeStepReached(index)
    }

    func retry() {
        Task { await session.retry() }
    }

    func cancel() {
        session.cancel()
    }
}
#endif
