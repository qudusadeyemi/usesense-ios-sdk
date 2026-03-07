import Foundation

public enum ChallengeType: String, Codable, Sendable {
    case followDot = "follow_dot"
    case headTurn = "head_turn"
    case speakPhrase = "speak_phrase"
}

public enum HeadDirection: String, Codable, Sendable {
    case left, right, up, down, center
}

public struct FollowDotWaypoint: Codable, Sendable {
    public let x: Float
    public let y: Float
    public let durationMs: Int
    public let index: Int

    enum CodingKeys: String, CodingKey {
        case x, y, index
        case durationMs = "duration_ms"
    }
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

public struct HeadTurnChallenge: Codable, Sendable {
    public let type: String
    public let seed: String
    public let sequence: [HeadTurnStep]
    public let totalDurationMs: Int
    public let framesPerStep: Int?
    public let captureFpsHint: Int?

    enum CodingKeys: String, CodingKey {
        case type, seed, sequence
        case totalDurationMs = "total_duration_ms"
        case framesPerStep = "frames_per_step"
        case captureFpsHint = "capture_fps_hint"
    }
}

public struct FollowDotChallenge: Codable, Sendable {
    public let type: String
    public let seed: String
    public let waypoints: [FollowDotWaypoint]
    public let dotSizePx: Int
    public let totalDurationMs: Int
    public let framesPerStep: Int?
    public let captureFpsHint: Int?

    enum CodingKeys: String, CodingKey {
        case type, seed, waypoints
        case dotSizePx = "dot_size_px"
        case totalDurationMs = "total_duration_ms"
        case framesPerStep = "frames_per_step"
        case captureFpsHint = "capture_fps_hint"
    }
}

public struct SpeakPhraseChallenge: Codable, Sendable {
    public let type: String
    public let seed: String
    public let phrase: String
    public let phraseLanguage: String?
    public let totalDurationMs: Int

    enum CodingKeys: String, CodingKey {
        case type, seed, phrase
        case phraseLanguage = "phrase_language"
        case totalDurationMs = "total_duration_ms"
    }
}

/// Discriminator-based decoded challenge wrapper
public enum ChallengeSpecWrapper: Sendable {
    case headTurn(HeadTurnChallenge)
    case followDot(FollowDotChallenge)
    case speakPhrase(SpeakPhraseChallenge)

    var challengeType: ChallengeType {
        switch self {
        case .headTurn: return .headTurn
        case .followDot: return .followDot
        case .speakPhrase: return .speakPhrase
        }
    }

    var seed: String {
        switch self {
        case .headTurn(let c): return c.seed
        case .followDot(let c): return c.seed
        case .speakPhrase(let c): return c.seed
        }
    }

    var totalDurationMs: Int {
        switch self {
        case .headTurn(let c): return c.totalDurationMs
        case .followDot(let c): return c.totalDurationMs
        case .speakPhrase(let c): return c.totalDurationMs
        }
    }

    var framesPerStep: Int? {
        switch self {
        case .headTurn(let c): return c.framesPerStep
        case .followDot(let c): return c.framesPerStep
        case .speakPhrase: return nil
        }
    }

    var captureFpsHint: Int? {
        switch self {
        case .headTurn(let c): return c.captureFpsHint
        case .followDot(let c): return c.captureFpsHint
        case .speakPhrase: return nil
        }
    }
}

extension ChallengeSpecWrapper: Decodable {
    private enum DiscriminatorKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let singleValue = try decoder.singleValueContainer()

        switch type {
        case "head_turn":
            self = .headTurn(try singleValue.decode(HeadTurnChallenge.self))
        case "follow_dot":
            self = .followDot(try singleValue.decode(FollowDotChallenge.self))
        case "speak_phrase":
            self = .speakPhrase(try singleValue.decode(SpeakPhraseChallenge.self))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown challenge type: \(type)")
        }
    }
}

extension ChallengeSpecWrapper: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .headTurn(let c): try container.encode(c)
        case .followDot(let c): try container.encode(c)
        case .speakPhrase(let c): try container.encode(c)
        }
    }
}
