import Foundation
import CoreGraphics

// MARK: - Capture quality gate (LiveSense capture redesign, Phase 1)
//
// One spec for iOS, Android and web (livesense-capture-proposal, "Quality
// gate"). The checks run in priority order on the MediaPipe mesh plus a
// luminance/sharpness pass over the face box, and they BLOCK the scan: it
// starts only when every check passes and pauses while any fails.
//
// Everything here is display and gating only. Nothing in this file changes
// what is uploaded or how the server scores it.

/// The gate's checks, in priority order (lowest raw value = highest priority).
enum GateCheck: Int, CaseIterable, Comparable, Sendable {
    // Spec v1.2: distance runs before in-frame, so size problems get size guidance.
    // COVER-v1: covered runs right after one person.
    case faceFound, onePerson, covered, distance, inFrame, pose, light, sharpness, eyesOpen, stillness

    static func < (lhs: GateCheck, rhs: GateCheck) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Short label for the debug chips.
    var debugLabel: String {
        switch self {
        case .faceFound: return "face"
        case .onePerson: return "one"
        case .covered: return "cover"
        case .inFrame: return "centre"
        case .distance: return "distance"
        case .pose: return "pose"
        case .light: return "light"
        case .sharpness: return "sharp"
        case .eyesOpen: return "eyes"
        case .stillness: return "still"
        }
    }
}

/// One user-facing hint. Copy is the capture test kit SPEC v1.1 "Guidance
/// copy", shared with Android and web: keep it exact.
struct GateHint: Equatable, Sendable {
    enum Icon: String, Sendable { case face, people, covered, centre, closer, back, pose, light, steady, eyes, still }

    let check: GateCheck
    let title: String
    let subtitle: String?
    let icon: Icon

    static let showFace = GateHint(check: .faceFound, title: "Show your face in the oval", subtitle: nil, icon: .face)
    static let onePerson = GateHint(check: .onePerson, title: "Only you in the picture", subtitle: nil, icon: .people)
    /// COVER-v1: a hand or an object over the face.
    static let uncovered = GateHint(check: .covered, title: "Keep your face uncovered", subtitle: nil, icon: .covered)
    static let centre = GateHint(check: .inFrame, title: "Move your face to the centre", subtitle: nil, icon: .centre)
    static let moveCloser = GateHint(check: .distance, title: "Move a little closer", subtitle: nil, icon: .closer)
    static let moveBack = GateHint(check: .distance, title: "Move back a little", subtitle: nil, icon: .back)
    /// Spec v1.2.1: in-frame fails on a well-placed face that is too close.
    static let moveBackToFit = GateHint(check: .inFrame, title: "Move back a little", subtitle: nil, icon: .back)
    static let lookStraight = GateHint(check: .pose, title: "Look straight ahead", subtitle: nil, icon: .pose)
    static let faceALight = GateHint(check: .light, title: "Find more light", subtitle: "Face a window or lamp", icon: .light)
    static let tooBright = GateHint(check: .light, title: "Too much light behind you",
                                    subtitle: "Turn away from the window", icon: .light)
    static let holdSteady = GateHint(check: .sharpness, title: "Hold your phone steady", subtitle: nil, icon: .steady)
    static let eyesOpen = GateHint(check: .eyesOpen, title: "Keep your eyes open", subtitle: nil, icon: .eyes)
    static let holdStill = GateHint(check: .stillness, title: "Hold still", subtitle: nil, icon: .still)
}

