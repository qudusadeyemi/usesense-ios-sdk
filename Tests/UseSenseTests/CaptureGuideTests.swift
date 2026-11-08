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

    func testContourFieldFollowsSpec() {
        // A face-sized blob of 478 points, nose (index 1) closest to the camera.
        let view = CGSize(width: 393, height: 852)
        var points = [CGPoint](repeating: .zero, count: 478)
        var z = [Double](repeating: 0, count: 478)
        for i in 0..<478 {
            let a = Double(i) * 2.399963, r = (Double(i) / 478).squareRoot()
            points[i] = CGPoint(x: 196 + 110 * r * cos(a), y: 340 + 150 * r * sin(a))
            z[i] = -0.08 * (1 - r * r)
        }
        points[10] = CGPoint(x: 196, y: 190)   // forehead
        points[152] = CGPoint(x: 196, y: 490)  // chin
        points[234] = CGPoint(x: 86, y: 340)   // cheeks
        points[454] = CGPoint(x: 306, y: 340)
        let field = ContourDepthField()
        for k in 0..<20 { field.update(points: points, z: z, viewSize: view, time: Double(k) / 30) }
        let snap = field.snapshot()
        XCTAssertTrue(snap.hasFace)
        XCTAssertEqual(snap.cols, 96)
        XCTAssertEqual(snap.rows, Int((96 * 852 / 393.0).rounded()))
        XCTAssertEqual(snap.faceHeight, 300, accuracy: 1)
        let centre = snap.sample(196, 340)
        XCTAssertGreaterThan(centre, 0.5)
        XCTAssertLessThanOrEqual(centre, 1)
        // The head dome lifts the hair above the forehead landmark.
        XCTAssertGreaterThan(snap.sample(196, 160), 0.05)
        // Flat far from the head.
        XCTAssertEqual(snap.sample(10, 820), 0, accuracy: 1e-4)
        // Face gone briefly: field kept; gone longer: dropped.
        field.noFace(at: 19.0 / 30 + 0.2)
        XCTAssertTrue(field.snapshot().hasFace)
        field.noFace(at: 19.0 / 30 + 0.5)
        XCTAssertFalse(field.snapshot().hasFace)
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
