import Foundation
import CoreGraphics

// MARK: - Extra check on the scan screen (storyboard flows 4 and 5)
//
// The guided capture draws a challenge on the scan screen itself: the camera,
// a purple ring that fills as the challenge runs, and one instruction at a
// time. `ChallengeRunner` is the pure timeline behind it. The session feeds it
// one observation per tick (is the face in the oval, the head pose, the mic
// level) and draws what it returns. Rules (agreed UX decisions):
//   - The face leaves the oval: the timeline pauses, the ring turns amber and
//     the text says what to fix. It resumes when the face is back. Nothing
//     fails on the device.
//   - A Head Turn step that wasn't turned far enough gets ONE local retry with
//     a hint. After that the result is left to the server.
//   - Follow Dot: the dot waits in place while the face is away.
//   - Speak Digits: the meter staying flat for 2 s says "Speak a little louder".

/// One tick's worth of what the camera and microphone saw.
struct ChallengeObservation: Equatable {
    /// Seconds on any monotonic clock.
    var time: TimeInterval
    /// A face is in the oval (debounced by the runner).
    var facePresent: Bool
    /// Physical head pose in degrees (ZYX from the face transform), when known.
    var yaw: Double?
    var pitch: Double?
    /// Microphone level 0...1 (Speak Digits only).
    var level: Double?
    /// The person has the "Leave verification?" dialog open: time stands still.
    var held: Bool = false
}

/// What the challenge screen draws.
struct ChallengeDisplay: Equatable {
    enum Kind: Equatable { case headTurn, followDot, digits }
    enum Tone: Equatable { case active, warning }

    var kind: Kind
    /// Ring fill 0...1.
    var progress: Double
    var tone: Tone
    var title: String
    var subtitle: String?
    /// Head Turn: the side to turn to (nil while paused or for "centre").
    var arrow: HeadDirection?
    /// Follow Dot: the dot and the path it has taken, in 0...1 screen units.
    var dot: CGPoint?
    var trail: [CGPoint] = []
    /// Speak Digits: the digits to say, and the latest mic level.
    var digits: String?
    var level: Double = 0
    var finished = false

    static let placeholder = ChallengeDisplay(kind: .headTurn, progress: 0, tone: .active,
                                              title: ExtraCheckCopy.showFace, subtitle: nil)
}

/// Every string the extra check shows (storyboard copy, no em dashes).
enum ExtraCheckCopy {
    static let sheetTitle = "One more quick check"
    static let continueButton = "Continue"
    static let done = "Done"
    static let showFace = "Show your face in the oval"
    static let centreFace = "Move your face to the centre"
    static let keepTurning = "Then keep turning"
    static let dotWaits = "The dot will wait for you"
    static let thenSayNumbers = "Then say the numbers"
    static let followDot = "Follow the dot with your head"
    static let keepFollowing = "Keep following"
    static let sayNumbers = "Say these numbers"
    static let cantHear = "We can't hear you"
    static let speakLouder = "Speak a little louder"
    static let tryAgain = "Let's try that again"
    static let slowly = "Slowly"

    /// The sheet's one sentence for each challenge.
    static func sheetBody(_ kind: ChallengeType) -> String {
        switch kind {
        case .headTurn: return "Slowly turn your head to the left, then to the right."
        case .followDot: return "Keep your face in the oval and follow the dot with your head."
        case .speakPhrase: return "Say the numbers you see out loud. We'll need your microphone."
        }
    }

    /// Head Turn: the sheet names the first two sides the server asked for.
    static func sheetBody(for spec: ChallengeSpecWrapper) -> String {
        guard case .headTurn(let c) = spec else { return sheetBody(spec.challengeType) }
        let sides = c.sequence.map(\.direction).filter { $0 != .center }
        guard let first = sides.first else { return sheetBody(.headTurn) }
        if sides.count == 1 { return "Slowly turn your head \(phrase(first))." }
        return "Slowly turn your head \(phrase(first)), then \(phrase(sides[1]))."
    }

    /// "to the left", "up", ...
    static func phrase(_ d: HeadDirection) -> String {
        switch d {
        case .left: return "to the left"
        case .right: return "to the right"
        case .up: return "up"
        case .down: return "down"
        case .center: return "back to the centre"
        }
    }

    /// The instruction for a Head Turn step.
    static func headTurnTitle(_ d: HeadDirection, first: Bool) -> String {
        switch d {
        case .left, .right: return first ? "Turn your head \(phrase(d))" : "Now \(phrase(d))"
        case .up: return first ? "Look up" : "Now look up"
        case .down: return first ? "Look down" : "Now look down"
        case .center: return "Now look straight ahead"
        }
    }

    /// The retry hint: "Turn a little further to the left".
    static func furtherHint(_ d: HeadDirection) -> String {
        switch d {
        case .left, .right: return "Turn a little further \(phrase(d))"
        case .up: return "Look a little further up"
        case .down: return "Look a little further down"
        case .center: return "Look straight at the screen"
        }
    }
}