/// Pass thresholds. Starting points from the spec, to tune on session data.
struct GateThresholds: Sendable {
    var faceFoundFrames = 3
    /// Spec v1.2.2: every FACE_OVAL silhouette landmark within 1.15 x the
    /// oval radius (normalised ellipse distance).
    var ovalLimit = 1.15
    /// Spec v1.2.1: in-frame failing with the face centre within 8% (of rx
    /// and of ry) of the expected face centre means too close, not off-centre.
    var sizeNotPositionTolerance = 0.08
    /// Eye ratio (spec v1.2.2): iris distance / (oval width / 0.72), screen space.
    var minEyeDistance = 0.17
    var maxEyeDistance = 0.32
    /// Extra room each side of the distance band once the scan runs, so a
    /// face sitting on a band edge doesn't flicker and drop the scan (as Android).
    var distanceHoldMargin = 0.02
    var maxYaw = 15.0
    var maxPitch = 15.0
    var maxRoll = 12.0
    var minFaceLuma: Float = 70
    var maxFaceLuma: Float = 200
    var maxClippedRatio: Float = 0.08
    /// Laplacian variance of the 96x96 face. The spec wants the per-device
    /// 20th percentile; until that table exists this is a fixed floor.
    /// Measured through the real pipeline on a 720p portrait: sharp 1313,
    /// Gaussian blur sigma 2 -> 133, sigma 4 -> 25, sigma 8 -> 6.
    var minFaceSharpness: Float = 50
    var maxEyeBlink = 0.6
    var stillnessWindow: TimeInterval = 0.3
    var maxJitter = 0.04
}

/// The gate during a challenge (before the scan or round 2): every scan
/// check still runs, and only the pose limits relax toward the movement the
/// current step asks for. Stillness applies only where the person isn't
/// asked to move, and the scan's change watch is off (a turning head changes
/// every face region); the covered-face segmenter still runs.
struct ChallengeGateRules: Equatable, Sendable {
    var maxYaw: Double
    var maxPitch: Double
    var maxRoll: Double
    var checksStillness: Bool

    /// Head Turn left/right: the yaw limit opens. The sign of "left" isn't
    /// trusted on the device (the server judges direction), so it opens both ways.
    /// The other axis opens part way too: a person turning right straight
    /// after looking up still has the head a little raised (device run:
    /// pitch 19 while turning right, which a 15 cap paused).
    static let turnSideways = ChallengeGateRules(maxYaw: 50, maxPitch: 30, maxRoll: 20, checksStillness: false)
    static let turnUpDown = ChallengeGateRules(maxYaw: 30, maxPitch: 45, maxRoll: 20, checksStillness: false)
    /// Coming back to the centre (from any side), or following the dot.
    static let returning = ChallengeGateRules(maxYaw: 50, maxPitch: 45, maxRoll: 20, checksStillness: false)
    static let followDot = ChallengeGateRules(maxYaw: 40, maxPitch: 35, maxRoll: 20, checksStillness: false)
    /// Speak Digits: the scan's own limits, stillness included (the chin is
    /// left out of the stillness anchors, since speaking moves it).
    static let digits = ChallengeGateRules(maxYaw: 15, maxPitch: 15, maxRoll: 12, checksStillness: true)

    static func forHeadTurn(_ direction: HeadDirection) -> ChallengeGateRules {
        switch direction {
        case .left, .right: return .turnSideways
        case .up, .down: return .turnUpDown
        case .center: return .returning
        }
    }
}

/// What the session measured on one camera frame.
struct GateObservation: Sendable {
    var time: TimeInterval
    /// Faces returned by the landmarker (0 = none).
    var faceCount: Int
    /// The largest normalised ellipse radius of any FACE_OVAL landmark
    /// against the on-screen oval (<= 1 = inside the drawn edge).
    var ovalExtent: Double?
    /// Face centre (mean of 10, 152, 234, 454) minus the expected face centre
    /// (oval cx, oval cy + 0.25 ry), divided by (rx, ry).
    var faceCentreOffset: CGPoint?
    /// Iris-centre distance / frame width.
    var eyeDistance: Double?
    /// ZYX Euler angles from the transformation matrix (degrees).
    var yaw: Double?
    var pitch: Double?
    var roll: Double?
    var face: FaceRegionQuality?
    var eyeBlinkLeft: Double?
    var eyeBlinkRight: Double?
    /// Stillness anchors, normalised buffer coordinates.
    var anchors: [CGPoint]
    /// COVER-v1: the latest segmentation result for this face (at most 3 s old).
    var cover: FaceCover? = nil
    /// The segmenter is on but this face has no result yet: hold, so a scan
    /// can't start unchecked.
    var coverPending = false
    /// Six face regions for the change watch (scan only).
    var regions: FaceRegions? = nil

