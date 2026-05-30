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
        case unknown
    }

    public let code: Code
    public let message: String
    /// Server-side error code passed through verbatim when present.
    public let serverCode: String?

    public init(code: Code, message: String, serverCode: String? = nil) {
        self.code = code
        self.message = message
        self.serverCode = serverCode
    }

    public var description: String { "FlowError(\(code.rawValue)): \(message)" }
}
