import Foundation

final class ChallengeResponseBuilder: @unchecked Sendable {
    private let spec: ChallengeSpec
    private var startedAt: Date?
    private var completedAt: Date?
    private var waypointFrames: [String: [Int]] = [:]
    private var stepFrames: [String: [Int]] = [:]
    private var currentStepIndex: Int = 0

    init(spec: ChallengeSpec) {
        self.spec = spec
    }

    func markStarted() {
        startedAt = Date()
    }

    func markCompleted() {
        completedAt = Date()
    }

    func setCurrentStep(_ index: Int) {
        currentStepIndex = index
    }

    func recordFrame(index: Int) {
        let key = String(currentStepIndex)
        switch spec.type {
        case .followDot:
            waypointFrames[key, default: []].append(index)
        case .headTurn:
            stepFrames[key, default: []].append(index)
        case .speakPhrase:
            break
        }
    }

    func build(frameTimestamps: [Int]) -> ChallengeResponsePayload {
        ChallengeResponsePayload(
            type: spec.type.rawValue,
            seed: spec.seed,
            completed: completedAt != nil,
            waypointFrames: spec.type == .followDot ? waypointFrames : nil,
            stepFrames: spec.type == .headTurn ? stepFrames : nil,
            startedAt: startedAt,
            completedAt: completedAt,
            frameTimestamps: frameTimestamps
        )
    }
}