    static func noFace(at time: TimeInterval) -> GateObservation {
        GateObservation(time: time, faceCount: 0, anchors: [])
    }
}

/// The guide's output for one frame.
struct GuideSnapshot: Equatable, Sendable {
    /// Every check passes on this frame (scan may start / bank frames).
    var allPass: Bool
    /// The hint to show (already debounced: 400 ms in, 1.2 s minimum).
    var hint: GateHint?
    /// The screen fill light should be on.
    var fillLight: Bool
    /// Checks failing on this frame (debug chips).
    var failing: Set<GateCheck>

    static let initial = GuideSnapshot(allPass: false, hint: nil, fillLight: false, failing: Set(GateCheck.allCases))
}

// MARK: - Per-frame checks

/// Stateful check evaluation (face streak + stillness history).
struct QualityGate: Sendable {
    var thresholds = GateThresholds()
    private var faceStreak = 0
    private var history: [(time: TimeInterval, anchors: [CGPoint], eyeDistance: Double)] = []
    private(set) var coverWatch = CoverWatch()
    private var wasScanning = false
    /// COVER-v1 "Fill light and the change watch": when the screen light last
    /// changed, still waiting for the watch to settle and re-baseline.
    private var lightChangedAt: TimeInterval?
    /// The pending light change happened during the scan (so its new
    /// baseline counts as a re-baseline, not the scan's first baseline).
    private var lightChangedMidScan = false
    /// The change watch ran on this frame (for the upload's covered_check).
    private(set) var watchRan = false
    /// This frame took a new baseline after a fill-light change.
    private(set) var rebaselined = false
    /// Exposure settles for this long after the light changes.
    static let lightSettle: TimeInterval = 0.5
    /// When the current scan started, and how long until its first steady
    /// baseline was taken (nil until then).
    private var scanStartedAt: TimeInterval?
    private(set) var baselineWait: TimeInterval?

    init(thresholds: GateThresholds = GateThresholds()) { self.thresholds = thresholds }

    mutating func reset() {
        faceStreak = 0
        history.removeAll()
        coverWatch.reset()
        wasScanning = false
        lightChangedAt = nil
        lightChangedMidScan = false
        scanStartedAt = nil
        baselineWait = nil
    }

    /// The screen fill light changed (on or off) at `time`. During a scan the
    /// change watch's baseline no longer holds; just before a scan its first
    /// baseline must wait for exposure to settle. A brightness change alone is
    /// never a reason to re-baseline (a hand moves mean luma too).
    mutating func lightChanged(at time: TimeInterval, scanning: Bool) {
        lightChangedAt = time
        lightChangedMidScan = scanning
    }

    /// Light failure direction for this frame, if any.
    enum LightFailure: Equatable, Sendable { case tooDark, tooBright }

    struct Evaluation: Equatable, Sendable {
        var failing: [GateCheck: GateHint] = [:]
        var light: LightFailure?
        /// The landmark jitter / eye distance over the window (debug).
        var jitter: Double?
        /// The failures that hold the scan: everything except light. Light is
        /// advice only (it turns the fill light on and gives a hint): a darker
        /// face in ordinary room light reads under the luma floor and must
        /// not be locked out (as Android, user decision).
        var blocking: [GateCheck: GateHint] { failing.filter { $0.key != .light } }
    }

