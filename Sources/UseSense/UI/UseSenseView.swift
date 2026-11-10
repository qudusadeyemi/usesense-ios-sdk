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

            switch viewModel.displayState {
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
                if viewModel.guided {
                    GuidedPageView(content: GuidedScreen.cameraStopped.content(),
                                   onPrimary: { viewModel.retry() }, onClose: close)
                } else {
                    cameraErrorView(message: message)
                }

            case .instructions(let challenge):
                if viewModel.guided {
                    GuidedPageView(content: GuidedScreen.primerTwoSteps(digits: challenge.challengeType == .speakPhrase).content(),
                                   onPrimary: { viewModel.continueFromInstructions() }, onClose: close)
                } else {
                    InstructionsView(challenge: challenge) {
                        viewModel.continueFromInstructions()
                    }
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
                if viewModel.extraCheckOnScanScreen {
                    GuidedChallengeView(camera: cameraLayer, display: viewModel.challenge,
                                        meter: viewModel.meter, onBack: viewModel.askToLeave)
                } else {
                    ZStack {
                        cameraLayer
                        BaselineOvalView()
                        challengeOverlay(spec)
                        captureOverlayChrome(phase: "VERIFYING")
                    }
                }

            case .extraCheckIntro(let spec):
                GuidedSheetScreen(backdrop: viewModel.uploadBackdropImage, onBack: viewModel.askToLeave) {
                    GuidedSheet(icon: ExtraCheckIcons.symbol(spec.challengeType),
                                title: ExtraCheckCopy.sheetTitle,
                                message: ExtraCheckCopy.sheetBody(for: spec),
                                primary: ExtraCheckCopy.continueButton,
                                onPrimary: { viewModel.extraCheckContinue() })
                    .accessibilityIdentifier("usesense.extracheck.sheet")
                }

            case .extraCheckDone:
                GuidedChallengeView(camera: cameraLayer, display: viewModel.challenge, done: true,
                                    onBack: viewModel.askToLeave)

            case .micUnavailable:
                GuidedPageView(content: GuidedScreen.micNeeded.content(),
                               onPrimary: { viewModel.openSettings() },
                               onSecondary: { viewModel.useMovementInstead() },
                               onClose: close,
                               busySecondary: viewModel.fallbackBusy)

            case .inlineStepUp where viewModel.extraCheckOnScanScreen:
                GuidedInlineStepUpView(camera: cameraLayer, display: viewModel.inlineStepUp,
                                       onBack: viewModel.askToLeave)

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
                GuidedUploadView(backdrop: viewModel.uploadBackdropImage, bar: viewModel.uploadBar,
                                 field: viewModel.contourField, onBack: close)

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

            case .done(let decision) where !viewModel.showsResultScreen:
                Color.black.ignoresSafeArea()
                    .onAppear { onComplete(.success(decision)) }

            case .done(let decision) where viewModel.guided:
                let screen = GuidedScreen.forDecision(decision.decision, retriesLeft: viewModel.rejectRetriesLeft)
                GuidedPageView(content: screen.content(),
                               onPrimary: {
                                   if case .rejected(true, _) = screen {
                                       viewModel.retryAfterReject()
                                   } else {
                                       onComplete(.success(decision))
                                   }
                               },
                               onSecondary: { onComplete(.success(decision)) })

            case .error(let error) where viewModel.guided && error.code != .userCancelled:
                guidedError(error)

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
        .overlay {
            if viewModel.leavePrompt {
                LeaveVerificationDialog(onLeave: close, onStay: viewModel.keepGoing)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.leavePrompt)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            viewModel.appBecameActive()
        }
        .statusBarHidden(viewModel.isCameraActive)
        .onDisappear { viewModel.restoreScreen() }
    }

    private func close() {
        viewModel.cancel()
        onCancel?()
    }

    // MARK: - Guided errors (storyboard flow 6)

    @ViewBuilder
    private func guidedError(_ error: UseSenseError) -> some View {
        let screen = GuidedScreen.forError(error, canResume: viewModel.canResumeFinalization)
        let action = errorAction(error)
        switch screen {
        case .uploadFailed:
            GuidedSheetScreen(backdrop: viewModel.uploadBackdropImage, onBack: close) {
                GuidedSheet(icon: "arrow.up", iconFill: CaptureColors.current.warning.color.opacity(0.16),
                            iconInk: CaptureColors.current.warning.color,
                            title: screen.content().title, message: screen.content().body,
                            primary: screen.content().primary, onPrimary: { viewModel.resumeFinalization() })
                .accessibilityIdentifier("usesense.upload.failed")
            }
        case .cameraDenied:
            GuidedPageView(content: screen.content(),
                           onPrimary: { viewModel.openSettings() },
                           onSecondary: { viewModel.retry() },
                           onClose: close)
        default:
            GuidedPageView(content: Self.relabel(screen.content(), primary: action.label),
                           onPrimary: action.run, onClose: close)
        }
    }

    private static func relabel(_ content: GuidedScreen.Content, primary: String) -> GuidedScreen.Content {
        var c = content
        c.primary = primary
        return c
    }

    /// What the error page's button does: send the kept capture again, start
    /// a clean attempt here, or hand the error back to the app.
    private func errorAction(_ error: UseSenseError) -> (label: String, run: () -> Void) {
        if error.isRetryable && viewModel.canResumeFinalization {
            return ("Try again", { viewModel.resumeFinalization() })
        }
        let expired = error.code == .sessionExpired || error.code == .tokenExpired
        let cameraStopped = GuidedScreen.forError(error, canResume: false) == .cameraStopped
        if (error.isRetryable || expired || cameraStopped) && viewModel.canRestartInPlace
            && (!expired || viewModel.ownsSession) {
            return (expired ? "Start again" : "Try again", { viewModel.retry() })
        }
        return ("Done", { onComplete(.failure(error)) })
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

final class UseSenseViewModel: ObservableObject, ColourTintHost {
    @Published var state: SessionState = .idle
    @Published var qualityGuidance: [QualityGuidance] = []
    @Published var qualityLevel: QualityLevel = .good
    @Published var challengeProgress: Double = 0
    @Published var completionResult: Result<RedactedDecisionObject, UseSenseError>?

    // Guided capture (capture redesign P1)
    @Published var guide = GuidedCaptureUpdate(snapshot: .initial, shutterAvailable: false)
    @Published var scan = ScanProgress(fraction: 0, paused: false, bankedSeconds: 0, totalSeconds: 0, completed: false)
    @Published var uploadBackdrop: UIImage?
    /// EVIDENCE-v1 colour sequence: the whole-screen tint showing now.
    @Published var tint: (color: Color, opacity: Double)? = nil
    /// EVIDENCE-v1 closer step: the oval's scale, and whether the person
    /// still needs to come closer.
    @Published var closer: (scale: CGFloat, needsCloser: Bool) = (1, false)

    // Guided extra check (storyboard flows 4 to 6)
    @Published var challenge = ChallengeDisplay.placeholder
    @Published var meter: [Double] = Array(repeating: 0, count: ExtraCheckTokens.meterBars)
    @Published var inlineStepUp = InlineStepUpDisplay.preparing
    @Published var leavePrompt = false
    @Published var fallbackBusy = false
    /// "Try again" taps used from the reject screen in this verification.
    private var rejectRetriesUsed = 0
    private var meterTick = 0

    private let session: UseSenseSession
    private let fillLight = ScreenFillLight()
    /// The colour sequence raised the brightness (not the fill light).
    private var colourRaisedBrightness = false
    private let readyHaptic = UIImpactFeedbackGenerator(style: .light)
    private let doneHaptic = UINotificationFeedbackGenerator()
    private var lastAnnouncement = Date.distantPast
    static let announcementInterval: TimeInterval = 1.2

    var guided: Bool { session.guidedCapture }
    /// The challenge is drawn on the scan screen (guided, not v4).
    var extraCheckOnScanScreen: Bool { session.guidedExtraCheck }
    var showsResultScreen: Bool { session.showsResultScreen }
    var rejectRetriesLeft: Int { max(0, session.retriesAfterReject - rejectRetriesUsed) }
    /// A self-created session (this object can mint a new one).
    var ownsSession: Bool { session.ownsSession }
    var contourField: ContourDepthField { session.contourField }
    var scanSecondsForCopy: Int { session.guidedScanSeconds }

    /// One bar for upload and checking.
    /// The state the screen shows. Normally `state`; the DEBUG capture rig
    /// can hold a guided screen (FORCE_STATE) for screenshots.
    var displayState: SessionState {
        #if DEBUG
        if guided, let forced = DebugCaptureRig.forcedState {
            switch (forced, state) {
            case (.align, .faceGuide), (.align, .baseline): return .faceGuide
            case (.scan, .faceGuide), (.scan, .baseline): return .baseline(remaining: 0)
            case (.upload, .faceGuide), (.upload, .baseline): return .uploading(progress: 0)
            default: break
            }
        }
        #endif
        return state
    }

    /// Upload backdrop: the last banked frame (or the rig's frame when forced).
    var uploadBackdropImage: UIImage? {
        return uploadBackdrop
    }

    /// The upload bar: sending, then checking, eased so it never sits still.
    var uploadBar: UploadBar {
        #if DEBUG
        if DebugCaptureRig.forcedState == .upload {
            return UploadBar(stage: .sending, startValue: 0.64, since: Date(), fixed: 0.64)
        }
        #endif
        return uploadBarState ?? .start()
    }
    /// Starts when the upload does (nil before).
    private var uploadBarState: UploadBar?

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
    /// The guided screens drop it (capture kit SPEC: no footer on capture).
    var showsCaptureFooter: Bool {
        switch state {
        case .faceGuide, .baseline, .uploading, .completing: return !guided
        case .challenge: return !extraCheckOnScanScreen
        case .inlineStepUp: return !extraCheckOnScanScreen
        case .zoom, .countdown: return true
        default: return false
        }
    }

    /// "Try Again" on a reject: standalone sessions only (see isInjected).
    var canRetryFromResult: Bool { !session.isInjected }

    var isCameraActive: Bool {
        switch state {
        case .faceGuide, .baseline, .countdown, .challenge, .inlineStepUp, .extraCheckDone: return true
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
        #if DEBUG
        if DebugCaptureRig.forcedState == .scan {
            scan = ScanProgress(fraction: DebugCaptureRig.forcedProgress ?? 0.5, paused: false,
                                bankedSeconds: 1.5, totalSeconds: 3, completed: false)
        }
        #endif
        session.colourTintHost = self
        session.onCloserUpdate = { [weak self] scale, needsCloser in
            DispatchQueue.main.async { self?.closer = (scale, needsCloser) }
        }
        session.onScanUpdate = { [weak self] progress in
            DispatchQueue.main.async { self?.apply(scan: progress) }
        }
        session.onChallengeUpdate = { [weak self] display in
            DispatchQueue.main.async { self?.apply(challenge: display) }
        }
        session.onInlineStepUpUpdate = { [weak self] display in
            DispatchQueue.main.async { self?.apply(inlineStepUp: display) }
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
        let previous = state
        state = newState
        switch newState {
        case .faceGuide:
            uploadBackdrop = nil
            uploadBarState = nil
            #if DEBUG
            if DebugCaptureRig.forcedState != nil { break }
            #endif
            scan = ScanProgress(fraction: 0, paused: false, bankedSeconds: 0, totalSeconds: 0, completed: false)
            readyHaptic.prepare()
        case .challenge(let spec):
            if extraCheckOnScanScreen, case .challenge = previous {} else {
                challenge = ChallengeRunner(spec: spec)?.display() ?? .placeholder
                meter = Array(repeating: 0, count: ExtraCheckTokens.meterBars)
            }
            doneHaptic.prepare()
        case .extraCheckIntro:
            // Round 2 gets its own upload bar and backdrop.
            uploadBarState = nil
            fillLight.restore()
        case .extraCheckDone:
            uploadBackdrop = nil
            doneHaptic.notificationOccurred(.success)
            announce(ExtraCheckCopy.done)
        case .inlineStepUp:
            if case .inlineStepUp = previous {} else { inlineStepUp = .preparing }
        case .baseline, .zoom, .countdown:
            doneHaptic.prepare()
        case .uploading(let p):
            fillLight.restore()
            uploadBarState = (uploadBarState ?? .start()).advanced(to: p >= 1 ? .checking : .sending)
            if guided, uploadBackdrop == nil {
                uploadBackdrop = session.lastCapturedFrame().flatMap { UIImage(data: $0) }
            }
        case .completing:
            fillLight.restore()
            uploadBarState = (uploadBarState ?? .start()).advanced(to: .checking)
            if guided, uploadBackdrop == nil {
                uploadBackdrop = session.lastCapturedFrame().flatMap { UIImage(data: $0) }
            }
        default:
            fillLight.restore()
        }
        if newState.isTerminal || newState.isIdle {
            if leavePrompt { session.setChallengeHeld(false) }
            leavePrompt = false
            fallbackBusy = false
        }
        if case .micUnavailable = newState { fallbackBusy = false }
    }

    private func apply(inlineStepUp display: InlineStepUpDisplay) {
        let old = inlineStepUp
        inlineStepUp = display
        // A flash lights the face: screen to full brightness while it runs.
        if display.flashColor != nil { fillLight.activate() }
        if display.title != old.title || display.subtitle != old.subtitle {
            announce(display.subtitle.map { "\(display.title). \($0)" } ?? display.title)
        }
    }

    private func apply(challenge display: ChallengeDisplay) {
        let old = challenge
        challenge = display
        if display.kind == .digits {
            meterTick &+= 1
            if meterTick % 2 == 0 { meter = Array(meter.dropFirst()) + [display.level] }
        }
        if display.title != old.title || display.subtitle != old.subtitle {
            announce(display.subtitle.map { "\(display.title). \($0)" } ?? display.title)
        }
    }

    private func apply(guide incoming: GuidedCaptureUpdate) {
        var update = incoming
        #if DEBUG
        if let pinned = DebugCaptureRig.forcedHint { update.snapshot.hint = pinned }
        #endif
        let wasPassing = guide.snapshot.allPass
        let oldHint = guide.snapshot.hint
        guide = update
        #if DEBUG
        if DebugCaptureRig.forcedState == .upload, uploadBackdrop == nil {
            uploadBackdrop = session.debugCurrentFrame()
        }
        #endif
        if update.snapshot.fillLight { fillLight.activate() }
        if case .faceGuide = state, update.snapshot.allPass, !wasPassing {
            readyHaptic.impactOccurred()
        }
        if let hint = update.snapshot.hint, hint != oldHint {
            announce(hint.subtitle.map { "\(hint.title). \($0)" } ?? hint.title)
        }
    }

    private func apply(scan progress: ScanProgress) {
        #if DEBUG
        if DebugCaptureRig.forcedState != nil { return }
        #endif
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

    // MARK: EVIDENCE-v1 colour sequence (ColourTintHost, main thread)

    func showTint(_ colour: String?, opacity: Double) {
        guard let colour else { tint = nil; return }
        tint = (CaptureColors.pick(colour, CaptureColors.RGB(r: 1, g: 1, b: 1)).color, opacity)
    }

    func holdFullBrightness() -> Double? {
        if !fillLight.isActive {
            fillLight.activate()
            colourRaisedBrightness = fillLight.isActive
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first).map { Double($0.screen.brightness) }
    }

    func releaseFullBrightness() {
        // The fill light, if it came on meanwhile, keeps the brightness.
        if colourRaisedBrightness, !guide.snapshot.fillLight { fillLight.restore() }
        colourRaisedBrightness = false
    }

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

    // MARK: Guided extra check

    func extraCheckContinue() { Task { await session.extraCheckContinue() } }

    /// Back mid extra check: confirm first; the challenge holds meanwhile.
    func askToLeave() {
        session.setChallengeHeld(true)
        leavePrompt = true
    }

    func keepGoing() {
        leavePrompt = false
        session.setChallengeHeld(false)
    }

    func useMovementInstead() {
        guard !fallbackBusy else { return }
        fallbackBusy = true
        Task { await session.useMovementInstead() }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Back from Settings: carry on if the microphone is now allowed.
    func appBecameActive() {
        if case .micUnavailable = state, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            Task { await session.retryMicrophone() }
        }
    }

    func retryAfterReject() {
        rejectRetriesUsed += 1
        retry()
    }
}
#endif
