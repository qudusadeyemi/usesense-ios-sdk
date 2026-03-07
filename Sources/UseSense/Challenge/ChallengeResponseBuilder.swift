import Foundation

struct ChallengeResponse: Codable, Sendable {
    let challengeType: String
    let seed: String
    let responses: [ChallengeStepResponse]
    let completedAt: String
    let durationMs: Int

    enum CodingKeys: String, CodingKey {
        case challengeType = "challenge_type"
        case seed
        case responses
        case completedAt = "completed_at"
        case durationMs = "duration_ms"
    }
}

struct ChallengeStepResponse: Codable, Sendable {
    let stepIndex: Int
    let timestamp: String
    let value: String?

    enum CodingKeys: String, CodingKey {
        case stepIndex = "step_index"
        case timestamp
        case value
    }
}

final class ChallengeResponseBuilder: @unchecked Sendable {
    private var steps: [ChallengeStepResponse] = []
    private var startTime: Date?
    private let lock = NSLock()

    func start() {
        lock.lock()
        defer { lock.unlock() }
        startTime = Date()
        steps.removeAll()
    }

    func recordStep(index: Int, value: String? = nil) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let step = ChallengeStepResponse(
            stepIndex: index,
            timestamp: formatter.string(from: Date()),
            value: value
        )

        lock.lock()
        defer { lock.unlock() }
        steps.append(step)
    }

    func build(challenge: ChallengeSpecWrapper) -> ChallengeResponse {
        lock.lock()
        let capturedSteps = steps
        let start = startTime ?? Date()
        lock.unlock()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        return ChallengeResponse(
            challengeType: challenge.challengeType.rawValue,
            seed: challenge.seed,
            responses: capturedSteps,
            completedAt: formatter.string(from: Date()),
            durationMs: durationMs
        )
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        steps.removeAll()
        startTime = nil
    }
}
