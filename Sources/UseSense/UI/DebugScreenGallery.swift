#if DEBUG && canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit

/// DEBUG builds only: every extra-check screen, held still for screenshots
/// (`-USESENSE_SCREEN <name>` in the Example app). Challenge screens come from
/// the real `ChallengeRunner`, driven with scripted observations, so the copy
/// on a screenshot is what the runner produces. Names follow the storyboard's
/// Phone screens table; `legacy_*` render today's (pre-4.11) screens.
public struct UseSenseDebugScreen: View {
    let name: String
    let backdrop: UIImage?

    public init(name: String, backdrop: UIImage?) {
        self.name = name
        self.backdrop = backdrop
    }

    public static let names = [
        "primer_two", "primer_digits", "xc_head", "xc_dot", "xc_digits", "head_left", "head_right", "head_paused",
        "head_again", "dot_1", "dot_2", "dot_lost", "digits", "digits_quiet", "mic_denied", "xc_done", "leave",
        "approved", "review", "rejected_retry", "rejected", "perm_denied", "cam_error", "offline", "expired",
        "error", "upload_failed", "rmas_blink", "rmas_turn", "rmas_smile", "flash", "head_covered", "dot_two_people",
        "upload", "loading", "camera_request", "help",
        "legacy_countdown", "legacy_head", "legacy_dot", "legacy_inline_stepup", "legacy_approved",
        "legacy_rejected", "legacy_error", "legacy_instructions",
    ]

    private var camera: some View {
        Group {
            if let backdrop {
                Image(uiImage: backdrop).resizable().scaledToFill()
            } else {
                Color(white: 0.2)
            }
        }
        .ignoresSafeArea()
    }

    public var body: some View {
        CaptureThemeRoot {
            ZStack {
                CaptureTokens.cam.ignoresSafeArea()
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch name {
        case "primer_two": page(.primerTwoSteps(digits: false))
        case "primer_digits": page(.primerTwoSteps(digits: true))
        case "mic_denied": page(.micNeeded)
        case "approved": page(.approved)
        case "review": page(.review)
        case "rejected_retry": page(.rejected(canRetry: true, onceMore: true))
        case "rejected": page(.rejected(canRetry: false, onceMore: false))
        case "perm_denied": page(.cameraDenied)
        case "cam_error": page(.cameraStopped)
        case "offline": page(.offline)
        case "expired": page(.expired)
        case "error": page(.error)
        case "xc_head", "xc_dot", "xc_digits":
            let spec = Self.spec(name == "xc_head" ? .headTurn : name == "xc_dot" ? .followDot : .speakPhrase)
            GuidedSheetScreen(backdrop: backdrop, onBack: {}) {
                GuidedSheet(icon: ExtraCheckIcons.symbol(spec.challengeType), title: ExtraCheckCopy.sheetTitle,
                            message: ExtraCheckCopy.sheetBody(for: spec), primary: ExtraCheckCopy.continueButton)
            }
        case "upload_failed":
            let c = GuidedScreen.uploadFailed.content()
            GuidedSheetScreen(backdrop: backdrop, onBack: {}) {
                GuidedSheet(icon: c.icon, iconTone: .tone(.warning), title: c.title, message: c.body, primary: c.primary)
            }
        case "upload":
            GuidedUploadView(backdrop: backdrop, bar: UploadBar(stage: .sending, startValue: 0.64, since: Date(), fixed: 0.64),
                             onBack: {})
        case "loading": CaptureLoadingView()
        case "camera_request": page(.cameraRequest)
        case "help":
            ZStack {
                GuidedChallengeView(camera: camera, display: Self.display("head_left"), onBack: {})
                CaptureHelpDialog(title: CaptureCopyText.helpTitle, message: CaptureCopyText.helpBody) {}
            }
        case "rmas_blink", "rmas_turn", "rmas_smile", "flash":
            GuidedInlineStepUpView(camera: camera, display: Self.inline(name), onBack: {})
        case "xc_done":
            GuidedChallengeView(camera: camera, display: Self.display("head_right"), done: true, onBack: {})
        case "leave":
            ZStack {
                GuidedChallengeView(camera: camera, display: Self.display("head_left"), onBack: {})
                LeaveVerificationDialog(onLeave: {}, onStay: {})
            }
        case "legacy_countdown":
            ZStack { camera; BaselineOvalView(); CountdownOverlay(number: 3) }
        case "legacy_head":
            if case .headTurn(let c) = Self.spec(.headTurn) {
                ZStack { camera; BaselineOvalView()
                    HeadTurnChallengeView(challenge: c, onComplete: {}, onStepReached: { _ in }) }
            }
        case "legacy_dot":
            if case .followDot(let c) = Self.spec(.followDot) {
                ZStack { camera; BaselineOvalView()
                    FollowDotChallengeView(challenge: c, onComplete: {}, onStepReached: { _ in }) }
            }
        case "legacy_inline_stepup":
            ZStack {
                camera; BaselineOvalView()
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "shield.checkered").font(.system(size: 36)).foregroundColor(Color.UseSense.primary)
                    Text("Additional Verification").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                    Text("Hold still -- verifying...").font(.system(size: 14)).foregroundColor(.white.opacity(0.7))
                    Spacer()
                }
            }
        case "legacy_approved": ResultView(decision: Self.decision("APPROVE"), onDismiss: {})
        case "legacy_rejected": ResultView(decision: Self.decision("REJECT"), onDismiss: {}, onRetry: {})
        case "legacy_error":
            FailureView(error: UseSenseError(code: .networkError, isRetryable: true), onRetry: {}, onCancel: {})
        case "legacy_instructions": InstructionsView(challenge: Self.spec(.headTurn)) {}
        default:
            GuidedChallengeView(camera: camera, display: Self.display(name),
                                meter: name == "digits" ? [0.3, 0.5, 0.85, 0.6, 0.95, 0.45, 0.7, 0.35, 0.2]
                                    : name == "digits_quiet" ? [0.02, 0.04, 0.02, 0.06, 0.02, 0.04, 0.02, 0.02, 0.02] : [],
                                onBack: {})
        }
    }

