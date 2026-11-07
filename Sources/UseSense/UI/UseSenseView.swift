#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import AVFoundation
import UIKit

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
                if viewModel.guided {
                    GuidedCaptureView(mode: .align, camera: cameraLayer, viewModel: viewModel, onClose: close)
                } else {
                    cameraWithFaceGuide
                }

            case .baseline:
                if viewModel.guided {
                    GuidedCaptureView(mode: .scan, camera: cameraLayer, viewModel: viewModel, onClose: close)
                } else {
                    cameraWithBaseline
                }

            case .zoom:
                // V4 zoom-motion state. The legacy UI does not render this;
                // V4 sessions use their own view path (LiveSenseV4Session).
                // Render baseline as a benign fallback so the switch stays
                // exhaustive without breaking the legacy capture flow.
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

            case .inlineStepUp(let phase):
                ZStack {
                    cameraLayer
                    BaselineOvalView()

                    // Step-up overlay: shield icon, "Additional Verification"
                    VStack(spacing: 16) {
                        Spacer()

                        Image(systemName: "shield.checkered")
                            .font(.system(size: 36))
                            .foregroundColor(Color.UseSense.primary)

                        Text("Additional Verification")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)

                        Text(phase == "preparing" ? "Preparing..." : "Hold still -- verifying...")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))

                        Spacer()
                    }
                }

            case .uploading where viewModel.guided, .completing where viewModel.guided:
                GuidedUploadView(backdrop: viewModel.uploadBackdrop, progress: viewModel.uploadProgress)

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
                ResultView(decision: decision,
                           headerLogoURL: viewModel.showsHeader ? viewModel.headerLogoURL : nil,
                           headerDisplayName: viewModel.showsHeader ? viewModel.headerDisplayName : nil,
                           onDismiss: {
                    onComplete(.success(decision))
                }, onRetry: viewModel.canRetryFromResult ? {
                    viewModel.retry()
                } : nil)

            case .error(let error):
                FailureView(error: error, onRetry: {
                    // "Start over": a clean attempt runs in place only when
                    // that's possible here; otherwise the host (e.g. the
                    // Flows runner) gets the error and re-inits the step.
                    if error.isRetryable && viewModel.canRestartInPlace {
                        viewModel.retry()
                    } else {
                        onComplete(.failure(error))
                    }
                }, onCancel: onCancel, onResume: viewModel.canResumeFinalization ? {
                    // "Retry": the capture is still good, so finish it on the
                    // same session (also for injected Flows/hosted sessions).
                    viewModel.resumeFinalization()
                } : nil)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.showsCaptureFooter { CaptureFooter() }
        }
        .statusBarHidden(viewModel.isCameraActive)
        .onDisappear { viewModel.restoreScreen() }
    }

    private func close() {
        viewModel.cancel()
        onCancel?()
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
                        .padding(.bottom, 8)
                }
            }
            // Clears the "Powered by Sense" capture footer.
            .padding(.bottom, CaptureFooter.clearance)
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
            .padding(.bottom, CaptureFooter.clearance)
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
                        .foregroundColor(USColors.primaryForeground)
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
                        .foregroundColor(USColors.primaryForeground)
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
        Button(action: close) {
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

// MARK: - Capture footer ("Powered by Sense", 50% white, as Android's capture footer)

struct CaptureFooter: View {
    /// Bottom space content above the footer must leave (12pt text + 2 x 12pt
    /// padding, plus a small gap).
    static let clearance: CGFloat = 44

    var body: some View {
        Text("Powered by Sense")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .allowsHitTesting(false)
            .accessibilityIdentifier("usesense.capture.footer")
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

    // Guided capture (capture redesign P1)
    @Published var guide = GuidedCaptureUpdate(snapshot: .initial, shutterAvailable: false)
    @Published var scan = ScanProgress(fraction: 0, paused: false, bankedSeconds: 0, totalSeconds: 0, completed: false)
    @Published var uploadBackdrop: UIImage?

    private let session: UseSenseSession
    private let fillLight = ScreenFillLight()
    private let readyHaptic = UIImpactFeedbackGenerator(style: .light)
    private let doneHaptic = UINotificationFeedbackGenerator()
    private var lastAnnouncement = Date.distantPast
    static let announcementInterval: TimeInterval = 1.2

    var guided: Bool { session.guidedCapture }
    var contourField: ContourDepthField { session.contourField }
    var scanSecondsForCopy: Int { session.guidedScanSeconds }

    /// One bar for upload and checking.
    var uploadProgress: Double {
        switch state {
        case .uploading(let p): return p >= 1 ? 0.7 : 0.55
        case .completing: return 0.95
        case .done: return 1
        default: return 0.04
        }
    }

    var previewLayer: AVCaptureVideoPreviewLayer? {
        session.previewLayer
    }

    /// Result header lockup. A Flow's resolved appearance (logo / placement)
    /// wins over the session's own branding; placement `none` hides it.
    var headerLogoURL: URL? { FlowAppearanceResolver.logoURL ?? session.brandLogoURL }
    var headerDisplayName: String? { session.brandDisplayName }
    var showsHeader: Bool {
        FlowAppearanceResolver.logoPlacement != AppearanceLogo.Placement.none &&
            (headerLogoURL != nil || headerDisplayName != nil)
    }

    /// The capture screens (camera up to the result) carry the
    /// "Powered by Sense" footer, as on Android.
    var showsCaptureFooter: Bool {
        switch state {
        case .faceGuide, .baseline, .zoom, .countdown, .challenge, .inlineStepUp, .uploading, .completing: return true
        default: return false
        }
    }

    /// "Try Again" on a reject: standalone sessions only (see isInjected).
    var canRetryFromResult: Bool { !session.isInjected }

    var isCameraActive: Bool {
        switch state {
        case .faceGuide, .baseline, .countdown, .challenge, .inlineStepUp: return true
        default: return false
        }
    }

    init(session: UseSenseSession) {
        self.session = session
        session.onStateChange = { [weak self] newState in
            DispatchQueue.main.async {
                self?.apply(state: newState)
            }
        }
        session.onGuideUpdate = { [weak self] update in
            DispatchQueue.main.async { self?.apply(guide: update) }
        }
        session.onScanUpdate = { [weak self] progress in
            DispatchQueue.main.async { self?.apply(scan: progress) }
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

    // MARK: Guided capture

    private func apply(state newState: SessionState) {
        state = newState
        switch newState {
        case .faceGuide:
            uploadBackdrop = nil
            scan = ScanProgress(fraction: 0, paused: false, bankedSeconds: 0, totalSeconds: 0, completed: false)
            readyHaptic.prepare()
        case .baseline, .zoom, .countdown, .challenge, .inlineStepUp:
            doneHaptic.prepare()
        case .uploading, .completing:
            fillLight.restore()
            if guided, uploadBackdrop == nil {
                uploadBackdrop = session.lastCapturedFrame().flatMap { UIImage(data: $0) }
            }
        default:
            fillLight.restore()
        }
    }

    private func apply(guide update: GuidedCaptureUpdate) {
        let wasPassing = guide.snapshot.allPass
        let oldHint = guide.snapshot.hint
        guide = update
        if update.snapshot.fillLight { fillLight.activate() }
        if case .faceGuide = state, update.snapshot.allPass, !wasPassing {
            readyHaptic.impactOccurred()
        }
        if let hint = update.snapshot.hint, hint != oldHint {
            announce(hint.subtitle.map { "\(hint.title). \($0)" } ?? hint.title)
        }
    }

    private func apply(scan progress: ScanProgress) {
        let wasComplete = scan.completed
        scan = progress
        if progress.completed, !wasComplete { doneHaptic.notificationOccurred(.success) }
    }

    /// VoiceOver hint, rate-limited like the on-screen hint (1.2 s).
    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnnouncement) >= Self.announcementInterval else { return }
        lastAnnouncement = now
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    func setViewport(_ size: CGSize) { session.setViewport(size) }

    func shutterTapped() { Task { await session.shutterTapped() } }

    func restoreScreen() { fillLight.restore() }

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

    var canRestartInPlace: Bool { session.canRestartInPlace }

    var canResumeFinalization: Bool { session.canResumeFinalization }

    func resumeFinalization() {
        Task { await session.resumeFinalization() }
    }

    func cancel() {
        session.cancel()
    }
}
#endif
