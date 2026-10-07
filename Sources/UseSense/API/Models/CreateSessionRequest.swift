import Foundation

struct CreateSessionRequest: Encodable {
    let sessionType: String
    let platform: String = "ios"
    let identityId: String?
    let externalUserId: String?
    let metadata: [String: AnyCodableValue]?
    /// What this SDK can do, e.g. run a server step-up round.
    let capabilities: [String] = StepUpCapability.all

    enum CodingKeys: String, CodingKey {
        case sessionType = "session_type"
        case platform
        case identityId = "identity_id"
        case externalUserId = "external_user_id"
        case metadata
        case capabilities
    }
}
