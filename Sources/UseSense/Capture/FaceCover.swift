import Foundation
import CoreGraphics
import CoreVideo
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif

// MARK: - Covered-face check (capture test kit COVER-v1.md)
//
// MediaPipe's face landmarker keeps predicting a plausible face under a hand,
// a phone or a sheet of paper, so every other check passes on a covered face.
// Two parts, both gate-only (nothing here is uploaded):
//  1. segmentation (any stage): the multiclass selfie model labels what is
//     inside the face silhouette; body skin is a hand, background, clothes or
//     "others" an object;
//  2. change watch (scan only): six face regions compared with the start of
//     the scan, which reacts within one frame, ahead of the segmenter.

/// The bundled segmentation model (MediaPipe selfie_multiclass_256x256 float32 v1).
public enum SegmenterModelInfo {
    public static let resourceName = "selfie_multiclass_256x256"
    public static let resourceExtension = "tflite"
    public static let sha256 = "c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0"
    public static let sizeBytes = 16_371_837
    public static let sourceUrl =
        "https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_multiclass_256x256/float32/1/selfie_multiclass_256x256.tflite"
}

/// How much of the face area the segmenter sees as something other than face.
struct FaceCover: Equatable, Sendable {
    /// Share labelled body skin: a hand or an arm in front of the face.
    var bodySkin: Float
    /// Share labelled background, clothes or other objects (a phone, paper).
    var other: Float
    /// The full split by category (background, hair, body skin, face skin,
    /// clothes, others), each a share of the area; nil when not measured.
    var classes: [Float]? = nil

    static let bodySkinMax: Float = 0.12
    static let otherMax: Float = 0.25
    /// Shrink of the face silhouette toward its centroid, so edge pixels don't count.
    static let inner: CGFloat = 0.85

    // selfie_multiclass_256x256 categories.
    static let background: UInt8 = 0, hair: UInt8 = 1, bodySkinClass: UInt8 = 2
    static let faceSkin: UInt8 = 3, clothes: UInt8 = 4, others: UInt8 = 5

    var covered: Bool { bodySkin >= Self.bodySkinMax || other >= Self.otherMax }

    /// Share of the face area by category, from a category mask (`mw` x `mh`,
    /// one byte per pixel) of an `imageSize` frame, inside the FACE_OVAL
    /// silhouette of `points` (image pixels) shrunk to 85%, sampled on a
    /// ~40-step grid across its width. Pure, so tested.
    static func measure(mask: (Int) -> UInt8, mw: Int, mh: Int, imageSize: CGSize, points: [CGPoint]) -> FaceCover? {
        guard points.count >= 468, mw > 0, mh > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let ring = ContourDepthField.faceOvalRing
        var cx: CGFloat = 0, cy: CGFloat = 0
        for k in ring { cx += points[k].x; cy += points[k].y }
        cx /= CGFloat(ring.count); cy /= CGFloat(ring.count)
        let px = ring.map { cx + (points[$0].x - cx) * inner }
        let py = ring.map { cy + (points[$0].y - cy) * inner }
        guard let minX = px.min(), let maxX = px.max(), let minY = py.min(), let maxY = py.max() else { return nil }
        let sx = CGFloat(mw) / imageSize.width, sy = CGFloat(mh) / imageSize.height
        let step = max(1, (maxX - minX) / 40)
        var total = 0
        var counts = [Int](repeating: 0, count: 6)
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                if inside(px, py, x, y) {
                    let mx = min(mw - 1, max(0, Int(x * sx)))
                    let my = min(mh - 1, max(0, Int(y * sy)))
                    let c = Int(mask(my * mw + mx))
                    if c < counts.count { counts[c] += 1 }
                    total += 1
                }
                x += step
            }
            y += step
        }
        guard total > 0 else { return nil }
        let share = counts.map { Float($0) / Float(total) }
        return FaceCover(bodySkin: share[Int(bodySkinClass)],
                         other: share[Int(background)] + share[Int(clothes)] + share[Int(others)],
                         classes: share)
    }

    private static func inside(_ px: [CGFloat], _ py: [CGFloat], _ x: CGFloat, _ y: CGFloat) -> Bool {
        var c = false
        var j = px.count - 1
        for i in px.indices {
            if (py[i] > y) != (py[j] > y), x < (px[j] - px[i]) * (y - py[i]) / (py[j] - py[i]) + px[i] { c.toggle() }
            j = i
        }
        return c
    }
}

// MARK: - Change watch