    private func page(_ screen: GuidedScreen) -> some View {
        GuidedPageView(content: screen.content(), onPrimary: {}, onSecondary: {}, onClose: {})
    }

    // MARK: Fixtures

    static func spec(_ type: ChallengeType) -> ChallengeSpecWrapper {
        let json: String
        switch type {
        case .headTurn:
            json = #"{"type":"head_turn","seed":"demo","total_duration_ms":5500,"sequence":[{"direction":"left","duration_ms":2000,"index":0},{"direction":"right","duration_ms":2000,"index":1},{"direction":"center","duration_ms":1500,"index":2}]}"#
        case .followDot:
            json = #"{"type":"follow_dot","seed":"demo","dot_size_px":24,"total_duration_ms":4000,"waypoints":[{"x":0.5,"y":0.28,"duration_ms":1000,"index":0},{"x":0.77,"y":0.25,"duration_ms":1000,"index":1},{"x":0.24,"y":0.56,"duration_ms":1000,"index":2},{"x":0.7,"y":0.5,"duration_ms":1000,"index":3}]}"#
        case .speakPhrase:
            json = #"{"type":"speak_phrase","seed":"demo","phrase":"4 7 2 9","phrase_language":"numeric","total_duration_ms":6000}"#
        }
        return try! JSONDecoder().decode(ChallengeSpecWrapper.self, from: Data(json.utf8))
    }

    /// Run the real runner with scripted observations up to the named moment.
    static func display(_ name: String) -> ChallengeDisplay {
        let type: ChallengeType = name.hasPrefix("dot") ? .followDot : name.hasPrefix("digits") ? .speakPhrase : .headTurn
        var r = ChallengeRunner(spec: spec(type))!
        var t: TimeInterval = 0
        var d = ChallengeDisplay.placeholder
        let left = 25 * ChallengeRunner.leftYawSign
        func run(_ seconds: TimeInterval, face: Bool = true, yaw: Double = 0, level: Double? = nil,
                 hint: GateHint? = nil) {
            let end = t + seconds
            while t < end - 1e-9 {
                t += 0.05
                d = r.advance(ChallengeObservation(time: t, facePresent: face, yaw: yaw, pitch: 0, level: level, hint: hint))
            }
        }
        switch name {
        case "head_left": run(0.3, yaw: left)
        case "head_right": run(0.75, yaw: left); run(0.3, yaw: -left)
        case "head_paused": run(0.3, yaw: left); run(0.6, face: false)
        case "head_covered": run(0.3, yaw: left); run(0.6, face: false, hint: .uncovered)
        case "dot_two_people": run(1.3); run(0.6, face: false, hint: .onePerson)
        case "head_again": run(ChallengeRunner.hintAfter + 0.2, yaw: left / 5)
        case "dot_1": run(1.3)
        case "dot_2": run(2.4)
        case "dot_lost": run(1.3); run(0.6, face: false)
        case "digits": run(2.5, level: 0.6)
        case "digits_quiet": run(2.6, level: 0.02)
        default: run(0.1)
        }
        return d
    }

