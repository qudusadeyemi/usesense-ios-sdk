import Foundation
import CoreGraphics

/// The contour scan's depth field, relief v2 (capture test kit
/// RELIEF-v2.md; reference `updateField` in capture-test-kit/reference/index.html).
///
/// A screen-space grid, 130 columns (rows follow the screen aspect):
///  1. depth per landmark relative to the face outline: 0 on the FACE_OVAL
///     ring (mean z), 1 at the nearest point (nose tip);
///  2. MediaPipe's 852 tessellation triangles rasterised into the grid with
///     barycentric depth (larger value wins where they overlap);
///  3. eye and mouth openings filled by normalised convolution (sigma 3);
///  4. soft edge: smoothstep(0.15, 0.95, blur(cover, 2));
///  5. head dome (unit height) so lines also lift over the hair;
///  6. raw = 0.5 dome + 0.7 mesh, blurred (0.9), EMA 0.30. The last field is
///     kept while the face is gone for under 300 ms.
///
/// Written from the capture queue (off the main thread), read by the contour
/// view on the main thread, so every access goes through the lock. Display
/// only: MediaPipe z is a prediction from one image and is not depth evidence.
final class ContourDepthField: @unchecked Sendable {
    enum Spec {
        static let gridColumns = 130
        static let emaAlpha: Float = 0.30
        static let fillSigma: Float = 3.0
        static let edgeSigma: Float = 2.0
        static let edgeLo: Float = 0.15
        static let edgeHi: Float = 0.95
        static let blurSigma: Float = 0.9
        static let domeHeight: Float = 0.50
        static let meshHeight: Float = 0.70
        static let barycentricSlack: Float = -0.02
        static let domeRxOfFaceW: CGFloat = 0.62
        static let domeRyOfFaceH: CGFloat = 0.78
        static let domeCyShiftOfFaceH: CGFloat = -0.12
        static let domeFeather: Float = 0.18
        static let holdWithoutFace: TimeInterval = 0.3
    }

