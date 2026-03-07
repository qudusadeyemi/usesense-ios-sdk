import Foundation

struct CreateSessionResponse: Decodable {
    let sessionId: String
    let sessionToken: String
    let expiresAt: String
    let nonce: String
    let policy: SessionPolicy
    let upload: UploadConfig

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
        case nonce, policy, upload
    }
}

struct SessionPolicy: Decodable {
    let requiresAudio: Bool?
    let requiresStepup: Bool?
    let challengeType: String?
    let challenge: ChallengeSpec?
    let audioChallenge: AudioChallengeSpec?
    let policySource: String?

    enum CodingKeys: String, CodingKey {
        case requiresAudio = "requires_audio"
        case requiresStepup = "requires_stepup"
        case challengeType = "challenge_type"
        case challenge
        case audioChallenge = "audio_challenge"
        case policySource = "policy_source"
    }
}

struct AudioChallengeSpec: Decodable {
    let type: String
    let seed: String?
    let phrase: String?
    let phraseLanguage: String?
    let totalDurationMs: Int

    enum CodingKeys: String, CodingKey {
        case type, seed, phrase
        case phraseLanguage = "phrase_language"
        case totalDurationMs = "total_duration_ms"
    }
}

struct UploadConfig: Decodable {
    let maxFrames: Int
    let targetFps: Int
    let captureDurationMs: Int

    enum CodingKeys: String, CodingKey {
        case maxFrames = "max_frames"
        case targetFps = "target_fps"
        case captureDurationMs = "capture_duration_ms"
    }
}
