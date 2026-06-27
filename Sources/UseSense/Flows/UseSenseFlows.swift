#if canImport(UIKit)
import UIKit

/// Public entry point for the Flows runner. Coexists with the existing
/// Sessions API (UseSense.createSession / startVerification / ...); this is
/// a parallel surface, not a replacement. See guides/flows/sessions-vs-flows
/// in the API docs for when to use which.
///
/// Usage:
///
///   UseSenseFlows.run(
///     flowRunId: id,
///     sdkToken: token,
///     from: presentingViewController
///   ) { result in
///     switch result {
///       case .success(let r): print(r.outcome ?? .manualReview)
///       case .failure(let e): print(e)
///     }
///   }
public enum UseSenseFlows {
    /// Run an operator-authored Flow inside the host app. Presents a
    /// full-screen modal that drives the parked steps and resolves with
    /// the terminal outcome. Mirrors `flows.run(...)` in the web SDK and
    /// `UseSenseFlows.run(...)` on Android.
    public static func run(
        flowRunId: String,
        sdkToken: String,
        apiBaseURL: URL = URL(string: "https://api.usesense.ai")!,
        appearance: FlowAppearance? = nil,
        from presentingViewController: UIViewController,
        completion: @escaping (Result<FlowRunResult, FlowError>) -> Void
    ) {
        let options = RunFlowOptions(flowRunId: flowRunId, sdkToken: sdkToken, apiBaseURL: apiBaseURL, appearance: appearance)
        let runner = FlowsRunnerViewController(options: options, completion: completion)
        runner.modalPresentationStyle = .fullScreen
        presentingViewController.present(runner, animated: true)
    }

    /// Convenience overload that takes a `BrandingConfig` (legacy fields +
    /// `appearance`) as the SDK-init customization layer.
    public static func run(
        flowRunId: String,
        sdkToken: String,
        apiBaseURL: URL = URL(string: "https://api.usesense.ai")!,
        branding: BrandingConfig?,
        from presentingViewController: UIViewController,
        completion: @escaping (Result<FlowRunResult, FlowError>) -> Void
    ) {
        run(
            flowRunId: flowRunId,
            sdkToken: sdkToken,
            apiBaseURL: apiBaseURL,
            appearance: branding?.resolvedAppearance,
            from: presentingViewController,
            completion: completion
        )
    }
}
#endif
