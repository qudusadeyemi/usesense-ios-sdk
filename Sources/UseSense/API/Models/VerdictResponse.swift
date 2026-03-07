import Foundation

public struct VerdictResponse: Decodable, Sendable {
    public let sessionId: String
    public let organizationId: String?
    public let sessionType: String
    public let identityId: String?
    public let decision: String
    public let matrixDecision: String?
    public let channelTrustScore: Int
    public let livenessScore: Int
    public let dedupeRiskScore: Int
    public let pillarVerdicts: PillarVerdicts
    public let verdictMetadata: VerdictMetadata?
    public let reasons: [String]
    public let timestamp: String
    public let signature: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case organizationId = "organization_id"
        case sessionType = "session_type"
        case identityId = "identity_id"
        case decision
        case matrixDecision = "matrix_decision"
        case channelTrustScore = "channel_trust_score"
        case livenessScore = "liveness_score"
        case dedupeRiskScore = "dedupe_risk_score"
        case pillarVerdicts = "pillar_verdicts"
        case verdictMetadata = "verdict_metadata"
        case reasons, timestamp, signature
    }
}

public struct VerdictMetadata: Codable, Sendable {
    public let source: String
    public let logic: String
}
