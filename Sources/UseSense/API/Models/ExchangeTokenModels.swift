import Foundation

/// Response from POST /v1/sessions/create-token (called by integrator backend)
public struct CreateTokenResponse: Codable, Sendable {
    public let clientToken: String
    public let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case clientToken = "client_token"
        case expiresAt = "expires_at"
    }
}
