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
    /// Guided Head Turn: per-step timing (`step_events`), ms since the epoch.
    private var stepEvents: [[String: Any]] = []
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

    /// Per-step timing from the guided challenge: when each step was prompted,
    /// when the pose reached it, and how it ended. `start` is the wall-clock
    /// time of the challenge clock's zero.
    func setStepEvents(_ log: [ChallengeStepLog], start: Date) {
        let ms = { (t: TimeInterval) in Int(((start.timeIntervalSince1970 + t) * 1000).rounded()) }
        let events: [[String: Any]] = log.map { e in
            var d: [String: Any] = ["index": e.index, "prompted_at_ms": ms(e.promptedAt), "ended_at_ms": ms(e.endedAt),
                                    "hinted": e.hinted]
            if let r = e.reachedAt {
                d["reached_at_ms"] = ms(r)
                d["reaction_ms"] = Int(((r - e.promptedAt) * 1000).rounded())
            }
            d["outcome"] = e.reached.map { $0 ? "reached" : "timed_out" } ?? "timed"
            return d
        }
        lock.lock(); stepEvents = events; lock.unlock()
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
        let events = stepEvents
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
        if !events.isEmpty { json["step_events"] = events }

        return json
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        waypointFrames.removeAll()
        stepEvents.removeAll()
        frameTimestamps.removeAll()
        startedAt = nil
        completedAt = nil
        completed = false
        currentStepIndex = 0
    }
}
