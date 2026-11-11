import Foundation

// MARK: - Guided pages and sheets: what each one says (storyboard flows 5 and 6)
//
// Pure content, so the copy and the outcome mapping are unit tested apart
// from SwiftUI. `[App]` in the storyboard is the host app's display name.

enum GuidedScreen: Equatable {
    /// Before-scan check announced up front.
    case primerTwoSteps(digits: Bool)
    case approved
    case review
    /// `onceMore`: exactly one retry left ("You can try once more.").
    case rejected(canRetry: Bool, onceMore: Bool)
    case cameraDenied
    case cameraStopped
    case offline
    case expired
    case error
    case micNeeded
    /// Sheet over the blurred scan: the upload failed but the scan is kept.
    case uploadFailed
    /// Asks for the camera before the system prompt.
    case cameraRequest

    enum Tone: Equatable { case brand, warning, success, failure }

    struct Content: Equatable {
        var icon: String
        var tone: Tone
        var title: String
        var body: String
        var tips: [String] = []
        var primary: String
        var secondary: String?
        /// `appearance.icons` slot that replaces the icon tile (result pages).
        var iconSlot: String?
    }

    func content(appName: String = GuidedScreen.appName) -> Content {
        let app = appName
        let App = appName.prefix(1).uppercased() + appName.dropFirst()
        typealias T = CaptureText
        let doneLabel = T.text(\.capture?.result?.done, "Done")
        let tryAgain = T.text(\.capture?.result?.tryAgain, "Try again")
        let errTryAgain = T.text(\.capture?.errors?.tryAgain, "Try again")
        let openSettings = T.text(\.capture?.errors?.openSettings, "Open Settings")
        switch self {
        case .primerTwoSteps(let digits):
            return Content(icon: "faceid", tone: .brand,
                           title: T.text(\.capture?.primer?.twoStepsTitle, "Two quick steps"),
                           body: digits
                               ? T.text(\.capture?.primer?.twoStepsDigitsBody,
                                        "A selfie scan, then say a few numbers out loud. About 10 seconds.")
                               : T.text(\.capture?.primer?.twoStepsBody,
                                        "A selfie scan, then a short movement. About 10 seconds."),
                           tips: T.list(\.capture?.primer?.twoStepsTips,
                                        ["Good light on your face", "Take off sunglasses, hats and masks", "Only you in the picture"]),
                           primary: T.text(\.capture?.primer?.start, "Start"))
        case .approved:
            return Content(icon: "checkmark", tone: .success,
                           title: T.text(\.capture?.result?.approvedTitle, "You're verified"),
                           body: T.text(\.capture?.result?.approvedBody, "Thanks. You can carry on in \(app)."),
                           primary: doneLabel, iconSlot: "success")
        case .review:
            return Content(icon: "clock", tone: .warning,
                           title: T.text(\.capture?.result?.reviewTitle, "Thanks, we're checking"),
                           body: T.text(\.capture?.result?.reviewBody, "This can take a few minutes. \(App) will let you know."),
                           primary: doneLabel, iconSlot: "review")
        case .rejected(let canRetry, let onceMore):
            if canRetry {
                return Content(icon: "xmark", tone: .failure,
                               title: T.text(\.capture?.result?.retryTitle, "We couldn't verify you"),
                               body: T.text(\.capture?.result?.retryBody,
                                            "This sometimes happens with poor light or movement. "
                                                + (onceMore ? "You can try once more." : "You can try again.")),
                               tips: T.list(\.capture?.result?.retryTips, ["Face a window or a lamp", "Hold your phone at eye level"]),
                               primary: tryAgain, secondary: T.text(\.capture?.result?.notNow, "Not now"),
                               iconSlot: "notVerified")
            }
            return Content(icon: "xmark", tone: .failure,
                           title: T.text(\.capture?.result?.rejectedTitle, "We couldn't verify you"),
                           body: T.text(\.capture?.result?.rejectedBody, "Please contact \(app) for help."),
                           primary: doneLabel, iconSlot: "notVerified")
        case .cameraDenied:
            return Content(icon: "camera", tone: .warning,
                           title: T.text(\.capture?.errors?.cameraDeniedTitle, "Camera access needed"),
                           body: T.text(\.capture?.errors?.cameraDeniedBody,
                                        "We use the camera only for this check. Turn on camera access for \(app) in Settings, then come back."),
                           primary: openSettings, secondary: errTryAgain)
        case .cameraStopped:
            return Content(icon: "camera", tone: .warning,
                           title: T.text(\.capture?.errors?.cameraStoppedTitle, "The camera stopped"),
                           body: T.text(\.capture?.errors?.cameraStoppedBody,
                                        "Another app may be using it. Close other apps that use the camera, then try again."),
                           primary: errTryAgain)
        case .offline:
            return Content(icon: "wifi.slash", tone: .warning,
                           title: T.text(\.capture?.errors?.offlineTitle, "You're offline"),
                           body: T.text(\.capture?.errors?.offlineBody, "Check your internet connection, then try again."),
                           primary: errTryAgain)
        case .expired:
            return Content(icon: "hourglass", tone: .warning,
                           title: T.text(\.capture?.errors?.expiredTitle, "This check timed out"),
                           body: T.text(\.capture?.errors?.expiredBody, "For your security, each check is only open for 15 minutes."),
                           primary: T.text(\.capture?.errors?.startAgain, "Start again"))
        case .error:
            return Content(icon: "exclamationmark.triangle", tone: .warning,
                           title: T.text(\.capture?.errors?.errorTitle, "Something went wrong"),
                           body: T.text(\.capture?.errors?.errorBody, "It's not you. Please try again in a moment."),
                           primary: errTryAgain)
        case .micNeeded:
            return Content(icon: "mic", tone: .warning,
                           title: T.text(\.capture?.errors?.micTitle, "Microphone needed"),
                           body: T.text(\.capture?.errors?.micBody,
                                        "This check needs your microphone. Turn it on for \(app) in Settings, or do a head movement instead."),
                           primary: openSettings,
                           secondary: T.text(\.capture?.errors?.useHeadMovement, "Do a head movement instead"))
        case .uploadFailed:
            return Content(icon: "arrow.up", tone: .warning,
                           title: T.text(\.capture?.upload?.failedTitle, "Couldn't send your scan"),
                           body: T.text(\.capture?.upload?.failedBody,
                                        "Check your connection. Your scan is kept, so you won't need to do it again."),
                           primary: T.text(\.capture?.upload?.retry, "Try again"))
        case .cameraRequest:
            return Content(icon: "camera", tone: .brand,
                           title: T.text(\.capture?.errors?.cameraTitle, "Camera Access Required"),
                           body: T.text(\.capture?.errors?.cameraBody,
                                        "We need camera access to verify your identity. Your privacy is protected."),
                           primary: T.text(\.capture?.errors?.allowCamera, "Grant Access"))
        }
    }

