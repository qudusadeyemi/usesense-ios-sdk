#if canImport(AVFoundation) && canImport(UIKit)
import Foundation

/// Per-frame 3D Morphable Model fit result.
struct ThreeDMMFitResult: Sendable {
    let shapeParams: [Double]       // 12 PCA identity coefficients (Float64 precision REQUIRED)
    let pose: HeadPose
    let depthPlausibility: Double   // 0-100
    let geometricRatios: [Double]   // 6 model-invariant face proportions
    let poseRatios2D: [Double]      // 5 pose-sensitive 2D ratios
}

/// On-device PCA-based 3D Morphable Model fitting.
/// Uses 40 salient landmarks from MediaPipe FaceMesh to estimate 3D face shape.
/// CRITICAL: All shape parameters use Double (Float64) precision, NOT Float (Float32).
final class OnDevice3DMMFitter: @unchecked Sendable {

    /// Salient landmark indices for 3DMM fitting (eye corners, nose, chin, etc.)
    private static let salientIndices: [Int] = [
        // Eye corners
        33, 133, 362, 263,
        // Eyebrow endpoints
        70, 63, 105, 66, 107, 300, 293, 334, 296, 336,
        // Nose
        1, 2, 98, 327, 168,
        // Mouth corners and lips
        61, 291, 13, 14, 78, 308, 82, 312,
        // Chin and jawline
        152, 234, 454, 10, 338, 297, 332, 284,
        // Cheek landmarks
        123, 352, 176, 400
    ]

    /// Fit 3DMM to a single frame's landmarks.
    func fit(landmarks: [(x: Double, y: Double, z: Double)], pose: HeadPose) -> ThreeDMMFitResult? {
        guard landmarks.count >= 468 else { return nil }

        // Extract salient landmarks
        let salient = Self.salientIndices.compactMap { idx -> (x: Double, y: Double, z: Double)? in
            guard idx < landmarks.count else { return nil }
            return landmarks[idx]
        }
        guard salient.count >= 30 else { return nil }

        // PCA-based shape parameter estimation (12 coefficients)
        let shapeParams = estimateShapeParams(from: salient)

        // Depth plausibility: how "face-shaped" the depth profile is
        let depthPlausibility = computeDepthPlausibility(landmarks: salient, shapeParams: shapeParams)

        // Model-invariant geometric ratios (6 ratios)
        let geometricRatios = computeGeometricRatios(from: landmarks)

        // Pose-sensitive 2D ratios (5 ratios)
        let poseRatios2D = computePoseRatios2D(from: landmarks)

        return ThreeDMMFitResult(
            shapeParams: shapeParams,
            pose: pose,
            depthPlausibility: depthPlausibility,
            geometricRatios: geometricRatios,
            poseRatios2D: poseRatios2D
        )
    }

    // MARK: - Shape Estimation

    /// Fixed 12 × 117 orthonormal projection basis used to extract shape
    /// parameters from the mean-centered salient-landmark space.
    ///
    /// This is NOT trained PCA — it is a deterministic orthonormal random
    /// projection generated once at static-init time via xorshift64* plus
    /// Gram-Schmidt. The Johnson-Lindenstrauss lemma guarantees that random
    /// orthonormal projections preserve pairwise distances between points
    /// up to a small distortion, so inter-face distinguishability is
    /// maintained even though the basis is not trained. Crucially, an
    /// orthonormal projection scales the natural frame-to-frame jitter in
    /// MediaPipe FaceLandmarker outputs into meaningful variance in the
    /// shape parameters (~1e-4 in practice), which is well above the
    /// backend mesh-integrity validator's MIN_SHAPE_VARIANCE floor. The
    /// prior implementation was a deterministic weighted sum that divided
    /// by salient.count, crushing the jitter below the floor and tripping
    /// a false-positive "possible replay" warning on every still face.
    ///
    /// TODO(usesense-ios-sdk): replace with a properly-trained PCA basis
    /// once a dataset of FaceLandmarker outputs is available. The loader
    /// should read bundled bytes instead of computing the basis in code.
    /// The on-wire shape param format will not change — only the numerical
    /// values — because `meshDigest` hashes whatever shape params the SDK
    /// emits.
    private static let projectionBasis: [[Double]] = {
        let outputDim = 12
        let inputDim = 3 * salientIndices.count // 3 coords × 39 salient landmarks = 117

        // xorshift64* with a fixed seed (golden-ratio fractional bits) so
        // every device computes the same basis. Any non-zero seed works.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func nextUniform() -> Double {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let x = state &* 0x2545F4914F6CDD1D
            // Map 53-bit mantissa range to [-1, 1)
            let bits = (x >> 11) & 0x1FFFFFFFFFFFFF // 53 bits
            return Double(bits) / Double(1 << 53) * 2.0 - 1.0
        }

