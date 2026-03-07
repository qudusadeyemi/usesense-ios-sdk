import Foundation

public enum ChallengeType: String, Codable, Sendable {
    case followDot = "follow_dot"
    case headTurn = "head_turn"
    case speakPhrase = "speak_phrase"
}

public struct Waypoint: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let durationMs: Int
    public let index: Int

    enum CodingKeys: String, CodingKey {
        case x, y, index
        case durationMs = "duration_ms"
    }
}

public enum HeadDirection: String, Codable, Sendable {
    case left, right, up, down, center
}

public struct HeadTurnStep: Codable, Sendable {
    public let direction: HeadDirection
    public let durationMs: Int
    public let index: Int

    enum CodingKeys: String, CodingKey {
        case direction, index
        case durationMs = "duration_ms"
    }
}

struct ChallengeSpec: Decodable {
    let type: ChallengeType
    let seed: String
    let generatedAt: String?
    let waypoints: [Waypoint]?
    let dotSizePx: Int?
    let sequence: [HeadTurnStep]?
    let phrase: String?
    let phraseLanguage: String?
    let totalDurationMs: Int
    let framesPerStep: Int?
    let captureFpsHint: Int?

    enum CodingKeys: String, CodingKey {
        case type, seed, waypoints, phrase, sequence
        case generatedAt = "generated_at"
        case dotSizePx = "dot_size_px"
        case phraseLanguage = "phrase_language"
        case totalDurationMs = "total_duration_ms"
        case framesPerStep = "frames_per_step"
        case captureFpsHint = "capture_fps_hint"
    }
}
