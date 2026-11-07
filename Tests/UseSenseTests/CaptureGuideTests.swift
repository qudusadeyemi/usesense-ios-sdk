import XCTest
@testable import UseSenseSDK

final class CaptureGuideTests: XCTestCase {

    // MARK: Fixtures

    private let goodFace = FaceRegionQuality(meanLuma: 130, clippedHighRatio: 0.01, clippedLowRatio: 0.0, sharpness: 80)
    private let anchors = [CGPoint(x: 0.5, y: 0.6), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5),
                           CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.5, y: 0.3)]

    private func good(at t: TimeInterval, _ edit: (inout GateObservation) -> Void = { _ in }) -> GateObservation {
        var o = GateObservation(time: t, faceCount: 1, ovalExtent: 0.8, eyeDistance: 0.22,
                                yaw: 2, pitch: -3, roll: 1, face: goodFace,
                                eyeBlinkLeft: 0.1, eyeBlinkRight: 0.1, anchors: anchors)
        edit(&o)
        return o
    }

    /// Feed `seconds` of frames at 30 fps; returns the last evaluation.
    @discardableResult
    private func run(_ gate: inout QualityGate, from t0: TimeInterval = 0, seconds: TimeInterval,
                     _ edit: (inout GateObservation) -> Void = { _ in }) -> QualityGate.Evaluation {
        var last = QualityGate.Evaluation()
        var t = t0
        while t <= t0 + seconds { last = gate.evaluate(good(at: t, edit)); t += 1.0 / 30 }
        return last
    }

    // MARK: Gate checks

    func testGoodFacePassesOnceStillnessWindowFills() {
        var gate = QualityGate()
        XCTAssertFalse(gate.evaluate(good(at: 0)).failing.isEmpty, "1 frame is not 3 in a row")
        let e = run(&gate, from: 1.0 / 30, seconds: 0.4)
        XCTAssertTrue(e.failing.isEmpty, "\(e.failing)")
    }

    func testNoFaceShowsShowFace() {
        var gate = QualityGate()
        let e = gate.evaluate(.noFace(at: 0))
        XCTAssertEqual(e.failing.min { $0.key < $1.key }?.value, .showFace)
        XCTAssertEqual(Set(e.failing.keys), Set(GateCheck.allCases))
    }

    func testEachCheckFailsWithItsCopy() {
        let cases: [(String, (inout GateObservation) -> Void, GateCheck, GateHint)] = [
            ("second face", { $0.faceCount = 2 }, .onePerson, .onePerson),
            ("off centre", { $0.ovalExtent = 1.0 }, .inFrame, .centre),
            ("too far", { $0.eyeDistance = 0.12 }, .distance, .moveCloser),
            ("too close", { $0.eyeDistance = 0.34 }, .distance, .moveBack),
            ("yaw", { $0.yaw = 16 }, .pose, .lookStraight),
            ("pitch", { $0.pitch = -15 }, .pose, .lookStraight),
            ("roll", { $0.roll = 12.5 }, .pose, .lookStraight),
            ("dark", { $0.face = FaceRegionQuality(meanLuma: 50, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 80) }, .light, .faceALight),
            ("bright", { $0.face = FaceRegionQuality(meanLuma: 220, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 80) }, .light, .tooBright),
            ("clipped", { $0.face = FaceRegionQuality(meanLuma: 150, clippedHighRatio: 0.09, clippedLowRatio: 0, sharpness: 80) }, .light, .tooBright),
            ("blurry", { $0.face = FaceRegionQuality(meanLuma: 130, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 3) }, .sharpness, .holdSteady),
            ("blink", { $0.eyeBlinkLeft = 0.7 }, .eyesOpen, .eyesOpen),
        ]
        for (name, edit, check, hint) in cases {
            var gate = QualityGate()
            let e = run(&gate, seconds: 0.5, edit)
            XCTAssertEqual(e.failing[check], hint, name)
            XCTAssertEqual(e.failing.count, 1, "\(name): only \(check) should fail, got \(e.failing)")
        }
    }

    func testFaceBiggerThanOvalReadsAsMoveBack() {
        var gate = QualityGate()
        let e = run(&gate, seconds: 0.5) { $0.ovalExtent = 1.2; $0.faceLargerThanOval = true }
        XCTAssertEqual(e.failing[.distance], .moveBack)
        XCTAssertNil(e.failing[.inFrame])
    }

    func testBlurIsNotJudgedOnADarkFace() {
        var gate = QualityGate()
        let e = run(&gate, seconds: 0.5) {
            $0.face = FaceRegionQuality(meanLuma: 40, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 1)
        }
        XCTAssertNotNil(e.failing[.light])
        XCTAssertNil(e.failing[.sharpness])
    }

    func testMissingBlendshapesSkipsEyesCheck() {
        var gate = QualityGate()
        let e = run(&gate, seconds: 0.5) { $0.eyeBlinkLeft = nil; $0.eyeBlinkRight = nil }
        XCTAssertTrue(e.failing.isEmpty)
    }

    func testStillnessFailsOnMovementAndRecovers() {
        var gate = QualityGate()
        run(&gate, seconds: 0.5)
        // Head drifting 0.02 of frame width per frame: far past 0.04 x eye distance.
        var t = 0.5
        var e = QualityGate.Evaluation()
        for i in 0..<9 {
            let dx = CGFloat(i) * 0.02
            e = gate.evaluate(good(at: t) { o in o.anchors = self.anchors.map { CGPoint(x: $0.x + dx, y: $0.y) } })
            t += 1.0 / 30
        }
        XCTAssertEqual(e.failing[.stillness], .holdStill)
        XCTAssertGreaterThan(e.jitter ?? 0, 0.04)
        // Still again at the new spot for 300 ms.
        e = run(&gate, from: t, seconds: 0.4) { o in o.anchors = self.anchors.map { CGPoint(x: $0.x + 0.16, y: $0.y) } }
        XCTAssertNil(e.failing[.stillness])
    }

    func testJitterIsMeanOfPerAnchorMaxDeviation() {
        let a = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        let b = [CGPoint(x: 0.2, y: 0), CGPoint(x: 1, y: 1)]
        // Anchor 0 mean x 0.1, max dev 0.1; anchor 1 dev 0 => 0.05.
        XCTAssertEqual(QualityGate.jitter([a, b]), 0.05, accuracy: 1e-9)
    }

    // MARK: Hint timing

    func testHintWaits400msAndStays1_2s() {
        var s = HintScheduler()
        XCTAssertNil(s.update(failing: [.stillness: .holdStill], at: 0))
        XCTAssertNil(s.update(failing: [.stillness: .holdStill], at: 0.39))
        XCTAssertEqual(s.update(failing: [.stillness: .holdStill], at: 0.4), .holdStill)
        // Fixed right away: still shown until 1.2 s after it appeared.
        XCTAssertEqual(s.update(failing: [:], at: 0.5), .holdStill)
        XCTAssertEqual(s.update(failing: [:], at: 1.59), .holdStill)
        XCTAssertNil(s.update(failing: [:], at: 1.6))
    }

    func testFlickeringFailureNeverShows() {
        var s = HintScheduler()
        var t = 0.0
        for i in 0..<20 {
            XCTAssertNil(s.update(failing: i % 2 == 0 ? [.pose: .lookStraight] : [:], at: t))
            t += 0.3
        }
    }

    func testOnlyHighestPriorityHintShows() {
        var s = HintScheduler()
        let failing: [GateCheck: GateHint] = [.stillness: .holdStill, .inFrame: .centre, .light: .faceALight]
        _ = s.update(failing: failing, at: 0)
        XCTAssertEqual(s.update(failing: failing, at: 0.5), .centre)
        // Centre fixed: the next one waits out the 1.2 s minimum.
        let rest: [GateCheck: GateHint] = [.stillness: .holdStill, .light: .faceALight]
        XCTAssertEqual(s.update(failing: rest, at: 1.0), .centre)
        XCTAssertEqual(s.update(failing: rest, at: 1.7), .faceALight)
    }

    // MARK: Fill light

    func testDarkFaceTurnsOnFillLightBeforeTheHint() {
        var guide = CaptureGuide()
        let dark = FaceRegionQuality(meanLuma: 40, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 50)
        var t = 0.0
        var snap = GuideSnapshot.initial
        while t < 0.45 { snap = guide.update(good(at: t) { $0.face = dark }); t += 1.0 / 30 }
        XCTAssertTrue(snap.fillLight, "fill light comes on after 400 ms of dark")
        while t < 1.0 { snap = guide.update(good(at: t) { $0.face = dark }); t += 1.0 / 30 }
        XCTAssertEqual(snap.hint, .brightening)
        XCTAssertEqual(snap.hint?.subtitle, "If it's still dark, face a window or lamp")
        while t < 3.2 { snap = guide.update(good(at: t) { $0.face = dark }); t += 1.0 / 30 }
        XCTAssertEqual(snap.hint, .faceALight, "still dark after the fill light settles")
        // Light enough now: the fill light stays on (turning it off would undo it).
        while t < 5.0 { snap = guide.update(good(at: t)); t += 1.0 / 30 }
        XCTAssertTrue(snap.fillLight)
        XCTAssertTrue(snap.allPass)
        XCTAssertNil(snap.hint)
    }

    // MARK: Pose from the transformation matrix

    private func rotation(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) -> (Int, Int) -> Double {
        let (y, p, r) = (yaw * .pi / 180, pitch * .pi / 180, roll * .pi / 180)
        let rz = [[cos(r), -sin(r), 0], [sin(r), cos(r), 0], [0, 0, 1.0]]
        let ry = [[cos(y), 0, sin(y)], [0, 1.0, 0], [-sin(y), 0, cos(y)]]
        let rx = [[1.0, 0, 0], [0, cos(p), -sin(p)], [0, sin(p), cos(p)]]
        func mul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
            (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
        }
        let m = mul(mul(rz, ry), rx)
        return { m[$0][$1] }
    }

    func testZYXPoseLabelsAxesPhysically() {
        let p = FaceMeshManager.zyxPose(rotation(yaw: 12, pitch: -7, roll: 5))
        XCTAssertEqual(p.yaw, 12, accuracy: 1e-6, "head turn = about Y")
        XCTAssertEqual(p.pitch, -7, accuracy: 1e-6, "nod = about X")
        XCTAssertEqual(p.roll, 5, accuracy: 1e-6, "tilt = about Z")
        let id = FaceMeshManager.zyxPose(rotation())
        XCTAssertEqual(id.yaw, 0, accuracy: 1e-9)
        XCTAssertEqual(id.pitch, 0, accuracy: 1e-9)
        XCTAssertEqual(id.roll, 0, accuracy: 1e-9)
    }

    // MARK: Geometry

    func testPreviewMapperMirrorsAndCropsLikeAspectFill() {
        // 720x1280 buffer on a 390x844 view: scale 0.659, shown 474.8 wide, 42.4 cropped each side.
        let m = PreviewMapper(bufferSize: CGSize(width: 720, height: 1280), viewSize: CGSize(width: 390, height: 844))
        let centre = m.viewPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(centre.x, 195, accuracy: 0.01)
        XCTAssertEqual(centre.y, 422, accuracy: 0.01)
        let left = m.viewPoint(x: 0.25, y: 0.5)
        XCTAssertGreaterThan(left.x, 195, "unmirrored buffer left = preview right")
    }

    func testOvalExtent() {
        let oval = CGRect(x: 0, y: 0, width: 200, height: 300)
        XCTAssertEqual(PreviewMapper.ovalExtent(of: [CGPoint(x: 100, y: 150)], in: oval), 0, accuracy: 1e-9)
        XCTAssertEqual(PreviewMapper.ovalExtent(of: [CGPoint(x: 200, y: 150)], in: oval), 1, accuracy: 1e-9)
        XCTAssertEqual(PreviewMapper.ovalExtent(of: [CGPoint(x: 100, y: 0), CGPoint(x: 150, y: 150)], in: oval), 1, accuracy: 1e-9)
    }

    func testEyeDistanceUsesIrisCentres() {
        var lm = [(x: Double, y: Double, z: Double)](repeating: (0.5, 0.5, 0), count: 478)
        lm[468] = (0.40, 0.50, 0)
        lm[473] = (0.62, 0.50, 0)
        XCTAssertEqual(UseSenseSession.eyeDistance(lm, aspect: 16.0 / 9.0) ?? 0, 0.22, accuracy: 1e-9)
    }

    // MARK: Contour depth

    func testContourFieldRaisesTheNose() {
        let field = ContourDepthField()
        var points: [CGPoint] = []
        var z: [Double] = []
        for j in 0..<20 {
            for i in 0..<20 {
                let x = Double(i) / 19, y = Double(j) / 19
                points.append(CGPoint(x: 100 + x * 200, y: 100 + y * 260))
                // A dome: centre closest to the camera (most negative z).
                z.append(-0.1 * max(0, 1 - ((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5)) * 4))
            }
        }
        field.update(points: points, z: z)
        let snap = field.snapshot()
        XCTAssertTrue(snap.hasFace)
        let centre = snap.sample(CGPoint(x: 200, y: 230))
        let edge = snap.sample(CGPoint(x: 110, y: 110))
        XCTAssertGreaterThan(centre.depth, edge.depth)
        XCTAssertGreaterThan(centre.mask, 0.5)
        XCTAssertEqual(snap.sample(CGPoint(x: 10, y: 10)).mask, 0, "off the face")
    }

    // MARK: Colours

    func testCaptureColoursDefaultsAndContrastFallback() {
        let d = CaptureColors.resolve(nil)
        XCTAssertEqual(d, .default)
        XCTAssertEqual(d.ring, CaptureColors.RGB(hex: 0x4F7CFF))
        // A readable brand colour is used.
        let custom = CaptureColors.resolve(AppearanceCapture(ring: "#00D4AA"))
        XCTAssertEqual(custom.ring, CaptureColors.RGB(hex: 0x00D4AA))
        // Navy on the dark scrim is under 3:1: back to the default.
        XCTAssertLessThan(CaptureColors.RGB(hex: 0x1A237E).contrast(against: CaptureColors.scrim), 3)
        let navy = CaptureColors.resolve(AppearanceCapture(ring: "#1A237E", contourStart: "nope", warning: "#FF0000"))
        XCTAssertEqual(navy.ring, CaptureColors.default.ring)
        XCTAssertEqual(navy.contourStart, CaptureColors.default.contourStart)
        XCTAssertEqual(navy.warning, CaptureColors.RGB(hex: 0xFF0000))
    }

    func testCaptureAppearanceDecodesBothKeyStylesAndMerges() throws {
        let camel = FlowAppearance.decodeFromJSONObject(["capture": ["ring": "#111111", "contourStart": "#222222"]])
        XCTAssertEqual(camel?.capture?.contourStart, "#222222")
        let snake = FlowAppearance.decodeFromJSONObject(["capture": ["contour_start": "#333333", "contour_end": "#444444"]])
        XCTAssertEqual(snake?.capture?.contourStart, "#333333")
        XCTAssertEqual(snake?.capture?.contourEnd, "#444444")
        let merged = FlowAppearance.merge(high: camel, low: snake)
        XCTAssertEqual(merged?.capture?.ring, "#111111")
        XCTAssertEqual(merged?.capture?.contourStart, "#222222", "high wins")
        XCTAssertEqual(merged?.capture?.contourEnd, "#444444", "low shows through")
        // Round-trip writes camelCase.
        let data = try JSONEncoder().encode(merged)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("contourEnd"))
    }

    // MARK: Flag

    func testGuidedCaptureIsOnByDefaultAndCanBeTurnedOff() {
        XCTAssertTrue(SDKOptions().guidedCaptureEnabled)
        let on = UseSenseSession(config: UseSenseConfig(apiKey: "k"), sessionType: .enrollment)
        XCTAssertTrue(on.guidedCapture)
        var config = UseSenseConfig(apiKey: "k")
        config.options = SDKOptions(guidedCaptureEnabled: false)
        XCTAssertFalse(UseSenseSession(config: config, sessionType: .enrollment).guidedCapture)
    }
}
