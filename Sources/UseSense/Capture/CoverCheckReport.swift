import Foundation

/// The covered-face scores sent with the upload as `metadata.covered_check`
/// (capture test kit COVER-v1.md section 3). Numbers only: no images, no
/// landmarks. Display/gate data for setting the limits later; it changes no
/// decision. Per-attempt fields describe the last scan attempt (the one
/// uploaded); counters cover the whole capture. Not thread-safe by itself.
struct CoverCheckReport: Sendable {
    enum FinalOutcome: String, Sendable { case clear, covered, timeout, skipped }

    // Last scan attempt.
    private(set) var atScanStart: FaceCover?
    private(set) var atScanStartAgeMs: Int?
    private(set) var scanMaxBodySkin: Float = 0
    private(set) var scanMaxOther: Float = 0
    private(set) var final: FaceCover?
    private(set) var finalWaitedMs: Int?
    private(set) var finalOutcome: FinalOutcome?
    private(set) var watchMaxLuma: Float = 0
    private(set) var watchMaxChroma: Float = 0
    private(set) var watchMaxEdge: Float = 1

    // Whole capture.
    private(set) var alignCoveredMs: Double = 0
    private(set) var scanDrops = 0
    private(set) var watchTrips = 0
    private(set) var tripRegions: [String] = []
    private var watchTripping = false

    /// A scan attempt starts: per-attempt fields start over.
    mutating func scanStarted(cover: FaceCover?, ageMs: Int?) {
        atScanStart = cover
        atScanStartAgeMs = cover == nil ? nil : ageMs
        scanMaxBodySkin = 0
        scanMaxOther = 0
        final = nil
        finalWaitedMs = nil
        finalOutcome = nil
        watchMaxLuma = 0
        watchMaxChroma = 0
        watchMaxEdge = 1
        watchTripping = false
    }

    /// One scan frame: the segmenter result in force and the change watch.
    mutating func scanFrame(cover: FaceCover?, watch: CoverWatch) {
        if let cover {
            scanMaxBodySkin = max(scanMaxBodySkin, cover.bodySkin)
            scanMaxOther = max(scanMaxOther, cover.other)
        }
        guard watch.compared else { return }
        watchMaxLuma = max(watchMaxLuma, watch.lastLumaDelta)
        watchMaxChroma = max(watchMaxChroma, watch.lastChromaDelta)
        watchMaxEdge = max(watchMaxEdge, watch.lastEdgeFactor)
        let tripped = watch.lastScore >= 1
        if tripped && !watchTripping {
            watchTrips += 1
            if let r = watch.lastRegion, r < FaceRegions.names.count {
                let name = FaceRegions.names[r]
                if !tripRegions.contains(name) { tripRegions.append(name) }
            }
        }
        watchTripping = tripped
    }

    /// Time on the align screen with "Keep your face uncovered" showing.
    mutating func alignCovered(seconds: TimeInterval) {
        alignCoveredMs += max(0, seconds) * 1000
    }

    /// A scan went back to align because of cover (segmenter or final check).
    mutating func scanDroppedForCover() { scanDrops += 1 }

    mutating func finalCheck(cover: FaceCover?, waitedMs: Int, outcome: FinalOutcome) {
        final = cover
        finalWaitedMs = waitedMs
        finalOutcome = outcome
    }

    // MARK: JSON

    static let version = "cover-v1"
    static let classNames = ["bg", "hair", "body_skin", "face_skin", "clothes", "others"]

    /// The `covered_check` object, with `stats` from the segmenter.
    func json(segmenter stats: FaceCoverSegmenter.Stats) -> [String: Any] {
        let null = NSNull()
        func r3(_ x: Float) -> Double { (Double(x) * 1000).rounded() / 1000 }
        func split(_ c: FaceCover?) -> [String: Any] {
            var out: [String: Any] = [:]
            let classes = c?.classes ?? []
            for (i, name) in Self.classNames.enumerated() {
                out[name] = i < classes.count ? r3(classes[i]) : null
            }
            return out
        }
        let sorted = stats.runMs.sorted()
        let p50: Any = sorted.isEmpty ? null : Int(sorted[sorted.count / 2].rounded())
        let maxMs: Any = sorted.last.map { Int($0.rounded()) } ?? null

        var atStart: Any = null
        if atScanStart != nil {
            var a = split(atScanStart)
            a["age_ms"] = atScanStartAgeMs ?? null
            atStart = a
        }
        var finalObj: Any = null
        if let outcome = finalOutcome {
            var f = split(final)
            f["waited_ms"] = finalWaitedMs ?? null
            f["outcome"] = outcome.rawValue
            finalObj = f
        }
        return [
            "version": Self.version,
            "model_sha256_prefix": stats.loaded ? String(SegmenterModelInfo.sha256.prefix(8)) : null,
            "model_load_ms": stats.loadMs ?? null,
            "model_error": stats.loadError ?? null,
            "limits": [
                "body_skin": r3(FaceCover.bodySkinMax),
                "other": r3(FaceCover.otherMax),
                "shrink": Double(FaceCover.inner),
            ],
            "runs": stats.runMs.count,
            "run_ms_p50": p50,
            "run_ms_max": maxMs,
            "at_scan_start": atStart,
            "scan_max": ["body_skin": r3(scanMaxBodySkin), "other": r3(scanMaxOther)],
            "final": finalObj,
            "align_covered_ms": Int(alignCoveredMs.rounded()),
            "scan_drops": scanDrops,
            "change_watch": [
                "trips": watchTrips,
                "max": [
                    "luma_ratio_delta": r3(watchMaxLuma),
                    "chroma_delta": r3(watchMaxChroma),
                    "edge_factor": r3(watchMaxEdge),
                ],
                "trip_regions": tripRegions,
            ],
        ]
    }
}
