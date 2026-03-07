import Foundation

enum PermissionType: Sendable {
    case camera
    case microphone
}

enum CapturePhase: String, CaseIterable, Sendable {
    case instructions
    case faceGuide
    case baseline
    case countdown
    case challenge
    case done
}

enum SessionState: Sendable {
    case idle
    case created(session: SessionData)
    case permissionsRequired(permissions: [PermissionType])
    case instructions(challenge: ChallengeSpec)
    case faceGuide
    case baseline(remaining: TimeInterval)
    case countdown(number: Int)
    case challenge(spec: ChallengeSpec)
    case uploading(progress: Double)
    case completing
    case done(result: UseSenseResult)
    case error(UseSenseError)
}

struct SessionData: Sendable {
    let sessionId: String
    let sessionToken: String
    let nonce: String
    let expiresAt: Date
    let policy: SessionPolicy
    let upload: UploadConfig

    var isExpired: Bool {
        Date() >= expiresAt
    }
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

// Make types Sendable where needed
extension SessionPolicy: @unchecked Sendable {}
extension ChallengeSpec: @unchecked Sendable {}
extension AudioChallengeSpec: @unchecked Sendable {}
extension UploadConfig: @unchecked Sendable {}
