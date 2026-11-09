import XCTest
import CoreGraphics
@testable import UseSenseSDK

/// Covered-face check (capture test kit COVER-v1.md). Every fixture here is
/// synthetic: a drawn face area and a drawn "hand", no real faces.
final class FaceCoverTests: XCTestCase {

    // MARK: Synthetic face (720 x 1280 frame, image pixels)

    private let frame = CGSize(width: 720, height: 1280)
    private let centre = CGPoint(x: 360, y: 560)
    private let rx: CGFloat = 150, ry: CGFloat = 200

    /// 478 landmarks: the FACE_OVAL ring on an ellipse, the six watch anchors
    /// where a face has them, everything else at the centre.
    private func face() -> [CGPoint] {
        var p = [CGPoint](repeating: centre, count: 478)
        let ring = ContourDepthField.faceOvalRing
        for (i, k) in ring.enumerated() {
            let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(ring.count)
            p[k] = CGPoint(x: centre.x + rx * CGFloat(cos(a)), y: centre.y + ry * CGFloat(sin(a)))
        }
        p[234] = CGPoint(x: centre.x - rx, y: centre.y)
        p[454] = CGPoint(x: centre.x + rx, y: centre.y)
        p[151] = CGPoint(x: 360, y: 430)   // forehead
        p[50] = CGPoint(x: 290, y: 580)    // cheek
        p[280] = CGPoint(x: 430, y: 580)   // cheek
        p[5] = CGPoint(x: 360, y: 570)     // nose
        p[13] = CGPoint(x: 360, y: 660)    // mouth
        p[199] = CGPoint(x: 360, y: 715)   // chin
        return p
    }

    // MARK: Segmentation measure

    /// A 256 x 256 category mask: face skin everywhere, `paint` overrides.
    private func mask(_ paint: (CGPoint) -> UInt8?) -> [UInt8] {
        var m = [UInt8](repeating: FaceCover.faceSkin, count: 256 * 256)
        for my in 0..<256 {
            for mx in 0..<256 {
                let p = CGPoint(x: (CGFloat(mx) + 0.5) * frame.width / 256, y: (CGFloat(my) + 0.5) * frame.height / 256)
                if let c = paint(p) { m[my * 256 + mx] = c }
            }
        }
        return m
    }

    private func measure(_ m: [UInt8]) -> FaceCover? {
        FaceCover.measure(mask: { m[$0] }, mw: 256, mh: 256, imageSize: frame, points: face())
    }

    func testClearFaceReadsClear() {
        let c = measure(mask { _ in nil })
        XCTAssertEqual(c?.bodySkin, 0)
        XCTAssertEqual(c?.other, 0)
        XCTAssertEqual(c?.covered, false)
    }

    func testHandOverMouthAndChinIsCovered() {
        // Body skin over the lower third of the face.
        let c = measure(mask { $0.y > self.centre.y + 0.33 * self.ry ? FaceCover.bodySkinClass : nil })
        XCTAssertNotNil(c)
        XCTAssertGreaterThanOrEqual(c!.bodySkin, FaceCover.bodySkinMax)
        XCTAssertTrue(c!.covered)
    }

    func testObjectOverHalfTheFaceIsCovered() {
        // A phone / paper reads as "others" over the left half.
        let c = measure(mask { $0.x < self.centre.x ? FaceCover.others : nil })
        XCTAssertGreaterThanOrEqual(c!.other, FaceCover.otherMax)
        XCTAssertTrue(c!.covered)
    }

    func testHairAndEdgesDontCount() {
        // Hair over the forehead is fine; background just outside the
        // silhouette is excluded by the 85% shrink.
        let c = measure(mask { p in
            let nx = (p.x - self.centre.x) / self.rx, ny = (p.y - self.centre.y) / self.ry
            if nx * nx + ny * ny > 0.9 * 0.9 { return FaceCover.background }
            return p.y < self.centre.y - 0.5 * self.ry ? FaceCover.hair : nil
        })
        XCTAssertEqual(c!.other, 0, accuracy: 0.01)
        XCTAssertEqual(c!.bodySkin, 0)
        XCTAssertFalse(c!.covered)
    }

