import Foundation
import CoreGraphics

/// The contour scan's depth field (capture test kit SPEC "Depth field";
/// reference `updateField` in capture-test-kit/reference/index.html).
///
/// A screen-space grid, 96 columns (rows follow the screen aspect):
///  1. mesh detail: each landmark's normalised depth (nose tip ~1, face
///     edge ~0) Gaussian-splatted (sigma 2.6 cells), masked by
///     smoothstep(0, 0.35, weight), then blurred (sigma 1.8 cells);
///  2. head dome: an ellipsoid from landmarks 10/152/234/454, so the lines
///     also lift over the hair and the whole head;
///  3. field = min(1, dome + 0.80 * mesh);
///  4. EMA 0.30 per frame; the last field is kept while the face is gone
///     for under 300 ms.
///
/// Written from the capture queue, read by the contour view on the main
/// thread, so every access goes through the lock. Display only: MediaPipe z
/// is a prediction from one image and is not depth evidence.
final class ContourDepthField: @unchecked Sendable {
    enum Spec {
        static let gridColumns = 96
        static let splatSigma: Float = 2.6
        static let blurSigma: Float = 1.8
        static let emaAlpha: Float = 0.30
        static let feather: Float = 0.35
        static let meshWeight: Float = 0.80
        static let domeRxOfFaceW: CGFloat = 0.62
        static let domeRyOfFaceH: CGFloat = 0.78
        static let domeCyShiftOfFaceH: CGFloat = -0.12
        static let domeHeight: Float = 0.62
        static let domeFeather: Float = 0.18
        static let holdWithoutFace: TimeInterval = 0.3
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

    /// One frame: landmarks already mapped to screen points (aspect-fill,
    /// mirrored: the preview's transform) plus their raw MediaPipe z.
    func update(points: [CGPoint], z: [Double], viewSize: CGSize, time: TimeInterval, alpha: Float = Spec.emaAlpha) {
        guard points.count == z.count, points.count > 454, viewSize.width > 0, viewSize.height > 0 else {
            noFace(at: time)
            return
        }
        let cols = Spec.gridColumns
        let rows = max(1, Int((CGFloat(cols) * viewSize.height / viewSize.width).rounded()))
        let n = cols * rows
        let cell = viewSize.width / CGFloat(cols)

        // 1. Mesh detail.
        var zmin = Double.infinity, zmax = -Double.infinity
        for v in z { zmin = min(zmin, v); zmax = max(zmax, v) }
        let zr = max(1e-6, zmax - zmin)
        var acc = [Float](repeating: 0, count: n)
        var wsum = [Float](repeating: 0, count: n)
        let sig = Spec.splatSigma
        let r = Int((sig * 2.5).rounded(.up))
        let inv2s2 = 1 / (2 * sig * sig)
        for (i, p) in points.enumerated() {
            let d = Float((zmax - z[i]) / zr)
            let gx = Float(p.x / cell), gy = Float(p.y / cell)
            let ix = Int(gx.rounded()), iy = Int(gy.rounded())
            let y0 = max(0, iy - r), y1 = min(rows - 1, iy + r)
            let x0 = max(0, ix - r), x1 = min(cols - 1, ix + r)
            guard y0 <= y1, x0 <= x1 else { continue }
            for y in y0...y1 {
                let dy = Float(y) - gy
                for x in x0...x1 {
                    let dx = Float(x) - gx
                    let w = expf(-(dx * dx + dy * dy) * inv2s2)
                    acc[y * cols + x] += w * d
                    wsum[y * cols + x] += w
                }
            }
        }
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n where wsum[i] > 1e-6 {
            raw[i] = acc[i] / wsum[i] * Self.smoothstep(0, Spec.feather, wsum[i])
        }
        raw = Self.gaussBlur(raw, cols: cols, rows: rows, sigma: Spec.blurSigma)

        // 2. Head dome from forehead (10), chin (152), cheeks (234, 454).
        let top = points[10], chin = points[152]
        let faceH = hypot(chin.x - top.x, chin.y - top.y)
        let faceW = abs(points[454].x - points[234].x)
        let dcx = (top.x + chin.x) / 2
        let dcy = (top.y + chin.y) / 2 + Spec.domeCyShiftOfFaceH * faceH
        let drx = max(1, Spec.domeRxOfFaceW * faceW), dry = max(1, Spec.domeRyOfFaceH * faceH)
        for gy in 0..<rows {
            let y = (CGFloat(gy) + 0.5) * cell
            for gx in 0..<cols {
                let x = (CGFloat(gx) + 0.5) * cell
                let ux = (x - dcx) / drx, uy = (y - dcy) / dry
                let r2 = Float(ux * ux + uy * uy)
                var dome: Float = 0
                if r2 < 1 {
                    dome = powf(1 - r2, 0.75) * Spec.domeHeight * Self.smoothstep(1, 1 - Spec.domeFeather, r2.squareRoot())
                }
                // 3. Combine.
                let i = gy * cols + gx
                raw[i] = min(1, dome + raw[i] * Spec.meshWeight)
            }
        }

        // 4. Temporal EMA.
        lock.lock()
        defer { lock.unlock() }
        if state.field.count != n || !state.hasFace {
            state.field = [Float](repeating: 0, count: n)
            state.faceHeight = faceH
        }
        for i in 0..<n { state.field[i] += (raw[i] - state.field[i]) * alpha }
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
        for y in 0..<rows {
            for x in 0..<cols {
                var a: Float = 0
                for i in -r...r { a += src[y * cols + min(cols - 1, max(0, x + i))] * k[i + r] }
                tmp[y * cols + x] = a
            }
        }
        for y in 0..<rows {
            for x in 0..<cols {
                var a: Float = 0
                for i in -r...r { a += tmp[min(rows - 1, max(0, y + i)) * cols + x] * k[i + r] }
                out[y * cols + x] = a
            }
        }
        return out
    }
}
