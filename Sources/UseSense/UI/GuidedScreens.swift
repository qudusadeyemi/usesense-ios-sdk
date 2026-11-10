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

    enum Tone: Equatable { case brand, warning, success, failure }

    struct Content: Equatable {
        var icon: String
        var tone: Tone
        var title: String
        var body: String
        var tips: [String] = []
        var primary: String
        var secondary: String?
    }

    func content(appName: String = GuidedScreen.appName) -> Content {
        let app = appName
        let App = appName.prefix(1).uppercased() + appName.dropFirst()
        switch self {
        case .primerTwoSteps(let digits):
            return Content(icon: "faceid", tone: .brand, title: "Two quick steps",
                           body: digits
                               ? "A selfie scan, then say a few numbers out loud. About 10 seconds."
                               : "A selfie scan, then a short movement. About 10 seconds.",
                           tips: ["Good light on your face", "Take off sunglasses, hats and masks", "Only you in the picture"],
                           primary: "Start")
        case .approved:
            return Content(icon: "checkmark", tone: .success, title: "You're verified",
                           body: "Thanks. You can carry on in \(app).", primary: "Done")
        case .review:
            return Content(icon: "clock", tone: .warning, title: "Thanks, we're checking",
                           body: "This can take a few minutes. \(App) will let you know.", primary: "Done")
        case .rejected(let canRetry, let onceMore):
            if canRetry {
                return Content(icon: "xmark", tone: .failure, title: "We couldn't verify you",
                               body: "This sometimes happens with poor light or movement. "
                                   + (onceMore ? "You can try once more." : "You can try again."),
                               tips: ["Face a window or a lamp", "Hold your phone at eye level"],
                               primary: "Try again", secondary: "Not now")
            }
            return Content(icon: "xmark", tone: .failure, title: "We couldn't verify you",
                           body: "Please contact \(app) for help.", primary: "Done")
        case .cameraDenied:
            return Content(icon: "camera", tone: .warning, title: "Camera access needed",
                           body: "We use the camera only for this check. Turn on camera access for \(app) in Settings, then come back.",
                           primary: "Open Settings", secondary: "Try again")
        case .cameraStopped:
            return Content(icon: "camera", tone: .warning, title: "The camera stopped",
                           body: "Another app may be using it. Close other apps that use the camera, then try again.",
                           primary: "Try again")
        case .offline:
            return Content(icon: "wifi.slash", tone: .warning, title: "You're offline",
                           body: "Check your internet connection, then try again.", primary: "Try again")
        case .expired:
            return Content(icon: "hourglass", tone: .warning, title: "This check timed out",
                           body: "For your security, each check is only open for 15 minutes.", primary: "Start again")
        case .error:
            return Content(icon: "exclamationmark.triangle", tone: .warning, title: "Something went wrong",
                           body: "It's not you. Please try again in a moment.", primary: "Try again")
        case .micNeeded:
            return Content(icon: "mic", tone: .warning, title: "Microphone needed",
                           body: "This check needs your microphone. Turn it on for \(app) in Settings, or do a head movement instead.",
                           primary: "Open Settings", secondary: "Do a head movement instead")
        case .uploadFailed:
            return Content(icon: "arrow.up", tone: .warning, title: "Couldn't send your scan",
                           body: "Check your connection. Your scan is kept, so you won't need to do it again.",
                           primary: "Try again")
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

    /// The host app's name for "[App]" in the copy.
    static var appName: String {
        let info = Bundle.main.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return "the app"
    }
}