    mutating func evaluate(_ o: GateObservation, scanning: Bool = false,
                           challenge: ChallengeGateRules? = nil) -> Evaluation {
        var e = Evaluation()
        var t = thresholds
        if let challenge {
            t.maxYaw = challenge.maxYaw
            t.maxPitch = challenge.maxPitch
            t.maxRoll = challenge.maxRoll
        }
        // A new scan takes a new baseline for the change watch.
        if scanning && !wasScanning {
            coverWatch.reset()
            scanStartedAt = o.time
            baselineWait = nil
        }
        wasScanning = scanning

        // 1. Face found: 1 face for 3 frames in a row.
        faceStreak = o.faceCount > 0 ? faceStreak + 1 : 0
        guard o.faceCount > 0 else {
            history.removeAll()
            for check in GateCheck.allCases { e.failing[check] = .showFace }
            return e
        }
        if faceStreak < t.faceFoundFrames { e.failing[.faceFound] = .showFace }

        // 2. One person.
        if o.faceCount > 1 { e.failing[.onePerson] = .onePerson }

        // 2b. Covered (COVER-v1): the segmenter sees a hand or an object over
        // the face. The scan's change watch runs after stillness, below.
        if o.cover?.covered == true { e.failing[.covered] = .uncovered }

        // 3. Distance (spec v1.2: before in-frame).
        if let d = o.eyeDistance {
            let margin = scanning ? t.distanceHoldMargin : 0
            if d < t.minEyeDistance - margin { e.failing[.distance] = .moveCloser }
            else if d > t.maxEyeDistance + margin { e.failing[.distance] = .moveBack }
        } else {
            e.failing[.distance] = .moveCloser
        }

        // 4. In frame: the face silhouette inside 1.10 x the oval. When it
        // doesn't fit but the face sits where it should, it is too close.
        if (o.ovalExtent ?? .infinity) > t.ovalLimit {
            if let c = o.faceCentreOffset,
               abs(Double(c.x)) <= t.sizeNotPositionTolerance, abs(Double(c.y)) <= t.sizeNotPositionTolerance {
                e.failing[.inFrame] = .moveBackToFit
            } else {
                e.failing[.inFrame] = .centre
            }
        }

        // 5. Pose (no matrix = cannot be checked = blocks).
        if let yaw = o.yaw, let pitch = o.pitch, let roll = o.roll {
            if abs(yaw) >= t.maxYaw || abs(pitch) >= t.maxPitch || abs(roll) >= t.maxRoll {
                e.failing[.pose] = .lookStraight
            }
        } else {
            e.failing[.pose] = .lookStraight
        }

        // 6. Light, 7. sharpness (face box).
        if let face = o.face {
            // Clipped = luma <= 5 or >= 250, both ends together (as Android).
            let clipped = face.clippedHighRatio + face.clippedLowRatio
            if face.meanLuma < t.minFaceLuma {
                e.light = .tooDark
            } else if face.meanLuma > t.maxFaceLuma {
                e.light = .tooBright
            } else if clipped > t.maxClippedRatio {
                e.light = face.clippedHighRatio >= face.clippedLowRatio ? .tooBright : .tooDark
            }
            if e.light != nil {
                e.failing[.light] = e.light == .tooDark ? .faceALight : .tooBright
            }
            // Sharpness is judged in every light (light no longer blocks).
            if face.sharpness < t.minFaceSharpness {
                e.failing[.sharpness] = .holdSteady
            }
        } else {
            e.failing[.light] = .faceALight
        }

        // 8. Eyes open (only when blendshapes are available).
        if let l = o.eyeBlinkLeft, let r = o.eyeBlinkRight, l >= t.maxEyeBlink || r >= t.maxEyeBlink {
            e.failing[.eyesOpen] = .eyesOpen
        }

        // 9. Stillness: landmark jitter / eye distance over 300 ms (not
        // during a challenge that asks for movement).
        if let challenge, !challenge.checksStillness {
            history.removeAll()
        } else if let d = o.eyeDistance, d > 0, !o.anchors.isEmpty {
            history.append((o.time, o.anchors, d))
            history.removeAll { o.time - $0.time > t.stillnessWindow }
            let jitter = Self.jitter(history.map(\.anchors)) / d
            e.jitter = jitter
            let span = (history.last?.time ?? 0) - (history.first?.time ?? 0)
            // Too little history to judge yet counts as not still.
            if jitter >= t.maxJitter || span < t.stillnessWindow * 0.6 {
                e.failing[.stillness] = .holdStill
            }
        } else {
            e.failing[.stillness] = .holdStill
        }

        // 2b (scan only). Change watch: a face region changed since a steady
        // baseline. Its baseline takes 3 consecutive frames where the face is
        // settled (found, still, in the oval, at the distance, facing
        // forward); motion wins over it (a moving frame doesn't count and
        // resets its 2-frame count, and the copy is "Hold still").
        let still = e.failing[.stillness] == nil
        let settled = still && e.failing[.faceFound] == nil && e.failing[.inFrame] == nil
            && e.failing[.distance] == nil && e.failing[.pose] == nil
        watchRan = false
        rebaselined = false
        if scanning && challenge == nil {
            if let since = lightChangedAt {
                // Light changed: ignore the watch while exposure settles, then
                // take a new baseline, but only on a face the segmenter says
                // is clear (or with no segmenter at all). Covered or no
                // result yet: wait, with the scan held.
                let segmenterClear = o.cover.map { !$0.covered } ?? !o.coverPending
                if o.time - since >= Self.lightSettle && segmenterClear {
                    coverWatch.reset()
                    rebaselined = lightChangedMidScan
                    lightChangedAt = nil
                    lightChangedMidScan = false
                } else if o.time - since >= Self.lightSettle {
                    e.failing[.stillness] = .holdStill
                }
            }
            if lightChangedAt == nil {
                let wasReady = coverWatch.baselineReady
                if coverWatch.covered(o.regions, still: still, settled: settled) {
                    e.failing[.covered] = .uncovered
                }
                watchRan = o.regions != nil
                if !wasReady, coverWatch.baselineReady, baselineWait == nil, let start = scanStartedAt {
                    baselineWait = o.time - start
                }
            }
        } else if let since = lightChangedAt, o.time - since >= Self.lightSettle, !lightChangedMidScan {
            lightChangedAt = nil   // settled before any scan started
        }

        // No covered-face result for this face yet: hold ("Hold still").
        if o.coverPending { e.failing[.stillness] = .holdStill }
        return e
    }

