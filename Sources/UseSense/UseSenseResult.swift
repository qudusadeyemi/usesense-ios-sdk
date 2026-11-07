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
///
/// Decoded leniently. The host only ever receives the redacted decision
/// fields, so a detail block whose shape drifts (a fractional score where an
/// integer was declared, an object where a string was expected, a field the
/// server stopped sending) becomes nil instead of failing the whole verdict.
/// On Android that failure mode turned real decisions into error 2001 three
/// times (2026-11-06: `pillar_verdicts.dedupe` as an object,
/// `highestDuplicateSimilarity` = 92.8). Only `session_id` and a decision
/// (`decision`, or the v4 envelope's `verdict`) are required.
struct FinalDecisionObject: Decodable, Sendable {
    let sessionId: String
    let organizationId: String?
    let sessionType: String?
    let identityId: String?
    let decision: String
    let matrixDecision: String?
    let channelTrustScore: Double?
    let livenessScore: Double?
    let dedupeRiskScore: Double?
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
        case verdict
        case matrixDecision = "matrix_decision"
        case channelTrustScore = "channel_trust_score"
        case livenessScore = "liveness_score"
        case dedupeRiskScore = "dedupe_risk_score"
        case pillarVerdicts = "pillar_verdicts"
        case verdictMetadata = "verdict_metadata"
        case reasons, timestamp, signature
        case completedAt = "completed_at"
        case geometricCoherence = "geometric_coherence"
        case senseiStepUp = "sensei_step_up"
        case inlineStepUp = "inline_step_up"
        case challengeValidation = "challenge_validation"
        case dedupeAnalysis = "dedupe_analysis"
        case blocklistHit = "blocklist_hit"
        case attestationHardGate = "attestation_hard_gate"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)

        if let d = c.lossyString(.decision), !d.isEmpty {
            decision = d
        } else if let v = c.lossyString(.verdict), !v.isEmpty {
            // v4 opaque envelope: { verdict: "pass" | "fail" | "review", ... }
            decision = Self.decision(fromV4Verdict: v)
        } else {
            throw DecodingError.keyNotFound(CodingKeys.decision, .init(
                codingPath: c.codingPath,
                debugDescription: "Verdict has neither `decision` nor `verdict`."
            ))
        }

        timestamp = c.lossyString(.timestamp)
            ?? c.lossyString(.completedAt)
            ?? ISO8601DateFormatter().string(from: Date())
        organizationId = c.lossyString(.organizationId)
        sessionType = c.lossyString(.sessionType)
        identityId = c.lossyString(.identityId)
        matrixDecision = c.lossyString(.matrixDecision)
        channelTrustScore = c.lossyDouble(.channelTrustScore)
        livenessScore = c.lossyDouble(.livenessScore)
        dedupeRiskScore = c.lossyDouble(.dedupeRiskScore)
        reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? nil
        signature = c.lossyString(.signature)
        pillarVerdicts = c.lenient(PillarVerdicts.self, .pillarVerdicts)
        verdictMetadata = c.lenient(VerdictMetadata.self, .verdictMetadata)
        geometricCoherence = c.lenient(GCDecisionResult.self, .geometricCoherence)
        senseiStepUp = c.lenient(SenSeiStepUpResult.self, .senseiStepUp)
        inlineStepUp = c.lenient(InlineStepUpResult.self, .inlineStepUp)
        challengeValidation = c.lenient(ChallengeValidationResult.self, .challengeValidation)
        dedupeAnalysis = c.lenient(DedupeAnalysisResult.self, .dedupeAnalysis)
        blocklistHit = c.lenient(AnyCodableValue.self, .blocklistHit)
        attestationHardGate = c.lenient(AnyCodableValue.self, .attestationHardGate)
    }

    /// The v4 envelope's verdict, in the decision vocabulary the host gets.
    static func decision(fromV4Verdict verdict: String) -> String {
        switch verdict.lowercased() {
        case "pass", "approve", "approved": return Decision.approve.rawValue
        case "fail", "reject", "rejected": return Decision.reject.rawValue
        case "review", "manual_review": return Decision.manualReview.rawValue
        default: return verdict.uppercased()
        }
    }

    func redacted() -> RedactedDecisionObject {
        RedactedDecisionObject(
            sessionId: sessionId, sessionType: sessionType,
            identityId: identityId, decision: decision, timestamp: timestamp
        )
    }
}

/// One pillar, in the shape the server sends: `{ "score": 82, "verdict": "PASS" }`.
struct PillarVerdict: Decodable, Sendable {
    let score: Double?
    let verdict: String?

    enum CodingKeys: String, CodingKey { case score, verdict }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = c.lossyDouble(.score)
        verdict = c.lossyString(.verdict)
    }
}

/// `{ deepsense, livesense, dedupe }`, each optional so one odd pillar
/// doesn't drop the others.
struct PillarVerdicts: Decodable, Sendable {
    let deepsense: PillarVerdict?
    let livesense: PillarVerdict?
    let dedupe: PillarVerdict?

    enum CodingKeys: String, CodingKey { case deepsense, livesense, dedupe }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deepsense = c.lenient(PillarVerdict.self, .deepsense)
        livesense = c.lenient(PillarVerdict.self, .livesense)
        dedupe = c.lenient(PillarVerdict.self, .dedupe)
    }
}

struct VerdictMetadata: Decodable, Sendable {
    let source: String?
    let logic: String?

    enum CodingKeys: String, CodingKey { case source, logic }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = c.lossyString(.source)
        logic = c.lossyString(.logic)
    }
}

