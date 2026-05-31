import Foundation

/// Uniform error taxonomy for the Flows runner, mirroring the web SDK's
/// FlowError so host apps reason about flow failures the same way across
/// platforms. See guides/flows/errors.mdx in the API docs.
public struct FlowError: Error, CustomStringConvertible, Equatable {
    public enum Code: String, Sendable {
        case tokenExpired = "token_expired"
        case tokenInvalid = "token_invalid"
        case networkUnavailable = "network_unavailable"
        case permissionDenied = "permission_denied"
        case providerUnavailable = "provider_unavailable"
        case cancelled
        case unsupportedAction = "unsupported_action"
        /// Server form validation failed; `details` carries per-field messages
        /// keyed by FormField.key. The runner surfaces these inline rather
        /// than terminating the run via the completion handler.
        case invalidInput = "invalid_input"
        case unknown
    }

    public let code: Code
    public let message: String
    /// Server-side error code passed through verbatim when present.
    public let serverCode: String?
    /// Populated when `code == .invalidInput`. Keyed by field_key.
    public let details: [String: String]

    public init(code: Code, message: String, serverCode: String? = nil, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.serverCode = serverCode
        self.details = details
    }

    public var description: String { "FlowError(\(code.rawValue)): \(message)" }
}
