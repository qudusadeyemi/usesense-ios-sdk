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
    /// Every check that holds the scan passes (the quality gate, with the
    /// current step's `gateRules`). Debounced by the runner.
    var facePresent: Bool
    /// Physical head pose in degrees (ZYX from the face transform), when known.
    var yaw: Double?
    var pitch: Double?
    /// Microphone level 0...1 (Speak Digits only).
    var level: Double?
    /// The person has the "Leave verification?" dialog open: time stands still.
    var held: Bool = false
    /// The gate's hint for what fails, if anything (named when paused).
    var hint: GateHint? = nil
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

/// How one challenge step went on the device, for the server's timing
/// checks: a live person turns after the prompt, from straight ahead; a
/// replayed or looping video doesn't line up with prompts it can't see.
struct ChallengeStepLog: Equatable {
    /// The spec's step index.
    var index: Int
    /// Challenge clock (seconds) when the step was prompted, and when it ended.
    var promptedAt: TimeInterval
    var endedAt: TimeInterval
    /// When the pose first reached the target (Head Turn), if it did.
    var reachedAt: TimeInterval?
    /// The step ended on the target (true), on time-out (false), or by the
    /// server's time with no pose to judge (nil).
    var reached: Bool?
    var hinted: Bool
}

struct ChallengeRunner {
    /// A face must be gone this long before the challenge pauses (one dropped
    /// frame is not a pause), and back this long before it resumes.
    static let lostAfter: TimeInterval = 0.3
    static let foundAfter: TimeInterval = 0.15
    /// Head Turn follows the person: a step ends when the head has reached
    /// the asked side (or, for "centre", come back) and held it for
    /// `holdAtTarget`, so the step's frames show the pose. The server's own
    /// bar is 6 degrees (yaw) / 5 (pitch) on its pose estimate; the device
    /// asks for a little more so the server sees a clear turn.
    static let turnYaw: Double = 15
    static let turnPitch: Double = 12
    static let centreTolerance: Double = 10
    static let holdAtTarget: TimeInterval = 0.5
    /// Not there after this long: show the hint ("Turn a little further"),
    /// once per challenge. Not there again after the same time: move on and
    /// leave the result to the server. Never shorter than the server's step.
    static let hintAfter: TimeInterval = 4
    /// Which way "left" reads in the face transform's yaw. Measured on an
    /// iPhone 17 Pro front camera, 2026-11-10 (sandbox head-turn run): turning
    /// left read -42 degrees, right +33, looking up gave pitch +33. The server
    /// (its own estimate) scored the same turns left +20.6, right -26.7.
    static let leftYawSign: Double = -1
    static let upPitchSign: Double = 1
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
    /// Head Turn: time at the target so far, and whether a pose was seen.
    private var atTarget: TimeInterval = 0
    private var poseSeen = false
    /// Step timing (see `ChallengeStepLog`).
    private(set) var stepLog: [ChallengeStepLog] = []
    private var stepPromptedAt: TimeInterval?
    private var stepReachedAt: TimeInterval?
    private var stepHinted = false
    private var lastTime: TimeInterval?
    private var present = false
    private var everPresent = false
    private var absentFor: TimeInterval = 0
    private var presentFor: TimeInterval = 0
    private var quietFor: TimeInterval = 0
    private var lastLevel: Double = 0
    private var lastHint: GateHint?

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

    /// The gate passes (debounced).
    var isPresent: Bool { present }

    /// The quality gate's rules for the step running now.
    var gateRules: ChallengeGateRules {
        switch plan {
        case .headTurn(let steps): return .forHeadTurn(steps[min(stepIndex, steps.count - 1)].direction)
        case .followDot: return .followDot
        case .digits: return .digits
        }
    }

    /// What holds the challenge, in the gate's words ("Keep your face
    /// uncovered", ...), or `fallback` when the gate gave no hint.
    private func pauseTitle(_ fallback: String) -> String {
        lastHint?.title ?? fallback
    }

    // MARK: Tick