/// Appearance of six face regions on one frame: luma relative to the mean of
/// all six (so the fill light or an exposure change cancels), red and blue
/// chromaticity, and edge energy (mean |dx| + |dy| of luma; fingers and
/// object edges raise it, a smooth palm or paper lowers it).
struct FaceRegions: Equatable, Sendable {
    /// Forehead, two cheeks, nose, mouth, chin (MediaPipe 478-point mesh).
    static let anchors = [151, 50, 280, 5, 13, 199]
    /// COVER-v1 names. Landmark 50 is on the subject's right cheek, 280 on the left.
    static let names = ["forehead", "cheek_r", "cheek_l", "nose", "mouth", "chin"]
    /// Patch half-size as a fraction of face width (|L454 - L234|).
    static let patchOfFaceW: CGFloat = 0.07

    struct Region: Equatable, Sendable {
        var luma: Float
        var red: Float
        var blue: Float
        var edge: Float
    }

    var regions: [Region]

    /// - Parameters:
    ///   - bgra: 32-bit BGRA pixels, `width` x `height`, `bytesPerRow` apart.
    ///   - points: landmarks in image pixels.
    static func measure(bgra: UnsafePointer<UInt8>, width w: Int, height h: Int, bytesPerRow: Int,
                        points: [CGPoint]) -> FaceRegions? {
        guard points.count >= 468, w > 4, h > 4 else { return nil }
        let faceW = abs(points[454].x - points[234].x)
        let half = max(2, Int(patchOfFaceW * faceW))
        @inline(__always) func luma(_ x: Int, _ y: Int) -> Float {
            let p = bgra + y * bytesPerRow + x * 4
            return 0.299 * Float(p[2]) + 0.587 * Float(p[1]) + 0.114 * Float(p[0])
        }
        var out: [Region] = []
        out.reserveCapacity(anchors.count)
        var lumaSum: Float = 0
        for idx in anchors {
            let cx = Int(points[idx].x), cy = Int(points[idx].y)
            let x0 = max(1, cx - half), x1 = min(w - 2, cx + half)
            let y0 = max(1, cy - half), y1 = min(h - 2, cy + half)
            guard x1 > x0, y1 > y0 else { return nil }
            var sl: Float = 0, sr: Float = 0, sb: Float = 0, se: Float = 0, n: Float = 0
            var y = y0
            while y <= y1 {
                var x = x0
                while x <= x1 {
                    let p = bgra + y * bytesPerRow + x * 4
                    let b = Float(p[0]), g = Float(p[1]), r = Float(p[2])
                    let sum = max(1, r + g + b)
                    sl += 0.299 * r + 0.587 * g + 0.114 * b
                    sr += r / sum
                    sb += b / sum
                    se += abs(luma(x + 1, y) - luma(x - 1, y)) + abs(luma(x, y + 1) - luma(x, y - 1))
                    n += 1
                    x += 2
                }
                y += 2
            }
            guard n > 0 else { return nil }
            out.append(Region(luma: sl / n, red: sr / n, blue: sb / n, edge: se / n))
            lumaSum += sl / n
        }
        // Luma relative to the face's mean, so a global change cancels.
        let mean = max(1, lumaSum / Float(anchors.count))
        for i in out.indices { out[i].luma /= mean }
        return FaceRegions(regions: out)
    }

    static func measure(_ pixelBuffer: CVPixelBuffer, points: [CGPoint]) -> FaceRegions? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        return measure(bgra: base.assumingMemoryBound(to: UInt8.self),
                       width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), points: points)
    }
}

/// Watches the face regions through one scan: the first 3 frames set a
/// baseline (running mean); afterwards a region that changes beyond the
/// limits means something covered the face. Pure, so tested.
struct CoverWatch: Sendable {
    static let baselineFrames = 3
    /// Change in a region's luma relative to the face mean.
    static let lumaLimit: Float = 0.22
    /// Change in red or blue chromaticity.
    static let chromaLimit: Float = 0.035
    /// Edge energy may rise or fall by this factor (with a +4 floor).
    static let edgeRatioLimit: Float = 2.2
    static let edgeFloor: Float = 4

    private var baseline: [FaceRegions.Region]?
    private var frames = 0
    /// The largest change on the last frame (>= 1 fails) and its region, for the trace.
    private(set) var lastScore: Float = 0
    private(set) var lastRegion: Int?
    /// Raw changes on the last frame after the baseline, largest over the
    /// regions (for the upload's covered_check): luma ratio change, red/blue
    /// chromaticity change, and edge energy factor (larger of up/down).
    private(set) var lastLumaDelta: Float = 0
    private(set) var lastChromaDelta: Float = 0
    private(set) var lastEdgeFactor: Float = 1
    /// The last frame was compared with a finished baseline.
    private(set) var compared = false