    /// FACE_OVAL ring (36 landmarks), as the reference.
    static let faceOvalRing: [Int] = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378,
                                      400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21,
                                      54, 103, 67, 109]

    /// MediaPipe's tessellation triangles. Set once from the landmarker's
    /// tessellation connections (3 edges per triangle, in order); empty when
    /// MediaPipe isn't linked, leaving only the dome.
    private static let trianglesLock = NSLock()
    private static var _triangles: [(Int, Int, Int)] = []
    static var triangles: [(Int, Int, Int)] {
        get { trianglesLock.lock(); defer { trianglesLock.unlock() }; return _triangles }
        set { trianglesLock.lock(); _triangles = newValue; trianglesLock.unlock() }
    }

    /// Triangles from a tessellation edge list: edges (3k, 3k+1) give
    /// (start, end, end of the next edge), as the reference.
    static func triangles(fromEdges edges: [(start: Int, end: Int)]) -> [(Int, Int, Int)] {
        var out: [(Int, Int, Int)] = []
        out.reserveCapacity(edges.count / 3)
        var i = 0
        while i + 2 < edges.count {
            out.append((edges[i].start, edges[i].end, edges[i + 1].end))
            i += 3
        }
        return out
    }

    struct Snapshot: Sendable {
        var viewSize: CGSize
        var cols: Int
        var rows: Int
        var field: [Float]
        /// Forehead (10) to chin (152) in screen points: the lift scale.
        var faceHeight: CGFloat
        var hasFace: Bool

        static let empty = Snapshot(viewSize: .zero, cols: 0, rows: 0, field: [], faceHeight: 0, hasFace: false)

        /// Bilinear sample at a screen point (reference `sampleField`).
        func sample(_ x: CGFloat, _ y: CGFloat) -> Float {
            guard hasFace, cols > 0, viewSize.width > 0 else { return 0 }
            let cell = viewSize.width / CGFloat(cols)
            let gx = x / cell, gy = y / cell
            let x0 = Int(floor(gx)), y0 = Int(floor(gy))
            let fx = Float(gx - CGFloat(x0)), fy = Float(gy - CGFloat(y0))
            func g(_ xx: Int, _ yy: Int) -> Float {
                (xx < 0 || yy < 0 || xx >= cols || yy >= rows) ? 0 : field[yy * cols + xx]
            }
            return g(x0, y0) * (1 - fx) * (1 - fy) + g(x0 + 1, y0) * fx * (1 - fy)
                + g(x0, y0 + 1) * (1 - fx) * fy + g(x0 + 1, y0 + 1) * fx * fy
        }
    }

    private let lock = NSLock()
    private var state = Snapshot.empty
    private var lastFaceTime: TimeInterval?

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func clear() {
        lock.lock(); state = .empty; lastFaceTime = nil; lock.unlock()
    }

    /// No face this frame: keep the last field briefly, then drop it.
    func noFace(at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if let last = lastFaceTime, time - last < Spec.holdWithoutFace { return }
        state.hasFace = false
    }

    private let workQueue = DispatchQueue(label: "ai.usesense.contour", qos: .userInitiated)
    private var busy = false

    /// Queue one frame on the field's own thread, off the camera queue so the
    /// quality gate never waits for the display. Frames that arrive while one
    /// is being built are dropped (the EMA smooths over them).
    func submit(points: [CGPoint], z: [Double], viewSize: CGSize, time: TimeInterval) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        workQueue.async { [self] in
            update(points: points, z: z, viewSize: viewSize, time: time)
            lock.lock(); busy = false; lock.unlock()
        }
    }

    /// One frame: landmarks already mapped to screen points (aspect-fill,
    /// mirrored: the preview's transform) plus their raw MediaPipe z.
    func update(points: [CGPoint], z: [Double], viewSize: CGSize, time: TimeInterval, alpha: Float = Spec.emaAlpha,
                triangles: [(Int, Int, Int)]? = nil) {
        guard points.count == z.count, points.count >= 468, viewSize.width > 0, viewSize.height > 0 else {
            noFace(at: time)
            return
        }
        let cols = Spec.gridColumns
        let rows = max(1, Int((CGFloat(cols) * viewSize.height / viewSize.width).rounded()))
        let n = cols * rows
        let cell = viewSize.width / CGFloat(cols)

        // 1. Depth relative to the face outline.
        var zmin = Double.infinity
        for i in 0..<468 { zmin = min(zmin, z[i]) }
        var zEdge = 0.0
        for k in Self.faceOvalRing { zEdge += z[k] }
        zEdge /= Double(Self.faceOvalRing.count)
        let zr = max(1e-6, zEdge - zmin)
        var px = [Float](repeating: 0, count: points.count)
        var py = [Float](repeating: 0, count: points.count)
        var pd = [Float](repeating: 0, count: points.count)
        for i in 0..<points.count {
            px[i] = Float(points[i].x / cell)
            py[i] = Float(points[i].y / cell)
            pd[i] = Float(max(0, (zEdge - z[i]) / zr))
        }

        // 2. Rasterise the triangle mesh. (Raw buffers: this runs every
        // frame and must stay cheap in unoptimised debug builds too.)
        var mesh = [Float](repeating: 0, count: n)
        var cover = [Float](repeating: 0, count: n)
        let slack = Spec.barycentricSlack
        let tris = triangles ?? Self.triangles
        let count = points.count
        mesh.withUnsafeMutableBufferPointer { mb in
        cover.withUnsafeMutableBufferPointer { cb in
        px.withUnsafeBufferPointer { X in
        py.withUnsafeBufferPointer { Y in
        pd.withUnsafeBufferPointer { D in
            let m = mb.baseAddress!, c = cb.baseAddress!
            for (ia, ib, ic) in tris {
                guard ia < count, ib < count, ic < count else { continue }
                let ax = X[ia], ay = Y[ia], bx = X[ib], by = Y[ib], cx = X[ic], cy = Y[ic]
                let x0 = max(0, Int(floor(min(ax, bx, cx)))), x1 = min(cols - 1, Int(ceil(max(ax, bx, cx))))
                let y0 = max(0, Int(floor(min(ay, by, cy)))), y1 = min(rows - 1, Int(ceil(max(ay, by, cy))))
                guard x0 <= x1, y0 <= y1 else { continue }
                let den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
                guard abs(den) >= 1e-9 else { continue }
                let inv = 1 / den
                let da = D[ia], db = D[ib], dc = D[ic]
                var y = y0
                while y <= y1 {
                    let qy = Float(y) + 0.5
                    var x = x0
                    while x <= x1 {
                        let qx = Float(x) + 0.5
                        let w1 = ((by - cy) * (qx - cx) + (cx - bx) * (qy - cy)) * inv
                        let w2 = ((cy - ay) * (qx - cx) + (ax - cx) * (qy - cy)) * inv
                        let w3 = 1 - w1 - w2
                        if w1 >= slack, w2 >= slack, w3 >= slack {
                            let d = w1 * da + w2 * db + w3 * dc
                            let i = y * cols + x
                            if d > m[i] || c[i] == 0 { m[i] = d }
                            c[i] = 1
                        }
                        x += 1
                    }
                    y += 1
                }
            }
        }}}}}

        // 3. Fill the eye and mouth openings; 4. soft edge.
        // Uncovered cells are 0 already, so mesh * cover == mesh.
        let mc = mesh
        let num = Self.gaussBlur(mc, cols: cols, rows: rows, sigma: Spec.fillSigma)
        let den2 = Self.gaussBlur(cover, cols: cols, rows: rows, sigma: Spec.fillSigma)
        let soft = Self.gaussBlur(cover, cols: cols, rows: rows, sigma: Spec.edgeSigma)

        // 5. Head dome from forehead (10), chin (152), cheeks (234, 454);
        // 6. combine.
        let top = points[10], chin = points[152]
        let faceH = hypot(chin.x - top.x, chin.y - top.y)
        let faceW = abs(points[454].x - points[234].x)
        let dcx = Float((top.x + chin.x) / 2)
        let dcy = Float((top.y + chin.y) / 2 + Spec.domeCyShiftOfFaceH * faceH)
        let drx = Float(max(1, Spec.domeRxOfFaceW * faceW)), dry = Float(max(1, Spec.domeRyOfFaceH * faceH))
        let fcell = Float(cell)
        var raw = [Float](repeating: 0, count: n)
        raw.withUnsafeMutableBufferPointer { rb in
        mesh.withUnsafeBufferPointer { M in
        cover.withUnsafeBufferPointer { C in
        num.withUnsafeBufferPointer { NU in
        den2.withUnsafeBufferPointer { DE in
        soft.withUnsafeBufferPointer { SO in
            let r = rb.baseAddress!
            for gy in 0..<rows {
                let uy = ((Float(gy) + 0.5) * fcell - dcy) / dry
                for gx in 0..<cols {
                    let i = gy * cols + gx
                    let filled = C[i] > 0 ? M[i] : (DE[i] > 1e-3 ? NU[i] / DE[i] : 0)
                    let meshV = filled * Self.smoothstep(Spec.edgeLo, Spec.edgeHi, SO[i])
                    let ux = ((Float(gx) + 0.5) * fcell - dcx) / drx
                    let r2 = ux * ux + uy * uy
                    var dome: Float = 0
                    if r2 < 1 {
                        dome = powf(1 - r2, 0.75) * Self.smoothstep(1, 1 - Spec.domeFeather, r2.squareRoot())
                    }
                    r[i] = dome * Spec.domeHeight + meshV * Spec.meshHeight
                }
            }
        }}}}}}
        raw = Self.gaussBlur(raw, cols: cols, rows: rows, sigma: Spec.blurSigma)

        // Temporal EMA.
        lock.lock()
        defer { lock.unlock() }
        if state.field.count != n || !state.hasFace {
            state.field = [Float](repeating: 0, count: n)
            state.faceHeight = faceH
        }
        raw.withUnsafeBufferPointer { R in
            state.field.withUnsafeMutableBufferPointer { F in
                for i in 0..<n { F[i] += (R[i] - F[i]) * alpha }
            }
        }
        state.faceHeight += (faceH - state.faceHeight) * CGFloat(alpha)
        state.viewSize = viewSize
        state.cols = cols
        state.rows = rows
        state.hasFace = true
        lastFaceTime = time
    }

    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Separable Gaussian blur with clamped edges (reference `gaussBlur`).
    static func gaussBlur(_ src: [Float], cols: Int, rows: Int, sigma: Float) -> [Float] {
        let r = Int((sigma * 2.5).rounded(.up))
        var k = [Float]()
        for i in -r...r { k.append(expf(-Float(i * i) / (2 * sigma * sigma))) }
        let sum = k.reduce(0, +)
        k = k.map { $0 / sum }
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { S in
        k.withUnsafeBufferPointer { K in
        tmp.withUnsafeMutableBufferPointer { T in
        out.withUnsafeMutableBufferPointer { O in
            for y in 0..<rows {
                let row = y * cols
                for x in 0..<cols {
                    var a: Float = 0
                    var i = -r
                    while i <= r {
                        let xx = min(cols - 1, max(0, x + i))
                        a += S[row + xx] * K[i + r]
                        i += 1
                    }
                    T[row + x] = a
                }
            }
            for y in 0..<rows {
                for x in 0..<cols {
                    var a: Float = 0
                    var i = -r
                    while i <= r {
                        let yy = min(rows - 1, max(0, y + i))
                        a += T[yy * cols + x] * K[i + r]
                        i += 1
                    }
                    O[y * cols + x] = a
                }
            }
        }}}}
        return out
    }
}
