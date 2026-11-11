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
            ("off centre", { $0.ovalExtent = 1.2; $0.faceCentreOffset = CGPoint(x: 0.3, y: 0) }, .inFrame, .centre),
            ("too far", { $0.eyeDistance = 0.12 }, .distance, .moveCloser),
            ("too close", { $0.eyeDistance = 0.33 }, .distance, .moveBack),
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

    func testInFrameSizeVersusPosition() {
        // Silhouette outside 1.10 x oval, face centred where expected: too close.
        var gate = QualityGate()
        var e = run(&gate, seconds: 0.5) { $0.ovalExtent = 1.2; $0.faceCentreOffset = CGPoint(x: 0.03, y: -0.05) }
        XCTAssertEqual(e.failing[.inFrame]?.title, "Move back a little")
        // Same overflow, face off to the side: centre it.
        gate = QualityGate()
        e = run(&gate, seconds: 0.5) { $0.ovalExtent = 1.2; $0.faceCentreOffset = CGPoint(x: 0.2, y: 0) }
        XCTAssertEqual(e.failing[.inFrame], .centre)
        // Within 1.15 passes (spec v1.2.2: the golden frame measures 1.12).
        gate = QualityGate()
        e = run(&gate, seconds: 0.5) { $0.ovalExtent = 1.12; $0.faceCentreOffset = .zero }
        XCTAssertNil(e.failing[.inFrame])
    }

    func testDistanceRunsBeforeInFrame() {
        XCTAssertLessThan(GateCheck.distance, GateCheck.inFrame)
        var s = HintScheduler()
        let failing: [GateCheck: GateHint] = [.inFrame: .centre, .distance: .moveBack]
        _ = s.update(failing: failing, at: 0)
        XCTAssertEqual(s.update(failing: failing, at: 0.5), .moveBack)
    }

    func testBlurIsJudgedInAnyLight() {
        var gate = QualityGate()
        let e = run(&gate, seconds: 0.5) {
            $0.face = FaceRegionQuality(meanLuma: 40, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 1)
        }
        XCTAssertNotNil(e.failing[.light])
        XCTAssertEqual(e.failing[.sharpness], .holdSteady)
    }

    func testLightIsAdviceAndNeverBlocks() {
        var gate = QualityGate()
        let e = run(&gate, seconds: 0.5) {
            $0.face = FaceRegionQuality(meanLuma: 50, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 80)
        }
        XCTAssertEqual(e.failing[.light], .faceALight)
        XCTAssertTrue(e.blocking.isEmpty, "\(e.blocking)")
    }

    func testDistanceHoldMarginWhileScanning() {
        // Entry band 0.17-0.32; once scanning 0.15-0.34.
        var gate = QualityGate()
        var e = run(&gate, seconds: 0.5) { $0.eyeDistance = 0.33 }
        XCTAssertEqual(e.failing[.distance], .moveBack)
        gate = QualityGate()
        var t = 0.0
        while t <= 0.5 { e = gate.evaluate(good(at: t) { $0.eyeDistance = 0.33 }, scanning: true); t += 1.0 / 30 }
        XCTAssertNil(e.failing[.distance])
        e = gate.evaluate(good(at: t) { $0.eyeDistance = 0.345 }, scanning: true)
        XCTAssertEqual(e.failing[.distance], .moveBack)
        e = gate.evaluate(good(at: t + 0.03) { $0.eyeDistance = 0.155 }, scanning: true)
        XCTAssertNil(e.failing[.distance])
        e = gate.evaluate(good(at: t + 0.06) { $0.eyeDistance = 0.145 }, scanning: true)
        XCTAssertEqual(e.failing[.distance], .moveCloser)
    }

    func testPausedScanHintSkipsLightAdvice() {
        var guide = CaptureGuide()
        let dark = FaceRegionQuality(meanLuma: 40, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 80)
        var t = 0.0
        var snap = GuideSnapshot.initial
        while t < 3.5 { snap = guide.update(good(at: t) { $0.face = dark; $0.yaw = 30 }, scanning: true); t += 1.0 / 30 }
        XCTAssertEqual(snap.hint, .lookStraight)
        XCTAssertFalse(snap.allPass)
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
        XCTAssertNil(snap.hint, "the fill light works silently while it settles")
        XCTAssertTrue(snap.allPass, "light is advice: a dark face doesn't block")
        while t < 3.2 { snap = guide.update(good(at: t) { $0.face = dark }); t += 1.0 / 30 }
        XCTAssertEqual(snap.hint, .faceALight, "still dark after the fill light settles")
        XCTAssertEqual(snap.hint?.title, "Find more light")
        XCTAssertEqual(snap.hint?.subtitle, "Face a window or lamp")
        // Light enough now: the fill light stays on (turning it off would undo it).
        while t < 5.0 { snap = guide.update(good(at: t)); t += 1.0 / 30 }
        XCTAssertTrue(snap.fillLight)
        XCTAssertTrue(snap.allPass)
        XCTAssertNil(snap.hint)
    }

    /// Device run (2026-11-11): a room too dark to find a face never turned
    /// the fill light on. The middle of the frame now decides when no face is found.
    func testNoFaceInADarkFrameTurnsOnFillLight() {
        var guide = CaptureGuide()
        var t = 0.0
        var snap = GuideSnapshot.initial
        func noFace(_ luma: Float?) -> GateObservation {
            var o = GateObservation.noFace(at: t); o.frameLuma = luma; return o
        }
        while t < 0.45 { snap = guide.update(noFace(25)); t += 1.0 / 30 }
        XCTAssertTrue(snap.fillLight, "dark frame, no face: fill light after the hint delay")
        while t < 1.5 { snap = guide.update(noFace(25)); t += 1.0 / 30 }
        XCTAssertNil(snap.hint, "silent while the light settles")
        while t < 3.5 { snap = guide.update(noFace(30)); t += 1.0 / 30 }
        XCTAssertEqual(snap.hint, .faceALight, "still no face in the dark: ask for light, not a face")

        // A bright frame with no face is just no face.
        var bright = CaptureGuide()
        t = 0
        while t < 2.0 { snap = bright.update(noFace(140)); t += 1.0 / 30 }
        XCTAssertFalse(snap.fillLight)
        XCTAssertEqual(snap.hint, .showFace)
        // No measurement: unchanged behaviour.
        var unknown = CaptureGuide()
        t = 0
        while t < 2.0 { snap = unknown.update(noFace(nil)); t += 1.0 / 30 }
        XCTAssertFalse(snap.fillLight)
    }

    func testDarkFrameDoesNotToggleTheFillLightDuringAScan() {
        var guide = CaptureGuide()
        var t = 0.0
        var snap = GuideSnapshot.initial
        while t < 1.0 {
            var o = GateObservation.noFace(at: t); o.frameLuma = 20
            snap = guide.update(o, scanning: true); t += 1.0 / 30
        }
        XCTAssertFalse(snap.fillLight, "frozen during a scan (COVER-v1)")
        XCTAssertEqual(snap.hint, .showFace, "a paused scan still says what holds it")
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

    func testScreenEyeDistanceUsesIrisCentres() {
        var p = [CGPoint](repeating: .zero, count: 478)
        p[468] = CGPoint(x: 100, y: 300); p[473] = CGPoint(x: 220, y: 300)
        XCTAssertEqual(UseSenseSession.screenEyeDistance(p) ?? 0, 120, accuracy: 1e-9)
        // Eye ratio on a 393 pt phone: oval width / 0.72 = screen width.
        let oval = CaptureOvalLayout.ovalRect(in: CGSize(width: 393, height: 852))
        XCTAssertEqual(oval.width / 0.72, 393, accuracy: 1e-6)
    }

    func testEyeDistanceUsesIrisCentres() {
        var lm = [(x: Double, y: Double, z: Double)](repeating: (0.5, 0.5, 0), count: 478)
        lm[468] = (0.40, 0.50, 0)
        lm[473] = (0.62, 0.50, 0)
        XCTAssertEqual(UseSenseSession.eyeDistance(lm, aspect: 16.0 / 9.0) ?? 0, 0.22, accuracy: 1e-9)
    }

    // MARK: Contour depth

    /// A 22 x 22 lattice of 484 points over the face box (478 used), nose
    /// bump in the middle, split into 2 triangles per cell.
    private func latticeFace(skipCentre: Bool = false) -> (points: [CGPoint], z: [Double], tris: [(Int, Int, Int)]) {
        let n = 22
        var points = [CGPoint](repeating: .zero, count: 478)
        var z = [Double](repeating: 0, count: 478)
        for i in 0..<478 {
            let gx = Double(i % n), gy = Double(i / n)
            points[i] = CGPoint(x: 86 + 220 * gx / Double(n - 1), y: 190 + 300 * gy / Double(n - 1))
            let dx = gx / Double(n - 1) - 0.5, dy = gy / Double(n - 1) - 0.5
            z[i] = -0.08 * max(0, 1 - 4 * (dx * dx + dy * dy))
        }
        var tris: [(Int, Int, Int)] = []
        for gy in 0..<(n - 1) {
            for gx in 0..<(n - 1) {
                let a = gy * n + gx, b = a + 1, c = a + n, d = c + 1
                guard d < 478 else { continue }
                if skipCentre, gx == 10, gy == 10 { continue }
                tris.append((a, b, c)); tris.append((b, d, c))
            }
        }
        return (points, z, tris)
    }

    /// The lattice with the bump's landmarks placed as on a face: forehead
    /// (10) at the top, chin (152) at the bottom, cheeks (234, 454) at the
    /// sides. Face box 220 x 300 at (86, 190).
    private func reliefFace() -> (points: [CGPoint], z: [Double], tris: [(Int, Int, Int)]) {
        var face = latticeFace()
        face.points[10] = CGPoint(x: 196, y: 190)
        face.points[152] = CGPoint(x: 196, y: 490)
        face.points[234] = CGPoint(x: 86, y: 340)
        face.points[454] = CGPoint(x: 306, y: 340)
        return face
    }

    private func settledField(_ face: (points: [CGPoint], z: [Double], tris: [(Int, Int, Int)]),
                              view: CGSize) -> ContourDepthField {
        let field = ContourDepthField()
        for k in 0..<24 {
            field.update(points: face.points, z: face.z, viewSize: view, time: Double(k) / 30, triangles: face.tris)
        }
        return field
    }

    func testReliefV31FieldsFollowSpec() {
        let view = CGSize(width: 393, height: 852)
        let field = settledField(reliefFace(), view: view)
        let snap = field.snapshot()
        XCTAssertTrue(snap.hasFace)
        XCTAssertEqual(snap.cols, 64)
        XCTAssertEqual(snap.rows, Int((64 * 852 / 393.0).rounded()))
        XCTAssertEqual(snap.detail.count, snap.field.count)
        // Bump centred 0.05 faceH below the 10/152 midpoint; displacement
        // scale ry 0.65 faceH.
        XCTAssertEqual(snap.bumpCy, 340 + 0.05 * 300, accuracy: 0.5)
        XCTAssertEqual(snap.bumpRy, 0.65 * 300, accuracy: 0.5)
        // Bulge is the bump alone: peak about 1, 0 beyond rx 0.58 faceW.
        let centre = snap.sample(196, 355)
        XCTAssertGreaterThan(centre, 0.9)
        XCTAssertLessThanOrEqual(centre, 1.0)
        XCTAssertEqual(snap.sample(196 + 0.58 * 220 + 20, 355), 0, accuracy: 0.02)
        // Taller above the centre (ry_up 0.85 faceH): 0.9 x 0.65 faceH above
        // is still inside the bump; the same distance below is outside it.
        XCTAssertGreaterThan(snap.sample(196, 355 - 0.9 * 195), 0.15)
        XCTAssertLessThan(snap.sample(196, 355 + 0.9 * 195), 0.1)
        // Detail: the nose (centre of the lattice face) stands out, 0 far away.
        XCTAssertGreaterThan(snap.sampleDetail(196, 340), 0.5)
        XCTAssertGreaterThan(snap.sampleDetail(196, 340) - snap.sampleDetail(100, 340), 0.3)
        XCTAssertEqual(snap.sampleDetail(10, 820), 0, accuracy: 1e-4)
        // Face gone briefly: fields kept; gone longer: dropped.
        field.noFace(at: 23.0 / 30 + 0.2)
        XCTAssertTrue(field.snapshot().hasFace)
        field.noFace(at: 23.0 / 30 + 0.5)
        XCTAssertFalse(field.snapshot().hasFace)
    }

    func testReliefV31FillsOpenings() {
        // No triangles over the middle (an "open mouth"): the detail is filled.
        let view = CGSize(width: 393, height: 852)
        var face = latticeFace(skipCentre: true)
        let clean = reliefFace()
        face.points = clean.points
        let snap = settledField(face, view: view).snapshot()
        XCTAssertGreaterThan(snap.sampleDetail(86 + 220 * 10.5 / 21, 190 + 300 * 10.5 / 21), 0.4)
    }

    func testTrianglesFromTessellationEdges() {
        let edges: [(start: Int, end: Int)] = [(1, 2), (2, 3), (3, 1), (4, 5), (5, 6), (6, 4), (7, 8)]
        let tris = ContourDepthField.triangles(fromEdges: edges)
        XCTAssertEqual(tris.count, 2)
        XCTAssertTrue(tris[0] == (1, 2, 3))
        XCTAssertTrue(tris[1] == (4, 5, 6))
    }

    func testContourLinesBulgeAndShowTheNose() {
        let view = CGSize(width: 393, height: 852)
        let snap = settledField(reliefFace(), view: view).snapshot()
        let lines = ContourScanView.layout(snap, size: view)
        XCTAssertEqual(ContourScanView.spacing, 9)
        XCTAssertEqual(ContourScanView.minGap, 2.5)
        let mid = Int((196 / ContourScanView.sampleStep).rounded())
        let side = lines.ys[0].count - 2   // right edge, beyond the bump
        var maxUp: CGFloat = 0, maxDown: CGFloat = 0
        for k in 0..<lines.ys.count {
            let y = lines.baseY[k], dy = lines.ys[k][mid] - y
            if y < snap.bumpCy - 20 { XCTAssertLessThanOrEqual(dy, 1e-6, "above the centre lines arch up") }
            maxUp = max(maxUp, -dy); maxDown = max(maxDown, dy)
            XCTAssertEqual(lines.ys[k][side], y, accuracy: 1.5, "flat beside the head")
            if k > 0 {
                for j in 0..<lines.ys[k].count {
                    XCTAssertGreaterThanOrEqual(lines.ys[k][j] - lines.ys[k - 1][j], ContourScanView.minGap - 1e-6)
                    XCTAssertEqual(lines.gaps[k][j], lines.ys[k][j] - lines.ys[k - 1][j], accuracy: 1e-6)
                }
            }
        }
        XCTAssertGreaterThan(maxUp, 30)
        XCTAssertGreaterThan(maxDown, 5, "lines below the face sag")
        // At the bump's centre the bulge is 0 (tanh 0), but the detail still
        // lifts the line over the nose: it shows where it is.
        let k = Int((snap.bumpCy / ContourScanView.spacing).rounded())
        let atNose = lines.baseY[k] - lines.ys[k][mid]
        let beside = lines.baseY[k] - lines.ys[k][Int((100 / ContourScanView.sampleStep).rounded())]
        XCTAssertGreaterThan(atNose, 8)
        XCTAssertGreaterThan(atNose - beside, 3)
    }

    func testPackedLinesFade() {
        let s = ContourScanView.spacing
        XCTAssertEqual(ContourScanView.packedFactor([s, s], 1), 1)
        XCTAssertEqual(ContourScanView.packedFactor([2 * s, s], 1), 1)
        XCTAssertEqual(ContourScanView.packedFactor([0, s], 1), 0.25)
        XCTAssertEqual(ContourScanView.packedFactor([s / 2, s], 1), 0.65, accuracy: 0.026)
    }

    func testOvalMatchesSpec() {
        let r = CaptureOvalLayout.ovalRect(in: CGSize(width: 393, height: 852))
        XCTAssertEqual(r.midX, 196.5, accuracy: 0.01)
        XCTAssertEqual(r.midY, 340.8, accuracy: 0.01)
        XCTAssertEqual(r.width / 2, 393 * 0.36, accuracy: 0.01)
        XCTAssertEqual(r.height / 2, 852 * 0.235, accuracy: 0.01)
    }

    func testGuidanceCopyIsSpecV1_1() {
        XCTAssertEqual(GateHint.holdStill.title, "Hold still")
        XCTAssertEqual(GateHint.centre.title, "Move your face to the centre")
        XCTAssertEqual(GateHint.moveCloser.title, "Move a little closer")
        XCTAssertEqual(GateHint.moveBack.title, "Move back a little")
        XCTAssertEqual(GateHint.lookStraight.title, "Look straight ahead")
        XCTAssertEqual(GateHint.faceALight.title, "Find more light")
        XCTAssertEqual(GateHint.tooBright.title, "Too much light behind you")
        XCTAssertEqual(GateHint.tooBright.subtitle, "Turn away from the window")
        XCTAssertEqual(GateHint.holdSteady.title, "Hold your phone steady")
        XCTAssertEqual(GateHint.eyesOpen.title, "Keep your eyes open")
        XCTAssertEqual(GateHint.onePerson.title, "Only you in the picture")
        XCTAssertEqual(GateHint.showFace.title, "Show your face in the oval")
    }

    // MARK: Colours

    func testCaptureColoursDefaultsAndContrastFallback() {
        let d = CaptureColors.resolve(nil)
        XCTAssertEqual(d, .default)
        XCTAssertEqual(d.ring, CaptureColors.RGB(hex: 0x4F7CFF))
        // A readable brand colour is used.
        let custom = CaptureColors.resolve(FlowAppearance(capture: AppearanceCapture(ring: "#00D4AA")))
        XCTAssertEqual(custom.ring, CaptureColors.RGB(hex: 0x00D4AA))
        // Navy on the dark scrim is under 3:1: back to the default (no primary set).
        XCTAssertLessThan(CaptureColors.RGB(hex: 0x1A237E).contrast(against: CaptureColors.scrim), 3)
        let navy = CaptureColors.resolve(FlowAppearance(capture: AppearanceCapture(ring: "#1A237E", contourStart: "nope", warning: "#FF0000")))
        XCTAssertEqual(navy.ring, CaptureColors.default.ring)
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

final class UploadBarTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testBarKeepsMovingWhileTheServerChecks() {
        var bar = UploadBar.start(at: t0)
        XCTAssertEqual(bar.value(at: t0), UploadBar.floor, accuracy: 1e-9)
        // Upload accepted after 2.3 s (device trace), then a 6.7 s check.
        let accepted = t0.addingTimeInterval(2.3)
        let sent = bar.value(at: accepted)
        XCTAssertGreaterThan(sent, 0.4)
        XCTAssertLessThan(sent, UploadBar.sendingCap)
        bar = bar.advanced(to: .checking, at: accepted)
        XCTAssertEqual(bar.value(at: accepted), sent, accuracy: 1e-9, "no jump between stages")
        var last = sent
        for s in stride(from: 1.0, through: 7.0, by: 1.0) {
            let v = bar.value(at: accepted.addingTimeInterval(s))
            XCTAssertGreaterThan(v - last, 0.005, "still visibly moving at \(s) s")
            last = v
        }
        XCTAssertLessThan(bar.value(at: accepted.addingTimeInterval(60)), UploadBar.checkingCap)
        XCTAssertEqual(bar.advanced(to: .done, at: accepted).value(at: accepted), 1)
    }

    func testBarNeverGoesBack() {
        let bar = UploadBar.start(at: t0).advanced(to: .checking, at: t0.addingTimeInterval(1))
        let back = bar.advanced(to: .sending, at: t0.addingTimeInterval(2))
        XCTAssertEqual(back, bar)
    }
}