    static func inline(_ name: String) -> InlineStepUpDisplay {
        switch name {
        case "rmas_blink": return InlineStepUpDisplay(.action(type: "blink", step: 0, steps: 3))
        case "rmas_turn": return InlineStepUpDisplay(.action(type: "turn_left", step: 1, steps: 3))
        case "rmas_smile": return InlineStepUpDisplay(.action(type: "smile", step: 2, steps: 3))
        default: return InlineStepUpDisplay(.flash(color: "#00FFFF", step: 1, steps: 6))
        }
    }

    static func decision(_ value: String) -> RedactedDecisionObject {
        RedactedDecisionObject(sessionId: "s", sessionType: nil, identityId: nil, decision: value,
                               timestamp: "2026-11-10T00:00:00Z")
    }
}

/// DEBUG builds only: the BRAND-v1 section 8 test brands for screenshots
/// (`-USESENSE_BRAND acme|nightpay`). Applied through the public resolvers,
/// as a Flow or session would.
public enum UseSenseDebugBrand {
    @MainActor public static func applyFromLaunchArguments() {
        guard let name = DebugCaptureRig.value("USESENSE_BRAND") else { return }
        apply(name)
    }

    @MainActor public static func apply(_ name: String) {
        switch name {
        case "acme":
            FlowAppearanceResolver.set(FlowAppearance(
                colors: AppearanceColors(primary: "#1F7A4D", background: "#FFFFFF", surface: "#F3F6F4",
                                         foreground: "#13261C", muted: "#5B6B62", border: "#D8E0DB"),
                typography: AppearanceTypography(fontFamily: "Inter", displayFamily: "Georgia"),
                shape: AppearanceShape(radius: 12, buttonRadius: 999, buttonStyle: .filled),
                logo: AppearanceLogo(url: logoDataURL(), placement: .header, height: 28),
                mode: .light))
            FlowCopyResolver.setDisplayName("Acme Bank")
        case "nightpay":
            FlowAppearanceResolver.set(FlowAppearance(
                colors: AppearanceColors(primary: "#3A1D8F", dark: AppearanceColors.DarkOverrides(
                    background: "#0B0B12", surface: "#16162A", foreground: "#EDEBFF", muted: "#9C98C9")),
                shape: AppearanceShape(buttonRadius: 4, buttonStyle: .outline),
                mode: .dark,
                capture: AppearanceCapture(challenge: "#FF4FA3")))
            FlowCopyResolver.setDisplayName("Night Pay")
        default:
            FlowAppearanceResolver.reset()
            FlowCopyResolver.reset()
        }
    }

    /// A drawn "Acme Bank" wordmark as a PNG data URL (the "<test logo>").
    static func logoDataURL() -> String {
        let size = CGSize(width: 168, height: 56)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let green = UIColor(red: 0x1F / 255, green: 0x7A / 255, blue: 0x4D / 255, alpha: 1)
            green.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 6, width: 44, height: 44), cornerRadius: 10).fill()
            let mark: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26, weight: .heavy), .foregroundColor: UIColor.white]
            NSAttributedString(string: "A", attributes: mark).draw(at: CGPoint(x: 13, y: 12))
            let word: [NSAttributedString.Key: Any] = [.font: UIFont(name: "Georgia-Bold", size: 22) ?? UIFont.boldSystemFont(ofSize: 22),
                                                       .foregroundColor: UIColor(red: 0x13 / 255, green: 0x26 / 255, blue: 0x1C / 255, alpha: 1)]
            NSAttributedString(string: "Acme Bank", attributes: word).draw(at: CGPoint(x: 54, y: 14))
            _ = ctx
        }
        return "data:image/png;base64," + (image.pngData()?.base64EncodedString() ?? "")
    }
}
#endif