// MARK: - v4.1 Decision Sub-Objects

struct GCDecisionResult: Decodable, Sendable {
    let score: Double?
    let subSignals: GCSubSignals?
    let flags: GCFlags?

    enum CodingKeys: String, CodingKey {
        case score
        case subSignals = "sub_signals"
        case flags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = c.lossyDouble(.score)
        subSignals = c.lenient(GCSubSignals.self, .subSignals)
        flags = c.lenient(GCFlags.self, .flags)
    }
}

struct GCSubSignals: Decodable, Sendable {
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        depthPlausibility = c.lossyDouble(.depthPlausibility)
        crossFrameConsistency = c.lossyDouble(.crossFrameConsistency)
        dualPathComparison = c.lossyDouble(.dualPathComparison)
        materialClassification = c.lossyString(.materialClassification)
    }
}

struct GCFlags: Decodable, Sendable {
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hardRejection = (try? c.decodeIfPresent(Bool.self, forKey: .hardRejection)) ?? nil
        hardRejectionReason = c.lossyString(.hardRejectionReason)
        frameIntegrityFailure = (try? c.decodeIfPresent(Bool.self, forKey: .frameIntegrityFailure)) ?? nil
        attestationFailure = (try? c.decodeIfPresent(Bool.self, forKey: .attestationFailure)) ?? nil
    }
}

struct SenSeiStepUpResult: Decodable, Sendable {
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stepUpTriggered = (try? c.decodeIfPresent(Bool.self, forKey: .stepUpTriggered)) ?? nil
        passiveConfidence = c.lossyString(.passiveConfidence)
        hardReject = (try? c.decodeIfPresent(Bool.self, forKey: .hardReject)) ?? nil
        hardRejectReason = c.lossyString(.hardRejectReason)
        reasoning = (try? c.decodeIfPresent([String].self, forKey: .reasoning)) ?? nil
    }
}

struct InlineStepUpResult: Decodable, Sendable {
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triggered = (try? c.decodeIfPresent(Bool.self, forKey: .triggered)) ?? nil
        suspicionScore = c.lossyDouble(.suspicionScore)
        passed = (try? c.decodeIfPresent(Bool.self, forKey: .passed)) ?? nil
        hardReject = (try? c.decodeIfPresent(Bool.self, forKey: .hardReject)) ?? nil
        flashReflection = c.lenient(AnyCodableValue.self, .flashReflection)
        rmas = c.lenient(AnyCodableValue.self, .rmas)
    }
}

struct ChallengeValidationResult: Decodable, Sendable {
    let challengeType: String?
    let verdict: String?
    let overallScore: Double?
    let stepsCompliant: Double?
    let stepsTotal: Double?

    enum CodingKeys: String, CodingKey { case challengeType, verdict, overallScore, stepsCompliant, stepsTotal }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        challengeType = c.lossyString(.challengeType)
        verdict = c.lossyString(.verdict)
        overallScore = c.lossyDouble(.overallScore)
        stepsCompliant = c.lossyDouble(.stepsCompliant)
        stepsTotal = c.lossyDouble(.stepsTotal)
    }
}

/// The server sends these keys in camelCase (`highestDuplicateSimilarity`).
/// The model used to declare snake_case, so every field silently read nil;
/// camelCase is read first, snake_case kept as a fallback.
struct DedupeAnalysisResult: Decodable, Sendable {
    let duplicateSearchPerformed: Bool?
    let highestDuplicateSimilarity: Double?
    let crossIdentityRisk: Double?
    let duplicateMatches: [AnyCodableValue]?
    let referenceMatch: ReferenceMatchResult?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ camel: String, _ snake: String) -> AnyKey {
            c.contains(AnyKey(camel)) ? AnyKey(camel) : AnyKey(snake)
        }
        duplicateSearchPerformed = (try? c.decodeIfPresent(Bool.self, forKey: key("duplicateSearchPerformed", "duplicate_search_performed"))) ?? nil
        highestDuplicateSimilarity = c.lossyDouble(key("highestDuplicateSimilarity", "highest_duplicate_similarity"))
        crossIdentityRisk = c.lossyDouble(key("crossIdentityRisk", "cross_identity_risk"))
        duplicateMatches = (try? c.decodeIfPresent([AnyCodableValue].self, forKey: key("duplicateMatches", "duplicate_matches"))) ?? nil
        referenceMatch = c.lenient(ReferenceMatchResult.self, key("reference_match", "referenceMatch"))
    }
}

struct ReferenceMatchResult: Decodable, Sendable {
    let similarity: Double?
    let threshold: Double?
    let matched: Bool?
    let referenceData: String?

    enum CodingKeys: String, CodingKey {
        case similarity, threshold, matched
        case referenceData = "reference_data"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        similarity = c.lossyDouble(.similarity)
        threshold = c.lossyDouble(.threshold)
        matched = (try? c.decodeIfPresent(Bool.self, forKey: .matched)) ?? nil
        referenceData = c.lossyString(.referenceData)
    }
}

// MARK: - Lenient decoding helpers

/// A coding key built from any string.
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer {
    /// A nested block that fails to decode becomes nil instead of failing the parent.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// A number sent as an integer, a fraction or a numeric string.
    func lossyDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    /// A string, or a number/bool rendered as one.
    func lossyString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let d = try? decodeIfPresent(Double.self, forKey: key) {
            return d.rounded() == d ? String(Int(d)) : String(d)
        }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return String(b) }
        return nil
    }
}
