import Foundation

public struct CreateSessionResponse: Codable, Sendable {
    public let sessionId: String
    public let sessionToken: String
    public let expiresAt: String
    public let nonce: String
    public let policy: SessionPolicy
    public let upload: UploadConfig
    public let geometricCoherence: GeometricCoherenceConfig?
    /// The org's dashboard branding (optional; absent on older servers). The
    /// layer below the integrator's code-set branding in session mode.
    public let branding: ServerBranding?

    public init(
        sessionId: String,
        sessionToken: String,
        expiresAt: String,
        nonce: String,
        policy: SessionPolicy,
        upload: UploadConfig,
        geometricCoherence: GeometricCoherenceConfig? = nil,
        branding: ServerBranding? = nil
    ) {
        self.sessionId = sessionId
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.policy = policy
        self.upload = upload
        self.geometricCoherence = geometricCoherence
        self.branding = branding
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
        case nonce, policy, upload
        case geometricCoherence = "geometric_coherence"
        case branding
    }

    /// The identity fields (session_id, session_token, nonce, expires_at) and
    /// the policy / upload blocks stay strict: without them there is no session
    /// to run. `geometric_coherence` is an optional collection hint, so a block
    /// of the wrong shape is dropped rather than failing the whole decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        sessionToken = try c.decode(String.self, forKey: .sessionToken)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        nonce = try c.decode(String.self, forKey: .nonce)
        policy = try c.decode(SessionPolicy.self, forKey: .policy)
        upload = try c.decode(UploadConfig.self, forKey: .upload)
        geometricCoherence = (try? c.decodeIfPresent(GeometricCoherenceConfig.self, forKey: .geometricCoherence)) ?? nil
        branding = (try? c.decodeIfPresent(ServerBranding.self, forKey: .branding)) ?? nil
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

    /// The challenge blocks (`challenge`, `audio_challenge`) and the three
    /// top-level policy fields stay strict -- silently dropping a challenge
    /// would weaken the capture. The remaining blocks are optional tuning
    /// hints: one the server sends malformed is treated as absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requiresAudio = try c.decode(Bool.self, forKey: .requiresAudio)
        requiresStepup = try c.decode(Bool.self, forKey: .requiresStepup)
        challengeType = try c.decode(String.self, forKey: .challengeType)
        challenge = try c.decodeIfPresent(ChallengeSpecWrapper.self, forKey: .challenge)
        audioChallenge = try c.decodeIfPresent(SpeakPhraseChallenge.self, forKey: .audioChallenge)
        policySource = (try? c.decodeIfPresent(String.self, forKey: .policySource)) ?? nil
        inlineStepUp = (try? c.decodeIfPresent(InlineStepUpConfig.self, forKey: .inlineStepUp)) ?? nil
        geometricCoherencePolicy = (try? c.decodeIfPresent(GCPolicyConfig.self, forKey: .geometricCoherencePolicy)) ?? nil
        screenIllumination = (try? c.decodeIfPresent(ScreenIlluminationConfig.self, forKey: .screenIllumination)) ?? nil
        meshIntegrity = (try? c.decodeIfPresent(MeshIntegrityConfig.self, forKey: .meshIntegrity)) ?? nil
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

    public init(
        dualPathEnabled: Bool = false,
        screenIlluminationEnabled: Bool = false,
        onDevice3dmmRequired: Bool = false,
        meshBindingChallenge: String = ""
    ) {
        self.dualPathEnabled = dualPathEnabled
        self.screenIlluminationEnabled = screenIlluminationEnabled
        self.onDevice3dmmRequired = onDevice3dmmRequired
        self.meshBindingChallenge = meshBindingChallenge
    }

    /// Tolerant: this block is an optional server hint about which extra
    /// signals to collect, so a field the server omits or sends as null (or as
    /// the wrong type) degrades to "off" / "" instead of failing the whole
    /// init-session decode. That strictness used to kill the session outright
    /// ("The data couldn't be read because it is missing.") whenever the
    /// server left out `screen_illumination_enabled` or sent
    /// `mesh_binding_challenge: null`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dualPathEnabled = c.lenientBool(.dualPathEnabled)
        screenIlluminationEnabled = c.lenientBool(.screenIlluminationEnabled)
        onDevice3dmmRequired = c.lenientBool(.onDevice3dmmRequired)
        meshBindingChallenge = c.lenientString(.meshBindingChallenge)
    }
}

extension KeyedDecodingContainer {
    /// Missing, null or mistyped -> false. Accepts 0/1 and "true"/"false".
    func lenientBool(_ key: Key) -> Bool {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return ["true", "1", "yes"].contains(s.lowercased())
        }
        return false
    }

    /// Missing, null or mistyped -> "".
    func lenientString(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? ""
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

    public init(enabled: Bool, suspicionThreshold: Int, preferredChallenge: String) {
        self.enabled = enabled
        self.suspicionThreshold = suspicionThreshold
        self.preferredChallenge = preferredChallenge
    }

    /// Tolerant like GeometricCoherenceConfig: a missing `enabled` reads as
    /// off, a missing threshold as the default 55, a missing/null preferred
    /// challenge as "auto".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.lenientBool(.enabled)
        suspicionThreshold = (try? c.decodeIfPresent(Int.self, forKey: .suspicionThreshold)) ?? 55
        let preferred = c.lenientString(.preferredChallenge)
        preferredChallenge = preferred.isEmpty ? "auto" : preferred
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