    func testCoverThresholds() {
        XCTAssertFalse(FaceCover(bodySkin: 0.11, other: 0.24).covered)
        XCTAssertTrue(FaceCover(bodySkin: 0.12, other: 0).covered)
        XCTAssertTrue(FaceCover(bodySkin: 0, other: 0.25).covered)
    }

    func testMeasureNeedsAFullMesh() {
        XCTAssertNil(FaceCover.measure(mask: { _ in 0 }, mw: 256, mh: 256, imageSize: frame, points: []))
    }

    // MARK: Change watch on a synthetic frame

    /// A BGRA frame: flat skin tone, optionally scaled (exposure) and with a
    /// drawn hand over the mouth and chin (lighter, with dark finger gaps).
    private func image(gain: Double = 1, hand: Bool = false) -> [UInt8] {
        let w = Int(frame.width), h = Int(frame.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var r = 190.0, g = 140.0, b = 115.0
                if hand, y >= 630, y <= 760, x >= 250, x <= 470 {
                    let gapBetweenFingers = (x - 250) % 28 < 4
                    (r, g, b) = gapBetweenFingers ? (90, 60, 50) : (235, 195, 175)
                }
                let i = (y * w + x) * 4
                px[i] = UInt8(min(255, b * gain))
                px[i + 1] = UInt8(min(255, g * gain))
                px[i + 2] = UInt8(min(255, r * gain))
                px[i + 3] = 255
            }
        }
        return px
    }

    private func regions(_ px: [UInt8]) -> FaceRegions? {
        px.withUnsafeBufferPointer {
            FaceRegions.measure(bgra: $0.baseAddress!, width: Int(frame.width), height: Int(frame.height),
                                bytesPerRow: Int(frame.width) * 4, points: face())
        }
    }

    func testRegionsMeasureSixPatches() {
        let r = regions(image())
        XCTAssertEqual(r?.regions.count, 6)
        for region in r!.regions {
            XCTAssertEqual(region.luma, 1, accuracy: 1e-4, "luma is relative to the face mean")
            XCTAssertEqual(region.edge, 0, accuracy: 1e-4, "flat skin has no edges")
            XCTAssertEqual(region.red, 190.0 / 445, accuracy: 1e-3)
        }
    }

    func testWatchCatchesAHandArrivingMidScan() {
        var watch = CoverWatch()
        let clear = regions(image())
        for _ in 0..<CoverWatch.baselineFrames { XCTAssertFalse(watch.covered(clear)) }
        XCTAssertFalse(watch.covered(clear), "unchanged face stays clear")
        let hand = regions(image(hand: true))
        XCTAssertFalse(watch.covered(hand), "one frame is not enough")
        XCTAssertGreaterThanOrEqual(watch.lastScore, 1)
        XCTAssertTrue(watch.covered(hand), "the drawn hand on a second frame trips the watch")
        let region = watch.lastCoveredRegion.map { FaceRegions.names[$0] }
        XCTAssertTrue(region == "mouth" || region == "chin", "\(region ?? "-")")
    }

    func testWatchIgnoresAGlobalBrightnessChange() {
        // The fill light coming on brightens every region alike.
        var watch = CoverWatch()
        let clear = regions(image())
        for _ in 0..<CoverWatch.baselineFrames { _ = watch.covered(clear) }
        XCTAssertFalse(watch.covered(regions(image(gain: 1.25))))
        XCTAssertLessThan(watch.lastScore, 1)
    }

    func testWatchNeedsItsBaselineFirst() {
        // A face covered from the first scan frame is the segmenter's job;
        // the watch only sees changes.
        var watch = CoverWatch()
        let covered = regions(image(hand: true))
        for _ in 0..<5 { XCTAssertFalse(watch.covered(covered)) }
    }

    // MARK: Two-frame rule (COVER-v1 s2)

    /// Six even regions, with region `r` (if any) pushed past the luma limit.
    private func frameWith(failing r: Int?) -> FaceRegions {
        var regs = Array(repeating: FaceRegions.Region(luma: 1, red: 0.42, blue: 0.26, edge: 6), count: 6)
        if let r { regs[r].luma = 1.3 }
        return FaceRegions(regions: regs)
    }

    private func baselined() -> CoverWatch {
        var w = CoverWatch()
        for _ in 0..<CoverWatch.baselineFrames { _ = w.covered(frameWith(failing: nil)) }
        return w
    }

    func testOneFailingFrameDoesNotPause() {
        var w = baselined()
        XCTAssertFalse(w.covered(frameWith(failing: 3)))
        XCTAssertFalse(w.covered(frameWith(failing: nil)))
        XCTAssertEqual(w.lastSingleFrameFlags, 1, "the one-frame exceedance is counted")
    }

    func testTwoFramesInARowOnTheSameRegionPause() {
        var w = baselined()
        XCTAssertFalse(w.covered(frameWith(failing: 4)))
        XCTAssertTrue(w.covered(frameWith(failing: 4)))
        XCTAssertEqual(w.lastCoveredRegion, 4)
        XCTAssertTrue(w.covered(frameWith(failing: 4)), "stays covered while it persists")
    }

    func testAlternatingRegionsDoNotPause() {
        var w = baselined()
        for i in 0..<6 {
            XCTAssertFalse(w.covered(frameWith(failing: i % 2 == 0 ? 3 : 5)), "frame \(i)")
        }
    }

    func testRegionCounterResetsOnAPass() {
        var w = baselined()
        XCTAssertFalse(w.covered(frameWith(failing: 0)))
        XCTAssertFalse(w.covered(frameWith(failing: nil)))
        XCTAssertFalse(w.covered(frameWith(failing: 0)), "the pass reset the count")
        XCTAssertTrue(w.covered(frameWith(failing: 0)))
    }

    // MARK: Gate

    private let goodFace = FaceRegionQuality(meanLuma: 130, clippedHighRatio: 0.01, clippedLowRatio: 0.0, sharpness: 80)
    private let anchors = [CGPoint(x: 0.5, y: 0.6), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5),
                           CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.5, y: 0.3)]

    private func good(at t: TimeInterval, _ edit: (inout GateObservation) -> Void = { _ in }) -> GateObservation {
        var o = GateObservation(time: t, faceCount: 1, ovalExtent: 0.8, eyeDistance: 0.22,
                                yaw: 2, pitch: -3, roll: 1, face: goodFace,
                                eyeBlinkLeft: 0.1, eyeBlinkRight: 0.1, anchors: anchors)
        o.cover = FaceCover(bodySkin: 0, other: 0)
        edit(&o)
        return o
    }

    private func run(_ guide: inout CaptureGuide, from t0: TimeInterval = 0, seconds: TimeInterval, scanning: Bool = false,
                     _ edit: (inout GateObservation) -> Void = { _ in }) -> GuideSnapshot {
        var last = GuideSnapshot.initial
        var t = t0
        while t <= t0 + seconds { last = guide.update(good(at: t, edit), scanning: scanning); t += 1.0 / 30 }
        return last
    }

    func testCoveredFaceBlocksWithItsHint() {
        var guide = CaptureGuide()
        let s = run(&guide, seconds: 1.5) { $0.cover = FaceCover(bodySkin: 0.5, other: 0) }
        XCTAssertFalse(s.allPass)
        XCTAssertTrue(s.failing.contains(.covered))
        XCTAssertEqual(s.hint, .uncovered)
        XCTAssertEqual(s.hint?.title, "Keep your face uncovered")
    }

    func testCoveredRanksAfterOnePersonBeforeDistance() {
        XCTAssertLessThan(GateCheck.onePerson, GateCheck.covered)
        XCTAssertLessThan(GateCheck.covered, GateCheck.distance)
        var guide = CaptureGuide()
        let s = run(&guide, seconds: 1.5) {
            $0.cover = FaceCover(bodySkin: 0.5, other: 0)
            $0.eyeDistance = 0.12   // also too far
        }
        XCTAssertEqual(s.hint, .uncovered)
    }

    func testNoCoverResultYetHolds() {
        var guide = CaptureGuide()
        let s = run(&guide, seconds: 1.5) { $0.cover = nil; $0.coverPending = true }
        XCTAssertFalse(s.allPass, "a scan can't start before the face was checked")
        XCTAssertEqual(s.hint, .holdStill)
        XCTAssertFalse(s.failing.contains(.covered))
    }

    func testCheckOffWhenSegmenterUnavailable() {
        // No model (or no MediaPipe): no result and not pending, so it passes.
        var guide = CaptureGuide()
        let s = run(&guide, seconds: 1.0) { $0.cover = nil; $0.coverPending = false }
        XCTAssertTrue(s.allPass)
    }

    // MARK: Fill light and the change watch (COVER-v1 s2)

    /// Feed scan frames from `t0` for `count` frames at 30 fps.
    private func feed(_ gate: inout QualityGate, from t0: TimeInterval, count: Int, regions: FaceRegions,
                      cover: FaceCover? = FaceCover(bodySkin: 0, other: 0)) -> [QualityGate.Evaluation] {
        (0..<count).map { i in
            let t = t0 + Double(i) / 30
            let e = gate.evaluate(good(at: t) { $0.regions = regions; $0.cover = cover }, scanning: true)
            return e
        }
    }

    func testNoFillLightToggleWhileScanning() {
        let dark = FaceRegionQuality(meanLuma: 30, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 80)
        var guide = CaptureGuide()
        let scanning = run(&guide, seconds: 2, scanning: true) { $0.face = dark }
        XCTAssertFalse(scanning.fillLight, "decided before the scan; no toggle during it")
        let aligning = run(&guide, from: 2.1, seconds: 1) { $0.face = dark }
        XCTAssertTrue(aligning.fillLight, "outside a scan the dark face still gets the light")
    }

    func testLightChangeRebaselinesAfterSettlingWhenClear() {
        var gate = QualityGate()
        let even = frameWith(failing: nil), noseLit = frameWith(failing: 3)
        _ = feed(&gate, from: 0, count: 6, regions: even)
        gate.lightChanged(at: 0.2, scanning: true)
        // The light brightened the nose for good: within 500 ms the watch is off.
        let settling = feed(&gate, from: 0.21, count: 12, regions: noseLit)
        XCTAssertTrue(settling.allSatisfy { $0.failing[.covered] == nil })
        XCTAssertFalse(gate.watchRan)
        // After 500 ms on a clear face: one new baseline, then no trip.
        var rebaselines = 0
        for i in 0..<15 {
            let e = gate.evaluate(good(at: 0.71 + Double(i) / 30) {
                $0.regions = noseLit; $0.cover = FaceCover(bodySkin: 0, other: 0)
            }, scanning: true)
            XCTAssertNil(e.failing[.covered], "frame \(i)")
            XCTAssertTrue(gate.watchRan)
            if gate.rebaselined { rebaselines += 1 }
        }
        XCTAssertEqual(rebaselines, 1)
    }

    func testLightChangeWhileCoveredWaits() {
        var gate = QualityGate()
        let even = frameWith(failing: nil), noseLit = frameWith(failing: 3)
        let hand = FaceCover(bodySkin: 0.4, other: 0)
        _ = feed(&gate, from: 0, count: 6, regions: even)
        gate.lightChanged(at: 0.2, scanning: true)
        let waiting = feed(&gate, from: 0.75, count: 10, regions: noseLit, cover: hand)
        XCTAssertFalse(gate.rebaselined, "no baseline on a covered face")
        XCTAssertTrue(waiting.allSatisfy { $0.failing[.stillness] != nil }, "the scan is held while it waits")
        // No segmenter result yet: still waits.
        _ = gate.evaluate(good(at: 1.2) { $0.regions = noseLit; $0.cover = nil; $0.coverPending = true }, scanning: true)
        XCTAssertFalse(gate.rebaselined)
        // Clear again: the baseline is taken now.
        _ = gate.evaluate(good(at: 1.3) { $0.regions = noseLit; $0.cover = FaceCover(bodySkin: 0, other: 0) }, scanning: true)
        XCTAssertTrue(gate.rebaselined)
    }

    func testBrightnessJumpWithoutLightChangeDoesNotRebaseline() {
        var gate = QualityGate()
        _ = feed(&gate, from: 0, count: 6, regions: frameWith(failing: nil))
        let after = feed(&gate, from: 0.3, count: 4, regions: frameWith(failing: 3))
        XCTAssertNotNil(after.last?.failing[.covered], "a lasting change still trips the watch")
        XCTAssertFalse(gate.rebaselined)
    }

    func testLightJustBeforeTheScanDelaysTheFirstBaseline() {
        var gate = QualityGate()
        gate.lightChanged(at: 0.0, scanning: false)
        _ = feed(&gate, from: 0.1, count: 3, regions: frameWith(failing: nil))
        XCTAssertFalse(gate.watchRan, "exposure still settling")
        _ = gate.evaluate(good(at: 0.6) { $0.regions = frameWith(failing: nil); $0.cover = FaceCover(bodySkin: 0, other: 0) }, scanning: true)
        XCTAssertTrue(gate.watchRan)
        XCTAssertFalse(gate.rebaselined, "the scan's first baseline is not a re-baseline")
    }

    func testChangeWatchPausesTheScan() {
        let clear = regions(image())
        let hand = regions(image(hand: true))
        var guide = CaptureGuide()
        XCTAssertTrue(run(&guide, seconds: 0.5, scanning: true) { $0.regions = clear }.allPass)
        XCTAssertTrue(guide.update(good(at: 0.6) { $0.regions = hand }, scanning: true).allPass,
                      "one frame is not enough")
        let s = guide.update(good(at: 0.633) { $0.regions = hand }, scanning: true)
        XCTAssertFalse(s.allPass, "a hand that stays a second frame pauses the scan")
        XCTAssertTrue(s.failing.contains(.covered))
        // Not scanning: the watch is off.
        var align = CaptureGuide()
        _ = run(&align, seconds: 0.5) { $0.regions = clear }
        _ = align.update(good(at: 0.6) { $0.regions = hand })
        XCTAssertFalse(align.update(good(at: 0.633) { $0.regions = hand }).failing.contains(.covered))
    }

    // MARK: One person

    func testOverlappingSecondFaceIsTheSameFace() {
        let subject = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let duplicate = CGRect(x: 0.32, y: 0.31, width: 0.38, height: 0.4)
        let someoneElse = CGRect(x: 0.75, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertGreaterThanOrEqual(FaceBoxes.iou(subject, duplicate), FaceBoxes.sameFaceIoU)
        XCTAssertEqual(FaceBoxes.distinctFaces([subject, duplicate], subject: 0), 1)
        XCTAssertEqual(FaceBoxes.distinctFaces([someoneElse, subject], subject: 1), 2)
        XCTAssertEqual(FaceBoxes.iou(subject, someoneElse), 0)
    }

    // MARK: Model

    func testBundledModelMatchesSpec() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/UseSense/Resources/selfie_multiclass_256x256.tflite")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(size, SegmenterModelInfo.sizeBytes)
    }
}
