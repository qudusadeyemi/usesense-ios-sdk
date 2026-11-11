#if canImport(AVFoundation) && canImport(UIKit)
import Foundation

/// Assembles the complete Geometric Coherence verification package for upload.
final class VerificationPackageBuilder: @unchecked Sendable {

    /// Build the verification_package JSON dictionary for metadata upload.
    ///
    /// `fittingResults[i]` is the fit of `meshResults[i]` (nil when the fit
    /// failed); `frameHashes[i]` is the hash of uploaded JPEG `i`. Entry `k`
    /// describes upload position `i`: a frame with no mesh or no fit simply
    /// has no entry (EVIDENCE-v1 section 3), never a neighbour's data.
    ///
    /// `evidence`: add the EVIDENCE-v1 per-frame fields (raw landmarks,
    /// matrix pose under `matrix_zyx_v3`, eye blendshapes, capture-clock
    /// timestamps) and bind the landmarks into `meshDigest`.
    func build(
        meshResults: [FaceMeshResult],
        fittingResults: [ThreeDMMFitResult?],
        frameHashes: [String],
        meshBindingChallenge: String?,
        attestFields: [String: Any],
        platform: String = "ios",
        evidence: Bool = false
    ) -> [String: Any]? {
        let frameCount = min(meshResults.count, min(fittingResults.count, frameHashes.count))
        guard frameCount > 0 else { return nil }

        var frames: [[String: Any]] = []
        var usedFits: [ThreeDMMFitResult] = []
        var seenHashes = Set<String>()

        for i in 0..<frameCount {
            let mesh = meshResults[i]
            guard let fit = fittingResults[i] else { continue }
            let hash = frameHashes[i]
            // At most one entry per uploaded frame (section 3, rule 3).
            guard seenHashes.insert(hash).inserted else { continue }

            // frameIndex is the upload position `i` (the index the server sees
            // when it enumerates the multipart frames), not FaceMeshManager's
            // camera counter. The server matches entries by frameHash.
            var pose = fit.pose
            var method = Evidence.poseMethodLegacy
            var fields: EvidenceFrameFields?
            if evidence {
                let f = EvidenceFrameFields(mesh: mesh)
                fields = f
                if let mp = f.matrixPose {
                    pose = mp
                    method = Evidence.poseMethodV3
                }
            }
            var frame: [String: Any] = [
                "frameIndex": i,
                "timestamp": evidence ? Int64(mesh.captureMs) : mesh.timestampMs,
                "shapeParams": fit.shapeParams,
                "pose": [
                    "yaw": pose.yaw,
                    "pitch": pose.pitch,
                    "roll": pose.roll
                ],
                "depthPlausibility": fit.depthPlausibility,
                "geometricRatios": fit.geometricRatios,
                "poseRatios2D": fit.poseRatios2D,
                "frameHash": hash,
                "poseNormalizationMethod": method
            ]
            var landmarksHash: String?
            if let f = fields {
                if f.landmarks.count == 478 * 3 || f.landmarks.count == 468 * 3 {
                    frame["landmarks"] = f.landmarks
                    landmarksHash = Evidence.landmarksHash(f.landmarks)
                }
                if let m = f.transformMatrix { frame["transformMatrix"] = m }
                if let b = f.blendshapesJSON { frame["blendshapes"] = b }
            }

            #if canImport(CryptoKit)
            // Compute mesh digest and binding proof
            let digest = BindingProofGenerator.meshDigest(
                shapeParams: fit.shapeParams,
                pose: pose,
                depthPlausibility: fit.depthPlausibility,
                landmarksHash: landmarksHash
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
            usedFits.append(fit)
        }
        guard !frames.isEmpty else { return nil }

        // Cross-frame consistency: L2 distance between shape vectors
        let crossFrameConsistency = computeCrossFrameConsistency(fittingResults: usedFits)

        // Preliminary score: weighted combo of depth + consistency
        let avgDepth = usedFits.map(\.depthPlausibility).reduce(0, +) / Double(usedFits.count)
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
