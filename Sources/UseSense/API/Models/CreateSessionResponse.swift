import Foundation

public struct CreateSessionResponse: Codable, Sendable {
    public let sessionId: String
    public let sessionToken: String
    public let expiresAt: String
    public let nonce: String
    public let policy: SessionPolicy
    public let upload: UploadConfig

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
        case nonce, policy, upload
    }
}

public struct SessionPolicy: Codable, Sendable {
    public let requiresAudio: Bool
    public let requiresStepup: Bool
    public let challengeType: String
    public let challenge: ChallengeSpecWrapper?
    public let audioChallenge: SpeakPhraseChallenge?

    enum CodingKeys: String, CodingKey {
        case requiresAudio = "requires_audio"
        case requiresStepup = "requires_stepup"
        case challengeType = "challenge_type"
        case challenge
        case audioChallenge = "audio_challenge"
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
