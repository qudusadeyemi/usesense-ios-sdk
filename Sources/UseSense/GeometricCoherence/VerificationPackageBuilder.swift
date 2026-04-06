#if canImport(AVFoundation) && canImport(UIKit)
import Foundation

/// Assembles the complete Geometric Coherence verification package for upload.
final class VerificationPackageBuilder: @unchecked Sendable {

    /// Build the verification_package JSON dictionary for metadata upload.
    func build(
        meshResults: [FaceMeshResult],
        fittingResults: [ThreeDMMFitResult],
        frameHashes: [String],
        meshBindingChallenge: String?,
        attestFields: [String: Any],
        platform: String = "ios"
    ) -> [String: Any]? {
        guard !meshResults.isEmpty, !fittingResults.isEmpty else { return nil }

        let frameCount = min(meshResults.count, min(fittingResults.count, frameHashes.count))
        guard frameCount > 0 else { return nil }

        var frames: [[String: Any]] = []

        for i in 0..<frameCount {
            let mesh = meshResults[i]
            let fit = fittingResults[i]
            let hash = frameHashes[i]

            var frame: [String: Any] = [
                "frameIndex": mesh.frameIndex,
                "timestamp": mesh.timestampMs,
                "shapeParams": fit.shapeParams,
                "pose": [
                    "yaw": fit.pose.yaw,
                    "pitch": fit.pose.pitch,
                    "roll": fit.pose.roll
                ],
                "depthPlausibility": fit.depthPlausibility,
                "geometricRatios": fit.geometricRatios,
                "poseRatios2D": fit.poseRatios2D,
                "frameHash": hash,
                "poseNormalizationMethod": "mediapipe_zyx_v2"
            ]

            #if canImport(CryptoKit)
            // Compute mesh digest and binding proof
            let digest = BindingProofGenerator.meshDigest(
                shapeParams: fit.shapeParams,
                pose: fit.pose,
                depthPlausibility: fit.depthPlausibility,
                landmarkCount: mesh.landmarks.count
            )
            frame["meshDigest"] = digest

            if let challenge = meshBindingChallenge {
                let proof = BindingProofGenerator.generateBindingProof(
                    meshBindingChallenge: challenge,
                    frameHash: hash,
                    meshDigest: digest
                )
                frame["bindingProof"] = proof
            }
            #endif

            frames.append(frame)
        }

        // Cross-frame consistency: L2 distance between shape vectors
        let crossFrameConsistency = computeCrossFrameConsistency(fittingResults: Array(fittingResults.prefix(frameCount)))

        // Preliminary score: weighted combo of depth + consistency
        let avgDepth = fittingResults.prefix(frameCount).map(\.depthPlausibility).reduce(0, +) / Double(frameCount)
        let preliminaryScore = avgDepth * 0.6 + crossFrameConsistency * 0.4

        // Build attestation
        var attestation: [String: Any] = ["platform": platform]
        if let token = attestFields["app_attest_assertion"] as? String {
            attestation["token"] = token
        }
        if let keyId = attestFields["app_attest_key_id"] as? String {
            attestation["keyId"] = keyId
        }

        return [
            "frames": frames,
            "crossFrameConsistency": crossFrameConsistency,
            "preliminaryScore": preliminaryScore,
            "attestation": attestation
        ]
    }

    // MARK: - Cross-Frame Consistency

    private func computeCrossFrameConsistency(fittingResults: [ThreeDMMFitResult]) -> Double {
        guard fittingResults.count >= 2 else { return 100.0 }

        var totalDistance: Double = 0
        var comparisons = 0

        for i in 0..<fittingResults.count {
            for j in (i+1)..<fittingResults.count {
                let a = fittingResults[i].shapeParams
                let b = fittingResults[j].shapeParams
                let count = min(a.count, b.count)
                var sumSq: Double = 0
                for k in 0..<count {
                    let diff = a[k] - b[k]
                    sumSq += diff * diff
                }
                totalDistance += sqrt(sumSq)
                comparisons += 1
            }
        }

        guard comparisons > 0 else { return 100.0 }
        let avgDistance = totalDistance / Double(comparisons)

        // Convert distance to 0-100 score (lower distance = higher consistency)
        return max(0, min(100, 100.0 - avgDistance * 500.0))
    }
}

#endif