    /// Mean over anchors of the largest distance from that anchor's mean
    /// position in the window (normalised buffer units).
    static func jitter(_ samples: [[CGPoint]]) -> Double {
        guard let count = samples.first?.count, count > 0, samples.count > 1 else { return 0 }
        var total = 0.0
        for a in 0..<count {
            let points = samples.compactMap { a < $0.count ? $0[a] : nil }
            guard !points.isEmpty else { continue }
            let mx = points.reduce(0.0) { $0 + Double($1.x) } / Double(points.count)
            let my = points.reduce(0.0) { $0 + Double($1.y) } / Double(points.count)
            let maxDev = points.reduce(0.0) { max($0, hypot(Double($1.x) - mx, Double($1.y) - my)) }
            total += maxDev
        }
        return total / Double(count)
    }
}

// MARK: - Hint timing

/// Shows only the highest failing check; a check must fail for 400 ms before
/// its hint appears, and a hint stays up at least 1.2 s, so hints don't flicker.
struct HintScheduler: Sendable {
    var showDelay: TimeInterval = 0.4
    var minimumDisplay: TimeInterval = 1.2

    private var failingSince: [GateCheck: TimeInterval] = [:]
    private(set) var current: GateHint?
    private var shownAt: TimeInterval = -.infinity

    mutating func reset() {
        failingSince.removeAll()
        current = nil
        shownAt = -.infinity
    }

    mutating func update(failing: [GateCheck: GateHint], at time: TimeInterval) -> GateHint? {
        for check in failingSince.keys where failing[check] == nil { failingSince[check] = nil }
        for check in failing.keys where failingSince[check] == nil { failingSince[check] = time }

        let candidate = failing
            .filter { time - (failingSince[$0.key] ?? time) >= showDelay }
            .min { $0.key < $1.key }?.value

        if candidate != current, current == nil || time - shownAt >= minimumDisplay {
            current = candidate
            shownAt = time
        }
        return current
    }
}

// MARK: - Guide (gate + fill light + hint timing)

/// Combines the checks, the screen fill light and the hint timing. Fed once
/// per camera frame from the capture queue (not thread-safe by itself).
struct CaptureGuide: Sendable {
    var gate = QualityGate()
    var hints = HintScheduler()
    /// How long the fill light gets before "Face a light" is shown.
    var fillLightSettle: TimeInterval = 1.5

    private var darkSince: TimeInterval?
    private(set) var fillLightSince: TimeInterval?
    private(set) var lastEvaluation = QualityGate.Evaluation()

