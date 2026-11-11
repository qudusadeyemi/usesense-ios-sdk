import Foundation

/// Speak Digits needs the microphone. When it is refused (or the device has no
/// input), the person can do a head movement instead: the SDK asks the server
/// to swap the challenge, and the server returns the session's policy with a
/// seeded Follow Dot of the same strength.
///
/// `POST /v1/sessions/:id/challenge-fallback`, session-token auth (as
/// /signals), body `{"reason":"microphone_unavailable"}`. Only before the
/// capture is uploaded. Errors: 409 `capture_already_uploaded` /
/// `fallback_not_allowed`, 400 for an unknown reason, 401 for a bad token.
/// Server: usesense-watchtower PR #1056.
enum ChallengeFallbackReason: String {
    case microphoneUnavailable = "microphone_unavailable"
}

struct ChallengeFallbackResponse: Decodable {
    let sessionId: String
    let policy: SessionPolicy

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case policy
    }
}
