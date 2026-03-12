import Foundation

enum PermissionType: Sendable { case camera, microphone }

/// Capture phase enum matching the spec state machine exactly.
public enum CapturePhase: String, CaseIterable, Sendable {
    case initializing    = "initializing"
    case cameraRequest   = "camera-request"
    case cameraError     = "camera-error"
    case instructions    = "instructions"
    case faceGuide       = "face-guide"
    case baseline        = "baseline"
    case countdown       = "countdown"
    case challenge       = "challenge"
    case uploading       = "uploading"
    case completing      = "completing"
    case done            = "done"
}

enum SessionState: Sendable {
    case idle
    case created(session: SessionData)
    case permissionsRequired(permissions: [PermissionType])
    case cameraError(message: String)
    case instructions(challenge: ChallengeSpecWrapper)
    case faceGuide
    case baseline(remaining: TimeInterval)
    case countdown(number: Int)
    case challenge(spec: ChallengeSpecWrapper)
    case uploading(progress: Double)
    case completing
    case done(decision: RedactedDecisionObject)
    case error(UseSenseError)
}

struct SessionData: Sendable {
    let sessionId: String
    let sessionToken: String
    let nonce: String
    let expiresAt: Date
    let policy: SessionPolicy
    let upload: UploadConfig

    var isExpired: Bool { Date() >= expiresAt }
}

extension SessionData {
    init(from response: CreateSessionResponse) {
        self.sessionId = response.sessionId
        self.sessionToken = response.sessionToken
        self.nonce = response.nonce

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.expiresAt = formatter.date(from: response.expiresAt) ?? Date().addingTimeInterval(900)

        self.policy = response.policy
        self.upload = response.upload
    }
}
