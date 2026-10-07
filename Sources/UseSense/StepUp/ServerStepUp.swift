import Foundation

/// Server step-up, round 2.
///
/// When a server Step-up rule matches the uploaded capture, the /signals
/// response asks for one more challenge in the same session. The SDK runs it
/// on the camera, uploads it with `?round=2`, then completes. Server contract:
/// docs/sdk/step-up-protocol.md in usesense-watchtower.
enum StepUpCapability {
    static let stepUpV1 = "step_up_v1"

    /// Every capability this SDK version declares.
    static let all: [String] = [stepUpV1]
}

/// The `step_up` object of a round-1 /signals response, decoded tolerantly:
/// a challenge this SDK can't decode becomes nil instead of failing the
/// whole upload response.
struct StepUpPayload: Decodable {
    let round: Int?
    let challenge: ChallengeSpecWrapper?
    let maxFrames: Int?

    private enum CodingKeys: String, CodingKey { case round, challenge, upload }
    private enum UploadKeys: String, CodingKey { case maxFrames = "max_frames" }

    init(round: Int?, challenge: ChallengeSpecWrapper?, maxFrames: Int?) {
        self.round = round
        self.challenge = challenge
        self.maxFrames = maxFrames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        round = try? c.decodeIfPresent(Int.self, forKey: .round)
        challenge = try? c.decodeIfPresent(ChallengeSpecWrapper.self, forKey: .challenge)
        if let upload = try? c.nestedContainer(keyedBy: UploadKeys.self, forKey: .upload) {
            maxFrames = try? upload.decodeIfPresent(Int.self, forKey: .maxFrames)
        } else {
            maxFrames = nil
        }
    }
}

/// A step-up the server asked for: the challenge to run and the round's frame budget.
struct StepUpInstruction {
    let challenge: ChallengeSpecWrapper
    let maxFrames: Int

    static let defaultMaxFrames = 20

    /// Nil for anything this SDK can't render (another round, speak_phrase,
    /// a spec without steps or seed), so the session completes as before and
    /// the server applies its own fallback.
    init?(payload: StepUpPayload?) {
        guard let payload, payload.round == 2, let challenge = payload.challenge,
              !challenge.seed.isEmpty else { return nil }
        switch challenge {
        case .headTurn(let c) where !c.sequence.isEmpty: break
        case .followDot(let c) where !c.waypoints.isEmpty: break
        default: return nil
        }
        self.challenge = challenge
        if let m = payload.maxFrames, m > 0 {
            self.maxFrames = m
        } else {
            self.maxFrames = StepUpInstruction.defaultMaxFrames
        }
    }
}