    mutating func reset() { self = CoverWatch() }

    /// True when the face looks covered compared with the start of the scan.
    mutating func covered(_ regions: FaceRegions?) -> Bool {
        guard let v = regions?.regions else { return false }
        if frames < Self.baselineFrames || baseline == nil {
            var b = baseline ?? v.map { _ in FaceRegions.Region(luma: 0, red: 0, blue: 0, edge: 0) }
            let k = Float(frames + 1)
            for i in b.indices {
                b[i].luma += (v[i].luma - b[i].luma) / k
                b[i].red += (v[i].red - b[i].red) / k
                b[i].blue += (v[i].blue - b[i].blue) / k
                b[i].edge += (v[i].edge - b[i].edge) / k
            }
            baseline = b
            frames += 1
            lastScore = 0
            lastRegion = nil
            compared = false
            return false
        }
        guard let base = baseline else { return false }
        var worst: Float = 0
        var worstRegion: Int?
        lastLumaDelta = 0; lastChromaDelta = 0; lastEdgeFactor = 1
        compared = true
        for r in v.indices where r < base.count {
            let lumaDelta = abs(v[r].luma - base[r].luma)
            let chromaDelta = max(abs(v[r].red - base[r].red), abs(v[r].blue - base[r].blue))
            let e0 = base[r].edge + Self.edgeFloor, e1 = v[r].edge + Self.edgeFloor
            let factor = max(e1 / e0, e0 / e1)
            lastLumaDelta = max(lastLumaDelta, lumaDelta)
            lastChromaDelta = max(lastChromaDelta, chromaDelta)
            lastEdgeFactor = max(lastEdgeFactor, factor)
            let luma = lumaDelta / Self.lumaLimit
            let chroma = chromaDelta / Self.chromaLimit
            let edge = (factor - 1) / (Self.edgeRatioLimit - 1)
            let score = max(luma, chroma, edge)
            if score > worst { worst = score; worstRegion = r }
        }
        lastScore = worst
        lastRegion = worstRegion
        return worst >= 1
    }
}

// MARK: - One person

enum FaceBoxes {
    /// A second face whose box overlaps the subject's by at least this is the
    /// same face found twice (tracking + re-detection), not another person.
    static let sameFaceIoU: CGFloat = 0.3

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Distinct people: the subject plus every other face that doesn't
    /// overlap it by `sameFaceIoU` or more.
    static func distinctFaces(_ boxes: [CGRect], subject: Int) -> Int {
        guard subject < boxes.count else { return boxes.count }
        return 1 + boxes.indices.filter { $0 != subject && iou(boxes[$0], boxes[subject]) < sameFaceIoU }.count
    }
}

// MARK: - Segmenter

/// Runs the multiclass selfie segmentation on its own queue, on the latest
/// frame whenever the previous run is done, and keeps the latest result.
/// Its own MediaPipe ImageSegmenter: no graph or resources are shared with
/// the face landmarker. Off (never pending) when MediaPipe isn't linked or
/// the model isn't bundled; capture then works as before.
final class FaceCoverSegmenter: @unchecked Sendable {
    /// A result older than this no longer counts.
    static let maxAge: TimeInterval = 3

    private let queue = DispatchQueue(label: "ai.usesense.cover", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var released = false
    private var _available = false
    private var _latest: FaceCover?
    private var _latestAt: TimeInterval = -.infinity
    private var runs = 0
    private(set) var meanMs: Double = 0
    private var _loadMs: Int?
    private var _loadError: String?
    private var _runMs: [Double] = []

    /// Model load result and run timings, for the upload's covered_check.
    struct Stats: Sendable {
        var loaded: Bool
        var loadMs: Int?
        var loadError: String?
        var runMs: [Double]
    }

    var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(loaded: _available, loadMs: _loadMs, loadError: _loadError, runMs: _runMs)
    }
    #if canImport(MediaPipeTasksVision)
    private var segmenter: ImageSegmenter?
    #endif

    var available: Bool { lock.lock(); defer { lock.unlock() }; return _available && !released }
    /// Time of the frame the latest result came from (-inf before any).
    var latestAt: TimeInterval { lock.lock(); defer { lock.unlock() }; return _latestAt }

