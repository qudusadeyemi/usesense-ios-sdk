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

    public var isApproved: Bool { decision == Decision.approve.rawValue }
    public var isRejected: Bool { decision == Decision.reject.rawValue }
    public var isPendingReview: Bool { decision == Decision.manualReview.rawValue }

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
    let geometricCoherence: GCDecisionResult?
    let senseiStepUp: SenSeiStepUpResult?
    let inlineStepUp: InlineStepUpResult?
    let challengeValidation: ChallengeValidationResult?
    let dedupeAnalysis: DedupeAnalysisResult?
    let blocklistHit: AnyCodableValue?
    let attestationHardGate: AnyCodableValue?

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
        case geometricCoherence = "geometric_coherence"
        case senseiStepUp = "sensei_step_up"
        case inlineStepUp = "inline_step_up"
        case challengeValidation = "challenge_validation"
        case dedupeAnalysis = "dedupe_analysis"
        case blocklistHit = "blocklist_hit"
        case attestationHardGate = "attestation_hard_gate"
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

// MARK: - v4.1 Decision Sub-Objects

struct GCDecisionResult: Decodable {
    let score: Int?
    let subSignals: GCSubSignals?
    let flags: GCFlags?

    enum CodingKeys: String, CodingKey {
        case score
        case subSignals = "sub_signals"
        case flags
    }
}

struct GCSubSignals: Decodable {
    let depthPlausibility: Double?
    let crossFrameConsistency: Double?
    let dualPathComparison: Double?
    let materialClassification: String?

    enum CodingKeys: String, CodingKey {
        case depthPlausibility = "depth_plausibility"
        case crossFrameConsistency = "cross_frame_consistency"
        case dualPathComparison = "dual_path_comparison"
        case materialClassification = "material_classification"
    }
}

struct GCFlags: Decodable {
    let hardRejection: Bool?
    let hardRejectionReason: String?
    let frameIntegrityFailure: Bool?
    let attestationFailure: Bool?

    enum CodingKeys: String, CodingKey {
        case hardRejection = "hard_rejection"
        case hardRejectionReason = "hard_rejection_reason"
        case frameIntegrityFailure = "frame_integrity_failure"
        case attestationFailure = "attestation_failure"
    }
}

struct SenSeiStepUpResult: Decodable {
    let stepUpTriggered: Bool?
    let passiveConfidence: String?
    let hardReject: Bool?
    let hardRejectReason: String?
    let reasoning: [String]?

    enum CodingKeys: String, CodingKey {
        case stepUpTriggered = "step_up_triggered"
        case passiveConfidence = "passive_confidence"
        case hardReject = "hard_reject"
        case hardRejectReason = "hard_reject_reason"
        case reasoning
    }
}

struct InlineStepUpResult: Decodable {
    let triggered: Bool?
    let suspicionScore: Double?
    let passed: Bool?
    let hardReject: Bool?
    let flashReflection: AnyCodableValue?
    let rmas: AnyCodableValue?

    enum CodingKeys: String, CodingKey {
        case triggered
        case suspicionScore = "suspicion_score"
        case passed
        case hardReject = "hard_reject"
        case flashReflection = "flash_reflection"
        case rmas
    }
}

struct ChallengeValidationResult: Decodable {
    let challengeType: String?
    let verdict: String?
    let overallScore: Double?
    let stepsCompliant: Int?
    let stepsTotal: Int?
}

struct DedupeAnalysisResult: Decodable {
    let duplicateSearchPerformed: Bool?
    let highestDuplicateSimilarity: Double?
    let crossIdentityRisk: Double?
    let duplicateMatches: [AnyCodableValue]?
    let referenceMatch: ReferenceMatchResult?

    enum CodingKeys: String, CodingKey {
        case duplicateSearchPerformed = "duplicate_search_performed"
        case highestDuplicateSimilarity = "highest_duplicate_similarity"
        case crossIdentityRisk = "cross_identity_risk"
        case duplicateMatches = "duplicate_matches"
        case referenceMatch = "reference_match"
    }
}

struct ReferenceMatchResult: Decodable {
    let similarity: Double?
    let threshold: Int?
    let matched: Bool?
    let referenceData: String?

    enum CodingKeys: String, CodingKey {
        case similarity, threshold, matched
        case referenceData = "reference_data"
    }
}