    /// Advance to `obs.time` and return what to draw.
    mutating func advance(_ obs: ChallengeObservation) -> ChallengeDisplay {
        let dt = lastTime.map { min(0.25, max(0, obs.time - $0)) } ?? 0
        lastTime = obs.time
        // A step is prompted when it first shows to a person in the oval.
        if stepPromptedAt == nil, present || obs.facePresent, !finished { stepPromptedAt = obs.time }
        updatePresence(obs.facePresent, dt: dt)
        if obs.hint != nil || obs.facePresent { lastHint = obs.hint }

        if let level = obs.level {
            lastLevel = level
            quietFor = level < Self.quietLevel ? quietFor + dt : 0
        }

        let running = present && !obs.held && !finished
        if running {
            stepElapsed += dt
            if case .headTurn(let steps) = plan {
                advanceHeadTurn(steps[stepIndex], yaw: obs.yaw, pitch: obs.pitch, dt: dt)
            } else {
                let durs = durations
                while !finished, stepIndex < durs.count, stepElapsed >= durs[stepIndex] {
                    endStep(overflow: stepElapsed - durs[stepIndex])
                }
            }
        }
        return display(held: obs.held)
    }

    /// Whether the pose is at the step's target (nil: no pose to judge).
    static func atTarget(_ direction: HeadDirection, yaw: Double?, pitch: Double?) -> Bool? {
        switch direction {
        case .left, .right:
            guard let yaw else { return nil }
            let towardLeft = yaw * leftYawSign
            return direction == .left ? towardLeft >= turnYaw : -towardLeft >= turnYaw
        case .up, .down:
            guard let pitch else { return nil }
            let towardUp = pitch * upPitchSign
            return direction == .up ? towardUp >= turnPitch : -towardUp >= turnPitch
        case .center:
            guard let yaw, let pitch else { return nil }
            return abs(yaw) < centreTolerance && abs(pitch) < centreTolerance
        }
    }

    private mutating func advanceHeadTurn(_ step: HeadTurnStep, yaw: Double?, pitch: Double?, dt: TimeInterval) {
        let server = max(0.2, Double(step.durationMs) / 1000)
        guard let reached = Self.atTarget(step.direction, yaw: yaw, pitch: pitch) else {
            // No transform from the landmarker: fall back to the server's time.
            if !poseSeen, stepElapsed >= server { endStep(overflow: 0) }
            return
        }
        poseSeen = true
        if reached, atTarget == 0 { stepReachedAt = lastTime }
        atTarget = reached ? atTarget + dt : 0
        if !reached { stepReachedAt = nil }
        if atTarget >= Self.holdAtTarget {
            endStep(overflow: 0, reached: true)
            return
        }
        let window = max(Self.hintAfter, server)
        if stepElapsed >= window {
            if !retrying, retriesLeft > 0 {
                // One hint per challenge, with the same time again.
                retriesLeft -= 1
                retrying = true
                stepHinted = true
                stepElapsed = 0
            } else {
                endStep(overflow: 0, reached: false)   // the server judges this step
            }
        }
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

    private mutating func endStep(overflow: TimeInterval, reached: Bool? = nil) {
        if case .headTurn(let steps) = plan, stepIndex < steps.count {
            let now = lastTime ?? 0
            stepLog.append(ChallengeStepLog(index: steps[stepIndex].index, promptedAt: stepPromptedAt ?? now,
                                            endedAt: now, reachedAt: reached == true ? stepReachedAt : nil,
                                            reached: reached, hinted: stepHinted))
        }
        stepPromptedAt = finished ? nil : lastTime
        stepReachedAt = nil
        stepHinted = false
        retrying = false
        stepIndex += 1
        stepElapsed = max(0, overflow)
        atTarget = 0
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
        if case .headTurn = plan {
            // One segment per step, filled by the hold at the target.
            return min(1, (Double(stepIndex) + min(1, atTarget / Self.holdAtTarget)) / Double(stepCount))
        }
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
                d.title = pauseTitle(ExtraCheckCopy.centreFace)
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
                d.title = pauseTitle(ExtraCheckCopy.showFace)
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
                d.title = pauseTitle(ExtraCheckCopy.showFace)
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