struct ChallengeRunner {
    /// A face must be gone this long before the challenge pauses (one dropped
    /// frame is not a pause), and back this long before it resumes.
    static let lostAfter: TimeInterval = 0.3
    static let foundAfter: TimeInterval = 0.15
    /// A Head Turn step counts as turned when the pose reached this far. The
    /// server's own bar is 6 degrees (yaw) / 5 (pitch) on its own pose
    /// estimate; the device asks for a little more so a retry is only offered
    /// when the turn was clearly short. Direction is left to the server.
    static let turnYaw: Double = 10
    static let turnPitch: Double = 8
    /// About -40 dB on the meter's scale (`AudioCaptureManager.normalised`).
    static let quietLevel: Double = 0.12
    static let quietAfter: TimeInterval = 2
    /// Follow Dot: time the dot takes to glide to its next waypoint.
    static let dotGlide: TimeInterval = 0.6

    enum Plan {
        case headTurn([HeadTurnStep])
        case followDot([FollowDotWaypoint])
        case digits(phrase: String, durationMs: Int)

        var isDigits: Bool {
            if case .digits = self { return true }
            return false
        }
    }

    let plan: Plan
    private(set) var retriesLeft: Int

    /// Index into the plan's steps.
    private(set) var stepIndex = 0
    private(set) var stepElapsed: TimeInterval = 0
    private(set) var finished = false
    /// The step being redone after a missed turn (shows the hint).
    private(set) var retrying = false
    private var peak: Double = 0
    private var poseSeen = false
    private var lastTime: TimeInterval?
    private var present = false
    private var everPresent = false
    private var absentFor: TimeInterval = 0
    private var presentFor: TimeInterval = 0
    private var quietFor: TimeInterval = 0
    private var lastLevel: Double = 0

    init(plan: Plan, retries: Int = 1) {
        self.plan = plan
        self.retriesLeft = retries
    }

    init?(spec: ChallengeSpecWrapper, retries: Int = 1) {
        switch spec {
        case .headTurn(let c):
            guard !c.sequence.isEmpty else { return nil }
            self.init(plan: .headTurn(c.sequence), retries: retries)
        case .followDot(let c):
            guard !c.waypoints.isEmpty else { return nil }
            self.init(plan: .followDot(c.waypoints), retries: retries)
        case .speakPhrase(let c):
            self.init(plan: .digits(phrase: c.phrase, durationMs: max(1000, c.totalDurationMs)), retries: retries)
        }
    }

    // MARK: Steps

    private var durations: [TimeInterval] {
        switch plan {
        case .headTurn(let s): return s.map { max(0.2, Double($0.durationMs) / 1000) }
        case .followDot(let w): return w.map { max(0.2, Double($0.durationMs) / 1000) }
        case .digits(_, let ms): return [Double(ms) / 1000]
        }
    }

    /// The spec's own index for the current step (what `step_frames` /
    /// `waypoint_frames` are keyed by).
    var specStepIndex: Int {
        let i = min(stepIndex, stepCount - 1)
        switch plan {
        case .headTurn(let s): return s[i].index
        case .followDot(let w): return w[i].index
        case .digits: return 0
        }
    }

    var stepCount: Int { durations.count }

    /// The face is in the oval (debounced).
    var isPresent: Bool { present }

    // MARK: Tick

    /// Advance to `obs.time` and return what to draw.
    mutating func advance(_ obs: ChallengeObservation) -> ChallengeDisplay {
        let dt = lastTime.map { min(0.25, max(0, obs.time - $0)) } ?? 0
        lastTime = obs.time
        updatePresence(obs.facePresent, dt: dt)

        if let level = obs.level {
            lastLevel = level
            quietFor = level < Self.quietLevel ? quietFor + dt : 0
        }

        let running = present && !obs.held && !finished
        if running {
            if case .headTurn(let steps) = plan, stepIndex < steps.count {
                notePose(steps[stepIndex].direction, yaw: obs.yaw, pitch: obs.pitch)
            }
            stepElapsed += dt
            let durs = durations
            while !finished, stepIndex < durs.count, stepElapsed >= durs[stepIndex] {
                endStep(overflow: stepElapsed - durs[stepIndex])
            }
        }
        return display(held: obs.held)
    }

    private mutating func updatePresence(_ seen: Bool, dt: TimeInterval) {
        if seen {
            presentFor += dt
            absentFor = 0
            // The first sighting starts at once; later returns are debounced.
            if !present, !everPresent || presentFor >= Self.foundAfter {
                present = true
                everPresent = true
            }
        } else {
            absentFor += dt
            presentFor = 0
            if present, absentFor >= Self.lostAfter { present = false }
        }
    }

    private mutating func notePose(_ direction: HeadDirection, yaw: Double?, pitch: Double?) {
        switch direction {
        case .left, .right:
            if let yaw { poseSeen = true; peak = max(peak, abs(yaw)) }
        case .up, .down:
            if let pitch { poseSeen = true; peak = max(peak, abs(pitch)) }
        case .center:
            break
        }
    }

