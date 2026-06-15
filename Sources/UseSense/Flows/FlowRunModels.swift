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

/// Per-field type the SDK uses to choose the right native input control.
/// Mirrors modules/flows/types.ts in usesense-watchtower — keep both in sync.
public enum FormFieldType: String, Sendable, Equatable {
    case text, email, tel, number, date, select, checkbox, country
}

/// One typed input on a form-capture step. A plain string `key` on the wire
/// becomes a FormField with type=.text and required=true; an object payload
/// carries the full per-field metadata so the SDK can render the right input,
/// run the validators, and surface inline errors.
public struct FormField: Sendable, Equatable {
    public let key: String
    public let type: FormFieldType
    public let label: String?
    public let hint: String?
    public let placeholder: String?
    public let required: Bool
    public let initial: AnyEquatableSendable?
    public let validators: Validators?
    public let options: [Option]?
    public let allowedCountries: [String]?

    public struct Validators: Sendable, Equatable {
        public let pattern: String?
        public let minLength: Int?
        public let maxLength: Int?
        public let minNumber: Double?
        public let maxNumber: Double?
        public let minString: String?
        public let maxString: String?
        public let errorMessage: String?
    }

    public struct Option: Sendable, Equatable {
        public let value: String
        public let label: String
    }

    static func decode(_ any: Any) -> FormField {
        if let s = any as? String {
            return FormField(key: s, type: .text, label: nil, hint: nil, placeholder: nil,
                             required: true, initial: nil, validators: nil, options: nil, allowedCountries: nil)
        }
        let raw = any as? [String: Any] ?? [:]
        let typeRaw = (raw["type"] as? String) ?? "text"
        let type = FormFieldType(rawValue: typeRaw) ?? .text
        let validators: Validators? = (raw["validators"] as? [String: Any]).map { v in
            let minNum = (v["min"] as? Double) ?? (v["min"] as? Int).map(Double.init)
            let maxNum = (v["max"] as? Double) ?? (v["max"] as? Int).map(Double.init)
            return Validators(
                pattern: v["pattern"] as? String,
                minLength: v["min_length"] as? Int,
                maxLength: v["max_length"] as? Int,
                minNumber: minNum,
                maxNumber: maxNum,
                minString: v["min"] as? String,
                maxString: v["max"] as? String,
                errorMessage: v["error_message"] as? String
            )
        }
        let options = (raw["options"] as? [[String: Any]])?.compactMap { o -> Option? in
            guard let v = o["value"] as? String, let l = o["label"] as? String else { return nil }
            return Option(value: v, label: l)
        }
        return FormField(
            key: (raw["key"] as? String) ?? "",
            type: type,
            label: raw["label"] as? String,
            hint: raw["hint"] as? String,
            placeholder: raw["placeholder"] as? String,
            required: (raw["required"] as? Bool) ?? true,
            initial: raw["initial"].map { AnyEquatableSendable(value: $0) },
            validators: validators,
            options: options,
            allowedCountries: raw["allowed_countries"] as? [String]
        )
    }
}

/// A boxed primitive (String / Bool / Double) carrying just enough Equatable
/// to satisfy FormField's value semantics without exposing JSON internals.
public struct AnyEquatableSendable: @unchecked Sendable, Equatable {
    public let value: Any
    public init(value: Any) { self.value = value }
    public static func == (lhs: AnyEquatableSendable, rhs: AnyEquatableSendable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l as String, r as String): return l == r
        case let (l as Bool, r as Bool): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Double, r as Double): return l == r
        default: return false
        }
    }
}

public enum InfoBulletIcon: String, Sendable, Equatable {
    case check, shield, camera, warning, info
}

public struct InfoBullet: Sendable, Equatable {
    public let icon: InfoBulletIcon?
    public let text: String
}

public struct InfoCta: Sendable, Equatable {
    public let label: String
    /// When set, the SDK opens this URL in SFSafariViewController and advances
    /// the run after the subject returns.
    public let openURL: URL?
}

public struct InfoSecondaryCta: Sendable, Equatable {
    public let label: String
    /// `advance` continues the run; `cancel` calls cancel() on the run.
    public let action: Action
    public enum Action: String, Sendable, Equatable { case cancel, advance }
}

/// Server-driven info screen. Subsumes `redirect_to_consent` (the server still
/// emits the legacy kind verbatim for downgrade-safe shapes — see
/// action-contract.mdx). Unknown bullet icons render as the default info
/// glyph; never block on them.
public struct InfoAction: Sendable, Equatable {
    public let title: String
    public let body: String?
    public let imageURL: URL?
    public let bullets: [InfoBullet]
    public let primary: InfoCta
    public let secondary: InfoSecondaryCta?
}

/// The action the server parked at. The runner reads it and renders the
/// matching native surface; unknown kinds surface as FlowError.unsupportedAction.
/// See guides/flows/action-contract.mdx.
public enum PendingAction: Sendable, Equatable {
    case captureFace(toolId: String?)
    case captureDocument(category: String, documentTypes: [String], issuingCountries: [String], camera: String?, captureMethods: [String])
    case captureForm(fields: [FormField])
    case info(InfoAction)
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
                let camera = raw["camera"] as? String
                let methodsRaw = (raw["captureMethods"] as? [String]) ?? []
                let methods = methodsRaw.isEmpty ? ["camera", "upload"] : methodsRaw
                return .captureDocument(category: category, documentTypes: types, issuingCountries: countries, camera: camera, captureMethods: methods)
            case "form":
                let rawFields = raw["fields"] as? [Any] ?? []
                return .captureForm(fields: rawFields.map(FormField.decode))
            default:
                throw FlowError(code: .unsupportedAction, message: "Unknown capture variant: \(capture)")
            }
        case "info":
            return .info(try InfoAction.decode(raw))
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

extension InfoAction {
    static func decode(_ raw: [String: Any]) throws -> InfoAction {
        guard let title = raw["title"] as? String else {
            throw FlowError(code: .unsupportedAction, message: "info.title missing")
        }
        guard let primaryRaw = raw["primary_cta"] as? [String: Any],
              let primaryLabel = primaryRaw["label"] as? String else {
            throw FlowError(code: .unsupportedAction, message: "info.primary_cta missing")
        }
        let primary = InfoCta(
            label: primaryLabel,
            openURL: (primaryRaw["open_url"] as? String).flatMap { URL(string: $0) }
        )
        let secondary: InfoSecondaryCta? = (raw["secondary_cta"] as? [String: Any]).flatMap { s in
            guard let label = s["label"] as? String,
                  let actionRaw = s["action"] as? String,
                  let action = InfoSecondaryCta.Action(rawValue: actionRaw) else { return nil }
            return InfoSecondaryCta(label: label, action: action)
        }
        let bullets: [InfoBullet] = (raw["bullets"] as? [[String: Any]] ?? []).compactMap { b in
            guard let text = b["text"] as? String else { return nil }
            let icon = (b["icon"] as? String).flatMap { InfoBulletIcon(rawValue: $0) }
            return InfoBullet(icon: icon, text: text)
        }
        return InfoAction(
            title: title,
            body: raw["body"] as? String,
            imageURL: (raw["image_url"] as? String).flatMap { URL(string: $0) },
            bullets: bullets,
            primary: primary,
            secondary: secondary
        )
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
