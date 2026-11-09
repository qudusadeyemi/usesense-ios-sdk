import XCTest
@testable import UseSenseSDK

/// `metadata.covered_check` must match capture test kit COVER-v1.md section 3
/// field for field (Android sends the same object; the server stores it whole).
final class CoverCheckReportTests: XCTestCase {

    private let split: [Float] = [0.0, 0.03, 0.0, 0.96, 0.0, 0.01]
    private let loaded = FaceCoverSegmenter.Stats(loaded: true, loadMs: 410, loadError: nil,
                                                 runMs: [930, 880, 1210, 900])

    private func cover(_ c: [Float]) -> FaceCover {
        FaceCover(bodySkin: c[2], other: c[0] + c[4] + c[5], classes: c)
    }

    /// Serialised and parsed back, as the server sees it.
    private func roundTrip(_ report: CoverCheckReport, _ stats: FaceCoverSegmenter.Stats) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["covered_check": report.json(segmenter: stats)])
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(parsed?["covered_check"] as? [String: Any])
    }

    private func fullReport() -> CoverCheckReport {
        var r = CoverCheckReport()
        r.alignCovered(seconds: 0.5)
        r.scanStarted(cover: cover(split), ageMs: 640)
        var watch = CoverWatch()
        let same = FaceRegions(regions: Array(repeating: .init(luma: 1, red: 0.42, blue: 0.26, edge: 6), count: 6))
        for _ in 0..<CoverWatch.baselineFrames { _ = watch.covered(same) }
        var moved = same
        var blip = same
        blip.regions[3] = .init(luma: 1.25, red: 0.42, blue: 0.26, edge: 6)  // nose, one frame only
        _ = watch.covered(blip)
        r.scanFrame(cover: nil, watch: watch)
        _ = watch.covered(same)
        r.scanFrame(cover: nil, watch: watch)
        moved.regions[4] = .init(luma: 1.4, red: 0.5, blue: 0.2, edge: 30)   // mouth, two frames
        _ = watch.covered(moved)
        r.scanFrame(cover: nil, watch: watch)
        _ = watch.covered(moved)
        r.scanFrame(cover: cover([0, 0.02, 0.3, 0.6, 0, 0.08]), watch: watch)
        r.finalCheck(cover: cover(split), waitedMs: 380, outcome: .clear)
        return r
    }

    func testFieldNamesMatchTheSpec() throws {
        let j = try roundTrip(fullReport(), loaded)
        XCTAssertEqual(Set(j.keys), [
            "version", "model_sha256_prefix", "model_load_ms", "model_error", "limits",
            "runs", "run_ms_p50", "run_ms_max", "at_scan_start", "scan_max", "final",
            "align_covered_ms", "scan_drops", "change_watch",
        ])
        let six: Set<String> = ["bg", "hair", "body_skin", "face_skin", "clothes", "others"]
        XCTAssertEqual(Set((j["limits"] as? [String: Any])?.keys ?? [:].keys), ["body_skin", "other", "shrink"])
        XCTAssertEqual(Set((j["at_scan_start"] as? [String: Any])?.keys ?? [:].keys), six.union(["age_ms"]))
        XCTAssertEqual(Set((j["scan_max"] as? [String: Any])?.keys ?? [:].keys), ["body_skin", "other"])
        XCTAssertEqual(Set((j["final"] as? [String: Any])?.keys ?? [:].keys), six.union(["waited_ms", "outcome"]))
        let watch = try XCTUnwrap(j["change_watch"] as? [String: Any])
        XCTAssertEqual(Set(watch.keys), ["trips", "single_frame_flags", "max", "trip_regions"])
        XCTAssertEqual(Set((watch["max"] as? [String: Any])?.keys ?? [:].keys),
                       ["luma_ratio_delta", "chroma_delta", "edge_factor"])
    }

    func testValues() throws {
        let j = try roundTrip(fullReport(), loaded)
        XCTAssertEqual(j["version"] as? String, "cover-v1")
        XCTAssertEqual(j["model_sha256_prefix"] as? String, "c6748b12")
        XCTAssertEqual(j["model_load_ms"] as? Int, 410)
        XCTAssertTrue(j["model_error"] is NSNull)
        XCTAssertEqual((j["limits"] as? [String: Any])?["body_skin"] as? Double, 0.12)
        XCTAssertEqual((j["limits"] as? [String: Any])?["other"] as? Double, 0.25)
        XCTAssertEqual((j["limits"] as? [String: Any])?["shrink"] as? Double ?? 0, 0.85, accuracy: 1e-6)
        XCTAssertEqual(j["runs"] as? Int, 4)
        XCTAssertEqual(j["run_ms_p50"] as? Int, 930)
        XCTAssertEqual(j["run_ms_max"] as? Int, 1210)
        let start = try XCTUnwrap(j["at_scan_start"] as? [String: Any])
        XCTAssertEqual(start["face_skin"] as? Double, 0.96)
        XCTAssertEqual(start["age_ms"] as? Int, 640)
        let scanMax = try XCTUnwrap(j["scan_max"] as? [String: Any])
        XCTAssertEqual(scanMax["body_skin"] as? Double, 0.3)
        XCTAssertEqual(scanMax["other"] as? Double, 0.08)
        let final = try XCTUnwrap(j["final"] as? [String: Any])
        XCTAssertEqual(final["outcome"] as? String, "clear")
        XCTAssertEqual(final["waited_ms"] as? Int, 380)
        XCTAssertEqual(j["align_covered_ms"] as? Int, 500)
        XCTAssertEqual(j["scan_drops"] as? Int, 0)
        let watch = try XCTUnwrap(j["change_watch"] as? [String: Any])
        XCTAssertEqual(watch["trips"] as? Int, 1, "only the two-frame mouth change paused")
        XCTAssertEqual(watch["single_frame_flags"] as? Int, 1, "the nose blip")
        XCTAssertEqual(watch["trip_regions"] as? [String], ["mouth"])
        let max = try XCTUnwrap(watch["max"] as? [String: Any])
        XCTAssertEqual(max["luma_ratio_delta"] as? Double ?? 0, 0.4, accuracy: 1e-3)
        XCTAssertEqual(max["chroma_delta"] as? Double ?? 0, 0.08, accuracy: 1e-3)
        XCTAssertEqual(max["edge_factor"] as? Double ?? 0, 34.0 / 10.0, accuracy: 1e-3)
    }

    func testNoModelReportsNullsAndSkippedFinal() throws {
        var r = CoverCheckReport()
        r.scanStarted(cover: nil, ageMs: nil)
        r.finalCheck(cover: nil, waitedMs: 0, outcome: .skipped)
        let failed = FaceCoverSegmenter.Stats(loaded: false, loadMs: nil, loadError: "model not bundled", runMs: [])
        let j = try roundTrip(r, failed)
        XCTAssertTrue(j["model_sha256_prefix"] is NSNull)
        XCTAssertEqual(j["model_error"] as? String, "model not bundled")
        XCTAssertEqual(j["runs"] as? Int, 0)
        XCTAssertTrue(j["run_ms_p50"] is NSNull)
        XCTAssertTrue(j["at_scan_start"] is NSNull)
        let final = try XCTUnwrap(j["final"] as? [String: Any])
        XCTAssertEqual(final["outcome"] as? String, "skipped")
        XCTAssertTrue(final["face_skin"] is NSNull)
    }

    func testPerAttemptFieldsResetButCountersDont() throws {
        var r = fullReport()
        r.scanDroppedForCover()
        r.scanStarted(cover: cover(split), ageMs: 100)   // the next (uploaded) attempt
        let j = try roundTrip(r, loaded)
        XCTAssertEqual((j["scan_max"] as? [String: Any])?["body_skin"] as? Double, 0)
        XCTAssertTrue(j["final"] is NSNull)
        XCTAssertEqual(j["scan_drops"] as? Int, 1)
        XCTAssertEqual((j["change_watch"] as? [String: Any])?["trips"] as? Int, 1)
        XCTAssertEqual(j["align_covered_ms"] as? Int, 500)
    }

    func testMeasureGivesTheSixClassSplit() {
        // Mask: hair on the top half, face skin below.
        var p = [CGPoint](repeating: CGPoint(x: 360, y: 560), count: 478)
        for (i, k) in ContourDepthField.faceOvalRing.enumerated() {
            let a = 2 * Double.pi * Double(i) / Double(ContourDepthField.faceOvalRing.count)
            p[k] = CGPoint(x: 360 + 150 * cos(a), y: 560 + 200 * sin(a))
        }
        let c = FaceCover.measure(mask: { $0 / 256 < 112 ? FaceCover.hair : FaceCover.faceSkin },
                                  mw: 256, mh: 256, imageSize: CGSize(width: 720, height: 1280), points: p)
        let classes = c?.classes ?? []
        XCTAssertEqual(classes.count, 6)
        XCTAssertEqual(classes.reduce(0, +), 1, accuracy: 1e-5)
        XCTAssertGreaterThan(classes[Int(FaceCover.hair)], 0.3)
        XCTAssertGreaterThan(classes[Int(FaceCover.faceSkin)], 0.3)
        XCTAssertEqual(c?.bodySkin, 0)
        XCTAssertEqual(c?.other, 0)
    }

    func testMetadataCarriesCoveredCheck() throws {
        let data = try MetadataBuilder().build(
            sessionId: "s", captureStartTime: Date(), captureEndTime: Date(), sessionStartTime: Date(),
            frameHashes: [], framesCaptured: 0, framesDropped: 0, avgFrameIntervalMs: 0,
            challengeResponse: nil, channelIntegrity: [:], deviceTelemetry: [:],
            coveredCheck: fullReport().json(segmenter: loaded))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((meta["covered_check"] as? [String: Any])?["version"] as? String, "cover-v1")
    }
}