    // MARK: Mapping

    /// The result page for a decision. `retriesLeft`: tries the integrator
    /// still allows after a reject (`SDKOptions.retriesAfterReject`).
    static func forDecision(_ decision: String, retriesLeft: Int) -> GuidedScreen {
        switch decision.uppercased() {
        case "APPROVE", "APPROVED": return .approved
        case "REJECT", "REJECTED": return .rejected(canRetry: retriesLeft > 0, onceMore: retriesLeft == 1)
        default: return .review
        }
    }

    /// The page (or sheet) for an error. `canResume`: the capture is kept and
    /// can be sent again on the same session.
    static func forError(_ error: UseSenseError, canResume: Bool) -> GuidedScreen {
        switch error.code {
        case .cameraPermissionDenied:
            return .cameraDenied
        case .cameraUnavailable, .captureFailed, .noFramesCaptured:
            return .cameraStopped
        case .networkError, .networkTimeout, .timeout, .uploadFailed, .uploadTimeout:
            return canResume ? .uploadFailed : .offline
        case .sessionExpired, .tokenExpired:
            return .expired
        default:
            return .error
        }
    }

    /// "[App]" in the copy: the brand's display name, else the host app's name.
    static var appName: String { CaptureText.appName }
}

/// Leave dialog and loading strings (BRAND-v1 copy.capture).
enum CaptureScreenCopy {
    static var leaveTitle: String { CaptureText.text(\.capture?.leave?.title, "Leave verification?") }
    static var leaveBody: String {
        CaptureText.text(\.capture?.leave?.body, "You're nearly done. If you leave, you'll need to start again.")
    }
    static var leave: String { CaptureText.text(\.capture?.leave?.leave, "Leave") }
    static var keepGoing: String { CaptureText.text(\.capture?.leave?.keepGoing, "Keep going") }
    static var gettingReady: String { CaptureText.text(\.capture?.loading?.title, "Getting ready") }
}
