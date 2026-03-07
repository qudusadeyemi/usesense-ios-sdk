#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import AVFoundation

struct UseSenseVerificationView: View {
    @StateObject private var session: UseSenseSessionManager
    @Environment(\.dismiss) private var dismiss
    private let theme: UseSenseTheme

    init(
        config: UseSenseConfig,
        theme: UseSenseTheme,
        request: VerificationRequest,
        onResult: @escaping (Result<UseSenseResult, UseSenseError>) -> Void,
        onCancelled: @escaping () -> Void
    ) {
        let manager = UseSenseSessionManager(config: config, theme: theme, request: request)
        manager.onResult = onResult
        manager.onCancelled = onCancelled
        _session = StateObject(wrappedValue: manager)
        self.theme = theme
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch session.state {
            case .idle, .created:
                ProgressView()
                    .tint(UseSenseTheme.Colors.indigo500)

            case .permissionsRequired:
                permissionsView

            case .instructions(let challenge):
                InstructionsView(
                    theme: theme,
                    challengeType: challenge.type,
                    onStart: { session.didTapInstructionsButton() }
                )

            case .faceGuide:
                cameraWithOverlay {
                    FaceGuideOverlay(
                        label: theme.localization.faceGuideLabel,
                        buttonLabel: theme.localization.faceGuideButton,
                        onReady: { session.didTapFaceReady() }
                    )
                }

            case .baseline:
                cameraWithOverlay {
                    baselineOverlay
                }

            case .countdown(let number):
                cameraWithOverlay {
                    CountdownOverlay(number: number, label: theme.localization.countdownLabel)
                }

            case .challenge(let spec):
                cameraWithOverlay {
                    challengeOverlay(for: spec)
                }

            case .uploading(let progress):
                ProcessingView(label: "Uploading...", progress: progress)

            case .completing:
                ProcessingView(label: theme.localization.processingLabel, progress: nil)

            case .done(let result):
                if theme.showResultScreen {
                    resultView(result: result)
                }

            case .error(let error):
                errorView(error: error)
            }
        }
        .statusBarHidden(true)
        .task { await session.start() }
    }

    // MARK: - Subviews

    private func cameraWithOverlay<Overlay: View>(@ViewBuilder overlay: () -> Overlay) -> some View {
        ZStack {
            CameraPreviewView(session: session.frameCaptureManager.captureSession)
                .ignoresSafeArea()
            overlay()
        }
    }

    private var baselineOverlay: some View {
        VStack {
            Text(theme.localization.baselineLabel)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(UseSenseTheme.Colors.indigo500.opacity(0.9)))
                .padding(.top, 60)
            Spacer()
        }
    }

    private func challengeOverlay(for spec: ChallengeSpec) -> some View {
        Group {
            switch spec.type {
            case .followDot:
                if let waypoints = spec.waypoints {
                    FollowDotChallengeView(
                        waypoints: waypoints,
                        dotSizePx: spec.dotSizePx ?? 20,
                        currentWaypointIndex: $session.currentWaypointIndex
                    )
                }
            case .headTurn:
                if let sequence = spec.sequence {
                    HeadTurnChallengeView(
                        sequence: sequence,
                        currentStepIndex: $session.currentStepIndex
                    )
                }
            case .speakPhrase:
                SpeakPhraseChallengeView(
                    phrase: spec.phrase ?? ""
                )
            }
        }
    }

    private var permissionsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundColor(UseSenseTheme.Colors.indigo500)
            Text("Camera access is required for verification.")
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func resultView(result: UseSenseResult) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: result.decision == .approve ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(result.decision == .approve ? .green : .red)

            Text(result.decision == .approve ? theme.localization.successLabel : theme.localization.failureLabel)
                .font(.title2.weight(.bold))
                .foregroundColor(.white)

            Spacer()

            Button("Done") { dismiss() }
                .font(.body.weight(.bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: theme.buttonCornerRadius).fill(UseSenseTheme.Colors.indigo600))
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
        }
        .background(Color.black)
    }

    private func errorView(error: UseSenseError) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundColor(.orange)

            Text(error.message)
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Button("Close") { dismiss() }
                .font(.body.weight(.bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: theme.buttonCornerRadius).fill(UseSenseTheme.Colors.indigo600))
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
        }
        .background(Color.black)
    }
}

// MARK: - View Modifier for SwiftUI Integration

public struct UseSenseVerificationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let request: VerificationRequest
    let onResult: (Result<UseSenseResult, UseSenseError>) -> Void
    let onCancelled: () -> Void

    public func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            if let config = UseSense.shared.config {
                UseSenseVerificationView(
                    config: config,
                    theme: UseSense.shared.theme,
                    request: request,
                    onResult: { result in
                        isPresented = false
                        onResult(result)
                    },
                    onCancelled: {
                        isPresented = false
                        onCancelled()
                    }
                )
            }
        }
    }
}

public extension View {
    func useSenseVerification(
        isPresented: Binding<Bool>,
        request: VerificationRequest,
        onResult: @escaping (Result<UseSenseResult, UseSenseError>) -> Void,
        onCancelled: @escaping () -> Void = {}
    ) -> some View {
        modifier(UseSenseVerificationModifier(
            isPresented: isPresented,
            request: request,
            onResult: onResult,
            onCancelled: onCancelled
        ))
    }
}
#endif