    /// The latest result if it is at most `maxAge` older than `time`.
    func latest(at time: TimeInterval) -> FaceCover? {
        lock.lock(); defer { lock.unlock() }
        guard let l = _latest, time - _latestAt <= Self.maxAge else { return nil }
        return l
    }

    func setup() {
        queue.async { [self] in
            #if canImport(MediaPipeTasksVision)
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let url = Bundle.useSenseResources.url(forResource: SegmenterModelInfo.resourceName,
                                                         withExtension: SegmenterModelInfo.resourceExtension) else {
                lock.lock(); _loadError = "model not bundled"; lock.unlock()
                USTrace.log("cover: segmentation model not bundled, check off")
                return
            }
            do {
                let options = ImageSegmenterOptions()
                options.baseOptions.modelAssetPath = url.path
                options.runningMode = .image
                options.shouldOutputCategoryMask = true
                options.shouldOutputConfidenceMasks = false
                let s = try ImageSegmenter(options: options)
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                lock.lock(); segmenter = s; _available = !released; _loadMs = ms; lock.unlock()
                USTrace.log("cover: segmentation on (\(SegmenterModelInfo.resourceName))")
            } catch {
                lock.lock(); _loadError = error.localizedDescription; lock.unlock()
                USTrace.log("cover: segmentation unavailable: \(error.localizedDescription)")
            }
            #else
            lock.lock(); _loadError = "MediaPipe not linked"; lock.unlock()
            #endif
        }
    }

    /// Start a run on a copy of `pixelBuffer` for the face in `points` (image
    /// pixels) unless one is running. `time` is the frame's time.
    @discardableResult
    func offer(_ pixelBuffer: CVPixelBuffer, points: [CGPoint], time: TimeInterval) -> Bool {
        lock.lock()
        guard _available, !released, !busy else { lock.unlock(); return false }
        busy = true
        lock.unlock()
        // A copy, so the camera's buffer pool isn't held for the whole run.
        guard let copy = Self.copy(pixelBuffer) else {
            lock.lock(); busy = false; lock.unlock()
            return false
        }
        queue.async { [self] in
            let result = measure(copy, points: points)
            lock.lock()
            if let result, !released { _latest = result; _latestAt = time }
            busy = false
            lock.unlock()
        }
        return true
    }

    /// Forget the last result (the face was lost).
    func clear() {
        lock.lock(); _latest = nil; _latestAt = -.infinity; lock.unlock()
    }

    func release() {
        lock.lock(); released = true; _available = false; lock.unlock()
        #if canImport(MediaPipeTasksVision)
        queue.async { [self] in segmenter = nil }
        #endif
    }

    private func measure(_ buffer: CVPixelBuffer, points: [CGPoint]) -> FaceCover? {
        #if canImport(MediaPipeTasksVision)
        guard let segmenter else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let image = try? MPImage(pixelBuffer: buffer),
              let result = try? segmenter.segment(image: image),
              let mask = result.categoryMask, mask.width > 0, mask.height > 0 else { return nil }
        let data = mask.uint8Data
        let cover = FaceCover.measure(mask: { data[$0] }, mw: mask.width, mh: mask.height,
                                      imageSize: CGSize(width: CVPixelBufferGetWidth(buffer),
                                                        height: CVPixelBufferGetHeight(buffer)),
                                      points: points)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        lock.lock()
        if _runMs.count < 2000 { _runMs.append(ms) }
        lock.unlock()
        runs += 1
        meanMs = runs == 1 ? ms : meanMs * 0.9 + ms * 0.1
        if runs % 20 == 1 {
            USTrace.log("cover: segmentation ~\(Int(meanMs)) ms"
                + " body=\(cover.map { String(format: "%.2f", $0.bodySkin) } ?? "-")"
                + " other=\(cover.map { String(format: "%.2f", $0.other) } ?? "-")")
        }
        return cover
        #else
        return nil
        #endif
    }

    private static func copy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)
        guard format == kCVPixelFormatType_32BGRA else { return nil }
        var dst: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, format, attrs as CFDictionary, &dst) == kCVReturnSuccess,
              let dst else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(src), let d = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let sRow = CVPixelBufferGetBytesPerRow(src), dRow = CVPixelBufferGetBytesPerRow(dst)
        let rowBytes = min(sRow, dRow, w * 4)
        for y in 0..<h { memcpy(d + y * dRow, s + y * sRow, rowBytes) }
        return dst
    }
}
