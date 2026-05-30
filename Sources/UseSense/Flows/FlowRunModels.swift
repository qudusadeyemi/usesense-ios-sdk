import Foundation

/// Server-driven Flow Run state. Host apps see only the terminal ones via
/// `FlowRunResult`; intermediate states (pending / in_progress / etc.) drive
/// the runner internally.
public enum FlowRunState: String, Sendable, Codable {
    case pending
    case inProgress = "in_progress"
    case stalled
    case awaitingReview = "awaiting_review"
    case completed
    case errored
    case abandoned
    case cancelled
}

public enum FlowOutcome: String, Sendable, Codable {
    case approve = "APPROVE"
    case reject = "REJECT"
    case manualReview = "MANUAL_REVIEW"
}

/// The action the server parked at. The runner reads it and renders the
/// matching native surface; unknown kinds surface as FlowError.unsupportedAction.
/// See guides/flows/action-contract.mdx.
public enum PendingAction: Sendable, Equatable {
    case captureFace(toolId: String?)
    case captureDocument(category: String, documentTypes: [String], issuingCountries: [String])
    case captureForm(fields: [String])
    case redirectToConsent(url: URL)

    /// Decodes the wire format the server emits; unknown variants throw the
    /// SDK-side `FlowError.unsupportedAction` so a version-skewed runner
    /// fails loud rather than guessing.
    static func decode(_ raw: [String: Any]) throws -> PendingAction {
        guard let kind = raw["kind"] as? String else {
            throw FlowError(code: .unsupportedAction, message: "pendingAction.kind missing")
        }
        switch kind {
        case "capture":
            guard let capture = raw["capture"] as? String else {
                throw FlowError(code: .unsupportedAction, message: "capture variant missing")
            }
            switch capture {
            case "face":
                return .captureFace(toolId: raw["toolId"] as? String)
            case "document":
                let category = (raw["documentCategory"] as? String) ?? "identity"
                let types = (raw["documentTypes"] as? [String]) ?? []
                let countries = (raw["issuingCountries"] as? [String]) ?? []
                return .captureDocument(category: category, documentTypes: types, issuingCountries: countries)
            case "form":
                let fields = (raw["fields"] as? [String]) ?? []
                return .captureForm(fields: fields)
            default:
                throw FlowError(code: .unsupportedAction, message: "Unknown capture variant: \(capture)")
            }
        case "redirect_to_consent":
            guard let urlStr = raw["consentUrl"] as? String, let url = URL(string: urlStr) else {
                throw FlowError(code: .unsupportedAction, message: "consentUrl missing or invalid")
            }
            return .redirectToConsent(url: url)
        default:
            throw FlowError(code: .unsupportedAction, message: "Unknown pendingAction.kind: \(kind)")
        }
    }
}

/// Server-shaped view returned by GET / POST advance. Decoded into Swift via
/// JSONSerialization because the wire shape is genuinely heterogeneous
/// (stepRuns vary per tool), and a strict Codable model would brittle on
/// every catalogue addition.
public struct FlowRunView {
    public let id: String
    public let state: FlowRunState
    public let outcome: FlowOutcome?
    public let cursorStepId: String?
    public let environment: String
    public let pendingAction: PendingAction?
    public let branding: Branding?

    public struct Branding {
        public let displayName: String
        public let logoURL: URL?
        public let primaryColor: String
        public let redirectURL: URL?
    }

    static func decode(_ json: Any) throws -> FlowRunView {
        guard let root = json as? [String: Any],
              let run = root["flowRun"] as? [String: Any],
              let id = run["id"] as? String,
              let stateRaw = run["state"] as? String,
              let state = FlowRunState(rawValue: stateRaw),
              let environment = run["environment"] as? String
        else {
            throw FlowError(code: .unknown, message: "Malformed flow run view")
        }
        let outcome = (run["outcome"] as? String).flatMap { FlowOutcome(rawValue: $0) }
        let cursor = run["cursorStepId"] as? String
        let action: PendingAction? = try (run["pendingAction"] as? [String: Any]).map { try PendingAction.decode($0) }
        let branding = (root["branding"] as? [String: Any]).map { b -> FlowRunView.Branding in
            Branding(
                displayName: (b["display_name"] as? String) ?? "UseSense",
                logoURL: (b["logo_url"] as? String).flatMap { URL(string: $0) },
                primaryColor: (b["primary_color"] as? String) ?? "#4F7CFF",
                redirectURL: (b["redirect_url"] as? String).flatMap { URL(string: $0) }
            )
        }
        return FlowRunView(id: id, state: state, outcome: outcome, cursorStepId: cursor, environment: environment, pendingAction: action, branding: branding)
    }
}

/// Terminal result delivered to the host app's completion handler.
public struct FlowRunResult: Sendable, Equatable {
    public let flowRunId: String
    public let state: FlowRunState
    public let outcome: FlowOutcome?
}

/// Options for `UseSenseFlows.run(...)`. flowRunId + sdkToken come from the
/// customer backend's `POST /v1/flow-runs` response; apiBaseUrl is the
/// production default unless the host wires a staging gateway.
public struct RunFlowOptions: Sendable {
    public let flowRunId: String
    public let sdkToken: String
    public let apiBaseURL: URL
    public init(flowRunId: String, sdkToken: String, apiBaseURL: URL = URL(string: "https://api.usesense.ai")!) {
        self.flowRunId = flowRunId
        self.sdkToken = sdkToken
        self.apiBaseURL = apiBaseURL
    }
}
