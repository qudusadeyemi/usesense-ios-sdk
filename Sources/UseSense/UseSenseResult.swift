import Foundation

public enum Decision: String, Codable, Sendable {
    case approve = "APPROVE"
    case reject = "REJECT"
    case manualReview = "MANUAL_REVIEW"
    case error = "ERROR"
}

public enum SessionType: String, Codable, Sendable {
    case enrollment
    case authentication
}

public struct PillarVerdict: Codable, Sendable {
    public let score: Int
    public let verdict: String
}

public struct PillarVerdicts: Codable, Sendable {
    public let deepsense: PillarVerdict
    public let livesense: PillarVerdict
    public let dedupe: PillarVerdict
}

public struct UseSenseResult: Sendable {
    public let sessionId: String
    public let sessionType: SessionType
    public let identityId: String?
    public let decision: Decision
    public let channelTrustScore: Int
    public let livenessScore: Int
    public let dedupeRiskScore: Int
    public let pillarVerdicts: PillarVerdicts
    public let reasons: [String]
    public let timestamp: Date
    public let signature: String
    public let rawResponse: VerdictResponse
}