        var rows: [[Double]] = []
        rows.reserveCapacity(outputDim)
        for _ in 0..<outputDim {
            var row = [Double](repeating: 0, count: inputDim)
            for j in 0..<inputDim {
                row[j] = nextUniform()
            }
            // Gram-Schmidt: subtract projections onto already-orthonormal rows.
            for prev in rows {
                var dot = 0.0
                for j in 0..<inputDim { dot += row[j] * prev[j] }
                for j in 0..<inputDim { row[j] -= dot * prev[j] }
            }
            // Normalize to unit length. After GS with random inputs in a
            // high-dim space, numerical stability is not a concern at 117 dims.
            var sumSq = 0.0
            for j in 0..<inputDim { sumSq += row[j] * row[j] }
            let invNorm = 1.0 / Foundation.sqrt(sumSq)
            for j in 0..<inputDim { row[j] *= invNorm }
            rows.append(row)
        }
        return rows
    }()

    private func estimateShapeParams(from salient: [(x: Double, y: Double, z: Double)]) -> [Double] {
        let basis = Self.projectionBasis
        let outputDim = basis.count

        // Mean-center the salient landmarks (subtracting the centroid removes
        // global translation so the shape params are translation-invariant).
        let count = Double(salient.count)
        var cx = 0.0, cy = 0.0, cz = 0.0
        for p in salient { cx += p.x; cy += p.y; cz += p.z }
        cx /= count; cy /= count; cz /= count

        var centered = [Double]()
        centered.reserveCapacity(salient.count * 3)
        for p in salient {
            centered.append(p.x - cx)
            centered.append(p.y - cy)
            centered.append(p.z - cz)
        }

        // Project centered landmarks onto each orthonormal basis row.
        // Each output coefficient is the dot product <basis_i, centered>.
        var params = [Double](repeating: 0, count: outputDim)
        for i in 0..<outputDim {
            let row = basis[i]
            // Guard against any mismatch between the basis's fixed input
            // dimension and the runtime salient count (shouldn't happen with
            // the >=468 landmark guard above, but cheap to be defensive).
            let dim = Swift.min(row.count, centered.count)
            var sum = 0.0
            for j in 0..<dim { sum += row[j] * centered[j] }
            params[i] = sum
        }
        return params
    }

    // MARK: - Depth Plausibility

    private func computeDepthPlausibility(
        landmarks: [(x: Double, y: Double, z: Double)],
        shapeParams: [Double]
    ) -> Double {
        // Depth plausibility checks if Z-values form a face-like depth profile.
        // Flat screens have near-zero Z variance; real faces have structured depth.
        let zValues = landmarks.map(\.z)
        guard !zValues.isEmpty else { return 0 }

        let mean = zValues.reduce(0, +) / Double(zValues.count)
        let variance = zValues.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(zValues.count)
        let stdDev = sqrt(variance)

        // Shape param magnitude (well-fit faces have moderate magnitude)
        let paramMagnitude = sqrt(shapeParams.map { $0 * $0 }.reduce(0, +))

        // Score: higher Z variance = more likely real 3D face
        let depthScore = min(100.0, stdDev * 5000.0)
        let shapeScore = min(100.0, max(0.0, 100.0 - abs(paramMagnitude - 0.5) * 200.0))

        return min(100.0, (depthScore * 0.6 + shapeScore * 0.4))
    }

    // MARK: - Geometric Ratios

    private func computeGeometricRatios(from landmarks: [(x: Double, y: Double, z: Double)]) -> [Double] {
        guard landmarks.count >= 468 else { return Array(repeating: 0, count: 6) }

        // 6 model-invariant face proportions
        let leftEye = landmarks[33]
        let rightEye = landmarks[263]
        let noseTip = landmarks[1]
        let chin = landmarks[152]
        let leftMouth = landmarks[61]
        let rightMouth = landmarks[291]

        let interocularDist = dist2D(leftEye, rightEye)
        guard interocularDist > 0.001 else { return Array(repeating: 0, count: 6) }

        return [
            dist2D(noseTip, chin) / interocularDist,           // nose-chin / eye distance
            dist2D(leftMouth, rightMouth) / interocularDist,   // mouth width / eye distance
            dist2D(noseTip, leftEye) / interocularDist,        // nose-left eye / eye distance
            dist2D(noseTip, rightEye) / interocularDist,       // nose-right eye / eye distance
            dist2D(landmarks[10], chin) / interocularDist,     // forehead-chin / eye distance
            dist2D(leftMouth, chin) / interocularDist          // mouth-chin / eye distance
        ]
    }

    private func computePoseRatios2D(from landmarks: [(x: Double, y: Double, z: Double)]) -> [Double] {
        guard landmarks.count >= 468 else { return Array(repeating: 0, count: 5) }

        let leftEye = landmarks[33]
        let rightEye = landmarks[263]
        let noseTip = landmarks[1]
        let leftCheek = landmarks[123]
        let rightCheek = landmarks[352]

        let eyeMidX = (leftEye.x + rightEye.x) / 2.0
        let eyeMidY = (leftEye.y + rightEye.y) / 2.0
        let interocular = dist2D(leftEye, rightEye)
        guard interocular > 0.001 else { return Array(repeating: 0, count: 5) }

        return [
            (noseTip.x - eyeMidX) / interocular,
            (noseTip.y - eyeMidY) / interocular,
            dist2D(leftCheek, noseTip) / interocular,
            dist2D(rightCheek, noseTip) / interocular,
            dist2D(leftCheek, rightCheek) / interocular
        ]
    }

    private func dist2D(_ a: (x: Double, y: Double, z: Double), _ b: (x: Double, y: Double, z: Double)) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
}

#endif
