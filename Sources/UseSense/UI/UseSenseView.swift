#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import AVFoundation

public struct UseSenseView: View {
    @ObservedObject private var viewModel: UseSenseViewModel
    private let onComplete: (Result<RedactedDecisionObject, UseSenseError>) -> Void
    private let onCancel: (() -> Void)?

    public init(
        session: UseSenseSession,
        onComplete: @escaping (Result<RedactedDecisionObject, UseSenseError>) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self._viewModel = ObservedObject(wrappedValue: UseSenseViewModel(session: session))
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
                cameraWithFaceGuide

            case .countdown(let number):
                ZStack {
                    cameraLayer
                    CountdownOverlay(number: number)
                }

            case .challenge(let spec):
                ZStack {
                    cameraLayer
                    challengeOverlay(spec)
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
                ResultView(decision: decision) {
                    onComplete(.success(decision))
                }

            case .error(let error):
                errorView(error)
            }
        }
        .statusBarHidden(viewModel.isCameraActive)
        .onChange(of: viewModel.completionResult) { result in
            if let result = result {
                onComplete(result)
            }
        }
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
            FaceGuideOverlay(qualityGuidance: viewModel.qualityGuidance)

            // Close button
            VStack {
                HStack {
                    Spacer()
                    closeButton
                }
                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Challenge Overlay

    @ViewBuilder
    private func challengeOverlay(_ spec: ChallengeSpecWrapper) -> some View {
        switch spec {
        case .followDot(let challenge):
            FollowDotChallengeView(
                challenge: challenge,
                onComplete: { viewModel.challengeCompleted() },
                onStepReached: { viewModel.challengeStepReached($0) }
            )
        case .headTurn(let challenge):
            HeadTurnChallengeView(
                challenge: challenge,
                onComplete: { viewModel.challengeCompleted() },
                onStepReached: { viewModel.challengeStepReached($0) }
            )
        case .speakPhrase(let challenge):
            SpeakPhraseChallengeView(
                challenge: challenge,
                onComplete: { viewModel.challengeCompleted() }
            )
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

    // MARK: - Error View

    private func errorView(_ error: UseSenseError) -> some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Color.UseSense.error)

                Text("Something went wrong")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color.UseSense.textPrimary)

                Text(error.message)
                    .font(.system(size: 16))
                    .foregroundColor(Color.UseSense.textSecondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button(action: { viewModel.retry() }) {
                        Text("Retry")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.UseSense.primary)
                            .cornerRadius(12)
                    }

                    if let onCancel = onCancel {
                        Button(action: {
                            onCancel()
                        }) {
                            Text("Cancel")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Color.UseSense.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color.UseSense.border)
                                .cornerRadius(12)
                        }
                    }
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
    }
}

// MARK: - ViewModel

final class UseSenseViewModel: ObservableObject {
    @Published var state: SessionState = .idle
    @Published var qualityGuidance: [QualityGuidance] = []
    @Published var completionResult: Result<RedactedDecisionObject, UseSenseError>?

    private let session: UseSenseSession
    private var stateObserver: (() -> Void)?

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
        session.onQualityUpdate = { [weak self] guidance in
            DispatchQueue.main.async {
                self?.qualityGuidance = guidance
            }
        }
    }

    func start() {
        Task { await session.start() }
    }

    func continueFromInstructions() {
        Task { await session.proceedFromInstructions() }
    }

    func requestPermissions() {
        Task { await session.requestPermissions() }
    }

    func challengeCompleted() {
        Task { await session.challengeCompleted() }
    }

    func challengeStepReached(_ index: Int) {
        session.recordChallengeStep(index: index)
    }

    func retry() {
        Task { await session.retry() }
    }

    func cancel() {
        session.cancel()
    }
}
#endif
