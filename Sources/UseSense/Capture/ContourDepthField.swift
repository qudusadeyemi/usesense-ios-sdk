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

    struct Snapshot: Sendable {
        /// Face box the grid covers, in view points.
        var rect: CGRect
        /// Height above the face's mean depth / face width (toward camera > 0).
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

        // MediaPipe z is negative toward the camera. Height = -(z - mean),
        // scaled by the face's z range so the relief reads the same at any
        // distance (about -0.5 ... +0.6, nose tip highest).
        let meanZ = z.reduce(0, +) / Double(z.count)
        var zMin = Double.infinity, zMax = -Double.infinity
        for v in z { zMin = min(zMin, v); zMax = max(zMax, v) }
        let zRange = max(1e-6, zMax - zMin)
        let heights = z.map { -($0 - meanZ) / zRange }

        // Splat each landmark with a small Gaussian, then normalise.
        let n = Self.size
        var acc = [Float](repeating: 0, count: n * n)
        var wsum = [Float](repeating: 0, count: n * n)
        let radius = 3
        let sigma2: Float = 2 * 1.6 * 1.6
        for (i, p) in points.enumerated() {
            let gx = Float((p.x - rect.minX) / rect.width) * Float(n - 1)
            let gy = Float((p.y - rect.minY) / rect.height) * Float(n - 1)
            let cx = Int(gx.rounded()), cy = Int(gy.rounded())
            let h = Float(heights[i])
            for y in max(0, cy - radius)...min(n - 1, cy + radius) {
                for x in max(0, cx - radius)...min(n - 1, cx + radius) {
                    let dx = Float(x) - gx, dy = Float(y) - gy
                    let w = expf(-(dx * dx + dy * dy) / sigma2)
                    acc[y * n + x] += w * h
                    wsum[y * n + x] += w
                }
            }
        }
        var depth = [Float](repeating: 0, count: n * n)
        var mask = [Float](repeating: 0, count: n * n)
        for k in 0..<(n * n) where wsum[k] > 1e-3 {
            depth[k] = acc[k] / wsum[k]
            mask[k] = min(1, wsum[k] / 0.8)
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