    mutating func reset(keepFillLight: Bool = false) {
        gate.reset()
        hints.reset()
        darkSince = nil
        if !keepFillLight { fillLightSince = nil }
    }

    /// - Parameter scanning: the scan is running: the distance band gets its
    ///   hold margin, and the hint names only a check that holds the scan.
    /// - Parameter challenge: a challenge is running: the gate uses its rules.
    mutating func update(_ o: GateObservation, scanning: Bool = false,
                         challenge: ChallengeGateRules? = nil) -> GuideSnapshot {
        // A challenge counts as scanning: distance hold margin, fill light
        // frozen, and the hint names only what holds the capture.
        let scanning = scanning || challenge != nil
        let e = gate.evaluate(o, scanning: scanning, challenge: challenge)
        let lightWasOn = fillLightSince != nil

        // Fill light first: once the face has been too dark for the hint
        // delay, the screen becomes a fill light. It stays on for the rest of
        // the capture (turning it off would make the face dark again).
        if e.light == .tooDark {
            if darkSince == nil { darkSince = o.time }
            // Frozen during a scan (COVER-v1): decided before it starts, no
            // toggle until it ends, so the change watch's baseline holds.
            if fillLightSince == nil, !scanning, let since = darkSince, o.time - since >= hints.showDelay {
                fillLightSince = o.time
            }
        } else {
            darkSince = nil
        }
        // The fill light works silently: while it settles the light check
        // gives no hint yet. Paused mid-scan, say what holds the scan, not
        // the light advice.
        var hintable = scanning ? e.blocking : e.failing
        if e.light == .tooDark, let since = fillLightSince, o.time - since < fillLightSettle {
            hintable[.light] = nil
        }
        lastEvaluation = e
        if (fillLightSince != nil) != lightWasOn { gate.lightChanged(at: o.time, scanning: scanning) }

        let hint = hints.update(failing: hintable, at: o.time)
        return GuideSnapshot(
            allPass: e.blocking.isEmpty,
            hint: hint,
            fillLight: fillLightSince != nil,
            failing: Set(e.failing.keys)
        )
    }
}

// MARK: - Geometry

/// The face oval, shared by the overlay and the gate so they agree on where
/// the oval is. Same size and offset the capture screens have always used.
enum CaptureOvalLayout {
    /// Capture kit SPEC: centre (0.5 W, 0.40 H), rx = 0.36 W, ry = 0.235 H.
    /// `scale` grows the oval about its centre (EVIDENCE-v1 closer step).
    static func ovalRect(in size: CGSize, scale: CGFloat = 1) -> CGRect {
        let rx = size.width * 0.36 * scale, ry = size.height * 0.235 * scale
        return CGRect(x: size.width * 0.5 - rx, y: size.height * 0.40 - ry, width: rx * 2, height: ry * 2)
    }
}

/// Maps normalised buffer coordinates (portrait, unmirrored) to the view's
/// points the way the aspect-fill, mirrored front-camera preview shows them.
struct PreviewMapper: Sendable {
    let bufferSize: CGSize
    let viewSize: CGSize
    var mirrored = true

    func viewPoint(x: Double, y: Double) -> CGPoint {
        guard bufferSize.width > 0, bufferSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / bufferSize.width, viewSize.height / bufferSize.height)
        let shownW = bufferSize.width * scale, shownH = bufferSize.height * scale
        let dx = (shownW - viewSize.width) / 2, dy = (shownH - viewSize.height) / 2
        let nx = mirrored ? 1 - x : x
        return CGPoint(x: CGFloat(nx) * shownW - dx, y: CGFloat(y) * shownH - dy)
    }

    /// Largest normalised ellipse radius of the points against `oval`.
    static func ovalExtent(of points: [CGPoint], in oval: CGRect) -> Double {
        let a = Double(oval.width / 2), b = Double(oval.height / 2)
        guard a > 0, b > 0 else { return .infinity }
        let cx = Double(oval.midX), cy = Double(oval.midY)
        var worst = 0.0
        for p in points {
            let nx = (Double(p.x) - cx) / a, ny = (Double(p.y) - cy) / b
            worst = max(worst, (nx * nx + ny * ny).squareRoot())
        }
        return worst
    }
}
