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
                    captureOverlayChrome(phase: "BASELINE")
                }

            case .challenge(let spec):
                ZStack {
                    cameraLayer
                    challengeOverlay(spec)
                    captureOverlayChrome(phase: "CHALLENGE")
                }

            case .uploading(let progress):
                ProcessingView(
                    title: "Uploading",
                    subtitle: "Sending verification data...",
                    progress: progress
                )

            case .completing:
                ProcessingView(
                    title: "Verifying",
                    subtitle: "Analyzing your identity..."
                )

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

            // Phase badge + close button
            VStack {
                HStack {
                    PhaseBadge(phase: "BASELINE")
                        .padding(.leading, 16)
                    Spacer()
                    closeButton
                }
                Spacer()
            }
            .padding(.top, 8)

            // Quality warning at bottom
            VStack {
                Spacer()
                if let guidance = viewModel.qualityGuidance.first {
                    QualityWarningBanner(guidance: guidance, qualityLevel: viewModel.qualityLevel)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                }
            }
        }
    }

    /// Chrome overlay for countdown and challenge phases: phase badge, close button, progress, quality.
    private func captureOverlayChrome(phase: String) -> some View {
        VStack {
            HStack {
                PhaseBadge(phase: phase)
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

    // MARK: - Challenge Overlay

    @ViewBuilder
    private func challengeOverlay(_ spec: ChallengeSpecWrapper) -> some View {
        // Use the challenge seed as a stable identity so SwiftUI does not
        // recreate (and reset @State in) the challenge view on parent re-renders.
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
