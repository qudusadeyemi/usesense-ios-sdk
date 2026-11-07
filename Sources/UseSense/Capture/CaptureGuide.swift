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
    case faceFound, onePerson, inFrame, distance, pose, light, sharpness, eyesOpen, stillness

    static func < (lhs: GateCheck, rhs: GateCheck) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Short label for the debug chips.
    var debugLabel: String {
        switch self {
        case .faceFound: return "face"
        case .onePerson: return "one"
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

/// One user-facing hint. Copy is shared with Android and web: keep it exact.
struct GateHint: Equatable, Sendable {
    enum Icon: String, Sendable { case face, people, centre, closer, back, pose, light, steady, eyes, still }

    let check: GateCheck
    let title: String
    let subtitle: String?
    let icon: Icon

    static let showFace = GateHint(check: .faceFound, title: "Show your face in the oval", subtitle: nil, icon: .face)
    static let onePerson = GateHint(check: .onePerson, title: "Only one person in view, please", subtitle: nil, icon: .people)
    static let centre = GateHint(check: .inFrame, title: "Move your face to the centre", subtitle: nil, icon: .centre)
    static let moveCloser = GateHint(check: .distance, title: "Move closer", subtitle: nil, icon: .closer)
    static let moveBack = GateHint(check: .distance, title: "Move back a little", subtitle: nil, icon: .back)
    static let lookStraight = GateHint(check: .pose, title: "Look straight at the screen", subtitle: nil, icon: .pose)
    static let brightening = GateHint(check: .light, title: "Brightening your screen",
                                      subtitle: "If it's still dark, face a window or lamp", icon: .light)
    static let faceALight = GateHint(check: .light, title: "Face a light", subtitle: nil, icon: .light)
    static let tooBright = GateHint(check: .light, title: "Move out of direct light", subtitle: nil, icon: .light)
    static let holdSteady = GateHint(check: .sharpness, title: "Hold the phone steady", subtitle: nil, icon: .steady)
    static let eyesOpen = GateHint(check: .eyesOpen, title: "Keep your eyes open", subtitle: nil, icon: .eyes)
    static let holdStill = GateHint(check: .stillness, title: "Hold still", subtitle: nil, icon: .still)
}

/// Pass thresholds. Starting points from the spec, to tune on session data.
struct GateThresholds: Sendable {
    var faceFoundFrames = 3
    /// Every landmark inside the oval shrunk by 4% of each radius.
    var ovalLimit = 0.96
    /// Iris-centre distance / frame width.
    var minEyeDistance = 0.17
    var maxEyeDistance = 0.30
    var maxYaw = 15.0
    var maxPitch = 15.0
    var maxRoll = 12.0
    var minFaceLuma: Float = 70
    var maxFaceLuma: Float = 200
    var maxClippedRatio: Float = 0.08
    /// Laplacian variance of the 96x96 face. The spec wants the per-device
    /// 20th percentile; until that table exists this is a fixed floor.
    var minFaceSharpness: Float = 12
    var maxEyeBlink = 0.6
    var stillnessWindow: TimeInterval = 0.3
    var maxJitter = 0.04
}

/// What the session measured on one camera frame.
struct GateObservation: Sendable {
    var time: TimeInterval
    /// Faces returned by the landmarker (0 = none).
    var faceCount: Int
    /// The largest normalised ellipse radius of any landmark against the
    /// on-screen oval (<= 1 = inside the drawn edge).
    var ovalExtent: Double?
    /// The face box is wider or taller than the oval (it can never fit).
    var faceLargerThanOval = false
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

    init(thresholds: GateThresholds = GateThresholds()) { self.thresholds = thresholds }

    mutating func reset() {
        faceStreak = 0
        history.removeAll()
    }

    /// Light failure direction for this frame, if any.
    enum LightFailure: Equatable, Sendable { case tooDark, tooBright }

    struct Evaluation: Equatable, Sendable {
        var failing: [GateCheck: GateHint] = [:]
        var light: LightFailure?
        /// The landmark jitter / eye distance over the window (debug).
        var jitter: Double?
    }

    mutating func evaluate(_ o: GateObservation) -> Evaluation {
        var e = Evaluation()
        let t = thresholds

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

        // 3. Fully inside the oval. A face bigger than the oval can never
        // fit, so that reads as distance ("Move back a little"), not centring
        // (same on Android).
        if (o.ovalExtent ?? .infinity) > t.ovalLimit {
            if o.faceLargerThanOval { e.failing[.distance] = .moveBack } else { e.failing[.inFrame] = .centre }
        }

        // 4. Distance.
        if let d = o.eyeDistance {
            if d < t.minEyeDistance { e.failing[.distance] = .moveCloser }
            else if d > t.maxEyeDistance { e.failing[.distance] = .moveBack }
        } else if e.failing[.distance] == nil {
            e.failing[.distance] = .moveCloser
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
            } else if face.sharpness < t.minFaceSharpness {
                // Blur is not judged on a badly lit face.
                e.failing[.sharpness] = .holdSteady
            }
        } else {
            e.failing[.light] = .faceALight
        }

        // 8. Eyes open (only when blendshapes are available).
        if let l = o.eyeBlinkLeft, let r = o.eyeBlinkRight, l >= t.maxEyeBlink || r >= t.maxEyeBlink {
            e.failing[.eyesOpen] = .eyesOpen
        }

        // 9. Stillness: landmark jitter / eye distance over 300 ms.
        if let d = o.eyeDistance, d > 0, !o.anchors.isEmpty {
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

    mutating func update(_ o: GateObservation) -> GuideSnapshot {
        var e = gate.evaluate(o)

        // Fill light first: once the face has been too dark for the hint
        // delay, the screen becomes a fill light. It stays on for the rest of
        // the capture (turning it off would make the face dark again).
        if e.light == .tooDark {
            if darkSince == nil { darkSince = o.time }
            if fillLightSince == nil, let since = darkSince, o.time - since >= hints.showDelay {
                fillLightSince = o.time
            }
        } else {
            darkSince = nil
        }
        if e.light == .tooDark, let since = fillLightSince {
            e.failing[.light] = o.time - since < fillLightSettle ? .brightening : .faceALight
        }
        lastEvaluation = e

        let hint = hints.update(failing: e.failing, at: o.time)
        return GuideSnapshot(
            allPass: e.failing.isEmpty,
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
    static func ovalRect(in size: CGSize) -> CGRect {
        let w = min(size.width * 0.70, size.height * 0.45, 320)
        let h = min(size.width * 0.93, size.height * 0.60, 420)
        let cy = size.height / 2 - size.height * 0.1
        return CGRect(x: size.width / 2 - w / 2, y: cy - h / 2, width: w, height: h)
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