    /// Whether the step just ended counts as done on the device.
    private func stepTurnedFarEnough() -> Bool {
        guard case .headTurn(let steps) = plan else { return true }
        let direction = steps[stepIndex].direction
        // No pose readings (no transform from the landmarker): nothing to judge.
        guard poseSeen else { return true }
        switch direction {
        case .left, .right: return peak >= Self.turnYaw
        case .up, .down: return peak >= Self.turnPitch
        case .center: return true
        }
    }

    private mutating func endStep(overflow: TimeInterval) {
        if !stepTurnedFarEnough(), retriesLeft > 0 {
            retriesLeft -= 1
            retrying = true
            stepElapsed = 0
            peak = 0
            poseSeen = false
            return
        }
        retrying = false
        stepIndex += 1
        stepElapsed = max(0, overflow)
        peak = 0
        poseSeen = false
        if stepIndex >= stepCount {
            finished = true
            stepIndex = stepCount - 1
            stepElapsed = durations.last ?? 0
        }
    }

    // MARK: Display

    var progress: Double {
        let durs = durations
        let total = durs.reduce(0, +)
        guard total > 0 else { return 1 }
        if finished { return 1 }
        let done = durs.prefix(stepIndex).reduce(0, +)
        return min(1, (done + min(stepElapsed, durs[stepIndex])) / total)
    }

    func display(held: Bool = false) -> ChallengeDisplay {
        let paused = everPresent && !present && !finished
        switch plan {
        case .headTurn(let steps):
            let step = steps[min(stepIndex, steps.count - 1)]
            var d = ChallengeDisplay(kind: .headTurn, progress: progress, tone: .active, title: "", subtitle: nil)
            d.finished = finished
            if !everPresent {
                d.title = ExtraCheckCopy.showFace
            } else if paused {
                d.tone = .warning
                d.title = ExtraCheckCopy.centreFace
                d.subtitle = ExtraCheckCopy.keepTurning
            } else if retrying {
                d.title = ExtraCheckCopy.tryAgain
                d.subtitle = ExtraCheckCopy.furtherHint(step.direction)
                d.arrow = step.direction == .center ? nil : step.direction
            } else {
                let firstTurn = steps.prefix(stepIndex).allSatisfy { $0.direction == .center }
                d.title = ExtraCheckCopy.headTurnTitle(step.direction, first: firstTurn)
                d.subtitle = firstTurn && step.direction != .center ? ExtraCheckCopy.slowly : nil
                d.arrow = step.direction == .center ? nil : step.direction
            }
            return d

        case .followDot(let waypoints):
            var d = ChallengeDisplay(kind: .followDot, progress: progress, tone: .active, title: "", subtitle: nil)
            d.finished = finished
            let pts = waypoints.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            let i = min(stepIndex, pts.count - 1)
            let from = i == 0 ? pts[0] : pts[i - 1]
            let glide = min(Self.dotGlide, durations[i] * 0.4)
            let t = glide > 0 ? min(1, stepElapsed / glide) : 1
            let e = t * t * (3 - 2 * t)
            let dot = CGPoint(x: from.x + (pts[i].x - from.x) * e, y: from.y + (pts[i].y - from.y) * e)
            d.dot = dot
            d.trail = Array(pts.prefix(i)) + [dot]
            if !everPresent {
                d.title = ExtraCheckCopy.showFace
            } else if paused {
                d.tone = .warning
                d.title = ExtraCheckCopy.showFace
                d.subtitle = ExtraCheckCopy.dotWaits
            } else {
                d.title = stepIndex * 2 < pts.count ? ExtraCheckCopy.followDot : ExtraCheckCopy.keepFollowing
            }
            return d

        case .digits(let phrase, _):
            var d = ChallengeDisplay(kind: .digits, progress: progress, tone: .active, title: "", subtitle: nil)
            d.finished = finished
            d.digits = phrase
            d.level = lastLevel
            if !everPresent {
                d.title = ExtraCheckCopy.showFace
            } else if paused {
                d.tone = .warning
                d.title = ExtraCheckCopy.showFace
                d.subtitle = ExtraCheckCopy.thenSayNumbers
            } else if quietFor >= Self.quietAfter {
                d.tone = .warning
                d.title = ExtraCheckCopy.cantHear
                d.subtitle = ExtraCheckCopy.speakLouder
            } else {
                d.title = ExtraCheckCopy.sayNumbers
            }
            return d
        }
    }
}

// MARK: - Presence in the oval during a challenge

extension ChallengeRunner {
    /// A face counts as in the oval while its centre (mean of landmarks 10,
    /// 152, 234, 454, in oval radii from the expected face centre) is within
    /// these bounds. Looser than the scan's gate: turning the head moves the
    /// centre, and that is the point of the challenge.
    static let presenceX: CGFloat = 0.55
    static let presenceY: CGFloat = 0.45

    static func faceInOval(centreOffset: CGPoint?) -> Bool {
        guard let c = centreOffset else { return false }
        return abs(c.x) <= presenceX && abs(c.y) <= presenceY
    }
}
