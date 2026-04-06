import Foundation

public struct CreateSessionResponse: Codable, Sendable {
    public let sessionId: String
    public let sessionToken: String
    public let expiresAt: String
    public let nonce: String
    public let policy: SessionPolicy
    public let upload: UploadConfig
    public let geometricCoherence: GeometricCoherenceConfig?

    public init(
        sessionId: String,
        sessionToken: String,
        expiresAt: String,
        nonce: String,
        policy: SessionPolicy,
        upload: UploadConfig,
        geometricCoherence: GeometricCoherenceConfig? = nil
    ) {
        self.sessionId = sessionId
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.policy = policy
        self.upload = upload
        self.geometricCoherence = geometricCoherence
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
        case nonce, policy, upload
        case geometricCoherence = "geometric_coherence"
    }
}

public struct SessionPolicy: Codable, Sendable {
    public let requiresAudio: Bool
    public let requiresStepup: Bool
    public let challengeType: String
    public let challenge: ChallengeSpecWrapper?
    public let audioChallenge: SpeakPhraseChallenge?
    public let policySource: String?
    public let inlineStepUp: InlineStepUpConfig?
    public let geometricCoherencePolicy: GCPolicyConfig?
    public let screenIllumination: ScreenIlluminationConfig?
    public let meshIntegrity: MeshIntegrityConfig?

    enum CodingKeys: String, CodingKey {
        case requiresAudio = "requires_audio"
        case requiresStepup = "requires_stepup"
        case challengeType = "challenge_type"
        case challenge
        case audioChallenge = "audio_challenge"
        case policySource = "policy_source"
        case inlineStepUp = "inline_step_up"
        case geometricCoherencePolicy = "geometricCoherence"
        case screenIllumination
        case meshIntegrity
    }
}

public struct UploadConfig: Codable, Sendable {
    public let maxFrames: Int
    public let targetFps: Int
    public let captureDurationMs: Int

    enum CodingKeys: String, CodingKey {
        case maxFrames = "max_frames"
        case targetFps = "target_fps"
        case captureDurationMs = "capture_duration_ms"
    }
}

// MARK: - Geometric Coherence Config

public struct GeometricCoherenceConfig: Codable, Sendable {
    public let dualPathEnabled: Bool
    public let screenIlluminationEnabled: Bool
    public let onDevice3dmmRequired: Bool
    public let meshBindingChallenge: String

    enum CodingKeys: String, CodingKey {
        case dualPathEnabled = "dual_path_enabled"
        case screenIlluminationEnabled = "screen_illumination_enabled"
        case onDevice3dmmRequired = "on_device_3dmm_required"
        case meshBindingChallenge = "mesh_binding_challenge"
    }
}

// MARK: - Inline Step-Up Config

public struct InlineStepUpConfig: Codable, Sendable {
    public let enabled: Bool
    public let suspicionThreshold: Int
    public let preferredChallenge: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case suspicionThreshold = "suspicion_threshold"
        case preferredChallenge = "preferred_challenge"
    }
}

// MARK: - GC Policy Config

public struct GCPolicyConfig: Codable, Sendable {
    public let hardGateFloor: Int?
    public let passiveConfidenceThreshold: Int?
    public let frameIntegrityAction: String?
    public let attestationFailureAction: String?
}

public struct ScreenIlluminationConfig: Codable, Sendable {
    public let enabled: Bool?
    public let gcScoreThreshold: Int?
    public let livesenseThreshold: Int?
    public let triggerOnHighRisk: Bool?
    public let alwaysOnMobile: Bool?
}

public struct MeshIntegrityConfig: Codable, Sendable {
    public let absenceAction: String?
    public let failureAction: String?
    public let requiredTiers: [String]?
}
