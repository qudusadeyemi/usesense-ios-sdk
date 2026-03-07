import Foundation

public enum Decision: String, Codable, Sendable {
    case approve = "APPROVE"
    case reject = "REJECT"
    case manualReview = "MANUAL_REVIEW"
}

public enum SessionType: String, Codable, Sendable {
    case enrollment
    case authentication
}

/// The ONLY decision object exposed to the host app.
/// Scores and analysis details are stripped for security.
public struct RedactedDecisionObject: Codable, Sendable {
    public let sessionId: String
    public let sessionType: String?
    public let identityId: String?
    public let decision: String
    public let timestamp: String

    public init(sessionId: String, sessionType: String?, identityId: String?, decision: String, timestamp: String) {
        self.sessionId = sessionId
        self.sessionType = sessionType
        self.identityId = identityId
        self.decision = decision
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionType = "session_type"
        case identityId = "identity_id"
        case decision, timestamp
    }
}

/// Internal full decision from server. NEVER exposed to host app.
struct FinalDecisionObject: Decodable {
    let sessionId: String
    let organizationId: String?
    let sessionType: String?
    let identityId: String?
    let decision: String
    let matrixDecision: String?
    let channelTrustScore: Int?
    let livenessScore: Int?
    let dedupeRiskScore: Int?
    let pillarVerdicts: PillarVerdicts?
    let verdictMetadata: VerdictMetadata?
    let reasons: [String]?
    let timestamp: String
    let signature: String?

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

    func redacted() -> RedactedDecisionObject {
        RedactedDecisionObject(
            sessionId: sessionId, sessionType: sessionType,
            identityId: identityId, decision: decision, timestamp: timestamp
        )
    }
}

struct PillarVerdict: Codable, Sendable { let score: Int; let verdict: String }
struct PillarVerdicts: Codable, Sendable { let deepsense: PillarVerdict; let livesense: PillarVerdict; let dedupe: PillarVerdict }
struct VerdictMetadata: Codable, Sendable { let source: String; let logic: String }
