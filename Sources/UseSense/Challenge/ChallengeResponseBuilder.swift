import Foundation

/// Tracks challenge completion during capture, mapping frame indices to challenge steps.
/// Matches Android's ChallengeResponseBuilder structure with waypoint_frames/step_frames.
final class ChallengeResponseBuilder: @unchecked Sendable {
    private var waypointFrames: [Int: [Int]] = [:]  // step index → list of frame indices
    private var frameTimestamps: [Int64] = []
    private var startedAt: String?
    private var completedAt: String?
    private var completed = false
    private var currentStepIndex = 0
    private let lock = NSLock()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func markStarted() {
        lock.lock()
        defer { lock.unlock() }
        startedAt = isoFormatter.string(from: Date())
    }

    func markCompleted() {
        lock.lock()
        defer { lock.unlock() }
        completedAt = isoFormatter.string(from: Date())
        completed = true
    }

    func setCurrentStep(_ stepIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        currentStepIndex = stepIndex
    }

    func recordFrame(frameIndex: Int, timestampMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if waypointFrames[currentStepIndex] == nil {
            waypointFrames[currentStepIndex] = []
        }
        waypointFrames[currentStepIndex]?.append(frameIndex)
        frameTimestamps.append(timestampMs)
    }

    // Legacy API for compatibility
    func start() { markStarted() }

    func recordStep(index: Int, value: String? = nil) {
        setCurrentStep(index)
    }

    /// Build the challenge response as a dictionary matching Android's JSON structure.
    func build(challenge: ChallengeSpecWrapper) -> [String: Any] {
        lock.lock()
        let frames = waypointFrames
        let timestamps = frameTimestamps
        let started = startedAt
        let ended = completedAt
        let isCompleted = completed
        lock.unlock()

        var json: [String: Any] = [:]
        json["type"] = challenge.challengeType.rawValue
        json["seed"] = challenge.seed
        json["completed"] = isCompleted

        // Use waypoint_frames for follow_dot, step_frames for head_turn
        let framesKey: String?
        switch challenge.challengeType {
        case .followDot: framesKey = "waypoint_frames"
        case .headTurn: framesKey = "step_frames"
        case .speakPhrase: framesKey = nil
        }

        if let key = framesKey {
            var framesObj: [String: [Int]] = [:]
            for (stepIdx, frameList) in frames {
                framesObj["\(stepIdx)"] = frameList
            }
            json[key] = framesObj
        }

        if let s = started { json["started_at"] = s }
        if let e = ended { json["completed_at"] = e }
        json["frame_timestamps"] = timestamps

        return json
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        waypointFrames.removeAll()
        frameTimestamps.removeAll()
        startedAt = nil
        completedAt = nil
        completed = false
        currentStepIndex = 0
    }
}
