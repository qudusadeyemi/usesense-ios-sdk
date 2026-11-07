import Foundation
import CoreGraphics

/// The contour scan's depth texture: the mesh z rasterised into a 64x64 grid
/// over the face (in view points) each frame, then smoothed over time.
///
/// Written from the capture queue, read by the contour view on the main
/// thread, so every access goes through the lock. Display only: MediaPipe z
/// is a prediction from one image and is not depth evidence.
final class ContourDepthField: @unchecked Sendable {
    static let size = 64
    static let kernelRadius = 5
    /// How strongly facial features stand out from the rounded base.
    static let detailGain: Float = 2.2
    /// > 1 lifts the nose and lips above the broad cheek/forehead plateau.
    static let reliefGamma = 1.8
    /// Gaussian splat kernel (sigma 2.4 cells), precomputed.
    static let kernel: [Float] = {
        let r = kernelRadius, s2: Float = 2 * 2.4 * 2.4
        var k: [Float] = []
        for dy in -r...r { for dx in -r...r { k.append(expf(-Float(dx * dx + dy * dy) / s2)) } }
        return k
    }()

    struct Snapshot: Sendable {
        /// Face box the grid covers, in view points.
        var rect: CGRect
        /// Relief height, already faded at the face edge: 0 off the face ... ~1 at the nose tip.
        var depth: [Float]
        /// 0...1 coverage (how much mesh is under each cell).
        var mask: [Float]
        var hasFace: Bool

        static let empty = Snapshot(rect: .zero, depth: [], mask: [], hasFace: false)

        /// Bilinear sample at a view point: (depth, mask). Zero off the face.
        func sample(_ p: CGPoint) -> (depth: Float, mask: Float) {
            guard hasFace, rect.width > 1, rect.height > 1 else { return (0, 0) }
            let n = ContourDepthField.size
            let gx = Float((p.x - rect.minX) / rect.width) * Float(n - 1)
            let gy = Float((p.y - rect.minY) / rect.height) * Float(n - 1)
            guard gx >= 0, gy >= 0, gx <= Float(n - 1), gy <= Float(n - 1) else { return (0, 0) }
            let x0 = Int(gx), y0 = Int(gy)
            let x1 = min(n - 1, x0 + 1), y1 = min(n - 1, y0 + 1)
            let fx = gx - Float(x0), fy = gy - Float(y0)
            func lerp(_ g: [Float]) -> Float {
                let a = g[y0 * n + x0] * (1 - fx) + g[y0 * n + x1] * fx
                let b = g[y1 * n + x0] * (1 - fx) + g[y1 * n + x1] * fx
                return a * (1 - fy) + b * fy
            }
            return (lerp(depth), lerp(mask))
        }
    }

    private let lock = NSLock()
    private var state = Snapshot.empty
    /// Weight of the new frame in the temporal smoothing.
    var smoothing: Float = 0.35

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func clear() {
        lock.lock(); state = .empty; lock.unlock()
    }

    /// Separable box blur (radius 2), repeated: ~Gaussian.
    static func blur(_ g: inout [Float], n: Int, passes: Int) {
        var tmp = [Float](repeating: 0, count: n * n)
        let r = 2
        for _ in 0..<passes {
            for y in 0..<n {
                for x in 0..<n {
                    var sum: Float = 0, c: Float = 0
                    for dx in -r...r where x + dx >= 0 && x + dx < n { sum += g[y * n + x + dx]; c += 1 }
                    tmp[y * n + x] = sum / c
                }
            }
            for y in 0..<n {
                for x in 0..<n {
                    var sum: Float = 0, c: Float = 0
                    for dy in -r...r where y + dy >= 0 && y + dy < n { sum += tmp[(y + dy) * n + x]; c += 1 }
                    g[y * n + x] = sum / c
                }
            }
        }
    }

    /// Rasterise one frame's landmarks (view points + raw MediaPipe z).
    func update(points: [CGPoint], z: [Double]) {
        guard points.count == z.count, points.count >= 100 else {
            lock.lock(); state.hasFace = false; lock.unlock()
            return
        }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let faceW = maxX - minX, faceH = maxY - minY
        guard faceW > 4, faceH > 4 else { return }
        let rect = CGRect(x: minX, y: minY, width: faceW, height: faceH).insetBy(dx: -faceW * 0.06, dy: -faceH * 0.06)

        // MediaPipe z is negative toward the camera. Height runs from 0 at
        // the farthest point (face edge) to 1 at the nearest (nose tip), so
        // the relief reads the same at any distance.
        var zMin = Double.infinity, zMax = -Double.infinity
        for v in z { zMin = min(zMin, v); zMax = max(zMax, v) }
        let zRange = max(1e-6, zMax - zMin)
        let heights = z.map { pow((zMax - $0) / zRange, Self.reliefGamma) }

        // Splat each mesh landmark with a Gaussian, then normalise
        // (normalised convolution). Iris points (468+) are skipped: their z
        // doesn't follow the surface and they spike the eyes.
        let n = Self.size
        var acc = [Float](repeating: 0, count: n * n)
        var wsum = [Float](repeating: 0, count: n * n)
        let r = Self.kernelRadius
        let kw = 2 * r + 1
        for i in 0..<min(points.count, 468) {
            let p = points[i]
            let cx = Int((Float((p.x - rect.minX) / rect.width) * Float(n - 1)).rounded())
            let cy = Int((Float((p.y - rect.minY) / rect.height) * Float(n - 1)).rounded())
            let h = Float(heights[i])
            for dy in -r...r {
                let y = cy + dy
                guard y >= 0, y < n else { continue }
                for dx in -r...r {
                    let x = cx + dx
                    guard x >= 0, x < n else { continue }
                    let w = Self.kernel[(dy + r) * kw + (dx + r)]
                    acc[y * n + x] += w * h
                    wsum[y * n + x] += w
                }
            }
        }
        var depth = [Float](repeating: 0, count: n * n)
        var mask = [Float](repeating: 0, count: n * n)
        for k in 0..<(n * n) where wsum[k] > 1e-3 {
            // Soft edge: coverage ramps the relief in over ~1 kernel width.
            let t = max(0, min(1, (wsum[k] - 0.25) / 1.6))
            mask[k] = t * t * (3 - 2 * t)
            depth[k] = acc[k] / wsum[k] * mask[k]
        }
        // Round the relief off: the mesh edge would otherwise read as a
        // steep shelf with ripples where boundary landmarks are sparse.
        var fine = depth
        Self.blur(&fine, n: n, passes: 1)
        Self.blur(&depth, n: n, passes: 3)
        Self.blur(&mask, n: n, passes: 2)
        // Put the features (nose ridge, eye sockets, lips) back on top of
        // the rounded base, in the interior only so the edge stays clean.
        for k in 0..<(n * n) {
            let t = max(0, min(1, (mask[k] - 0.55) / 0.4))
            let interior = t * t * (3 - 2 * t)
            depth[k] += Self.detailGain * (fine[k] - depth[k]) * interior
        }

        lock.lock()
        defer { lock.unlock() }
        if state.hasFace, state.depth.count == n * n {
            let a = smoothing, b = 1 - smoothing
            for k in 0..<(n * n) {
                depth[k] = a * depth[k] + b * state.depth[k]
                mask[k] = a * mask[k] + b * state.mask[k]
            }
            let r0 = state.rect
            let lerp = { (u: CGFloat, v: CGFloat) in u * CGFloat(b) + v * CGFloat(a) }
            state.rect = CGRect(x: lerp(r0.minX, rect.minX), y: lerp(r0.minY, rect.minY),
                                width: lerp(r0.width, rect.width), height: lerp(r0.height, rect.height))
        } else {
            state.rect = rect
        }
        state.depth = depth
        state.mask = mask
        state.hasFace = true
    }
}
