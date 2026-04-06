#if canImport(CryptoKit)
import Foundation
import CryptoKit

/// Generates cryptographic binding proofs that tie mesh data to actual JPEG frame data.
/// This prevents attackers from fabricating mesh data.
///
/// CRITICAL IMPLEMENTATION NOTES:
/// - The mesh_binding_challenge MUST be hex-decoded, NOT UTF-8 encoded
/// - Shape params MUST use Double (Float64) precision
/// - Canonical JSON field order MUST be: s, p (y, p, r), d, l
final class BindingProofGenerator {

    /// Compute SHA-256 hash of JPEG frame bytes.
    static func frameHash(jpegData: Data) -> String {
        let digest = SHA256.hash(data: jpegData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute the mesh digest from canonical JSON representation.
    /// Field order MUST be exactly: s, p (with y, p, r), d, l
    static func meshDigest(
        shapeParams: [Double],
        pose: HeadPose,
        depthPlausibility: Double,
        landmarkCount: Int
    ) -> String {
        // Build canonical JSON with EXACT field order
        let sArray = shapeParams.map { String($0) }.joined(separator: ",")
        let canonical = "{\"s\":[\(sArray)],\"p\":{\"y\":\(pose.yaw),\"p\":\(pose.pitch),\"r\":\(pose.roll)},\"d\":\(depthPlausibility),\"l\":\(landmarkCount)}"

        let data = Data(canonical.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Generate the HMAC-SHA256 binding proof.
    ///
    /// - Parameters:
    ///   - meshBindingChallenge: 32-byte hex string from session creation response
    ///   - frameHash: SHA-256 hex of the JPEG frame bytes
    ///   - meshDigest: SHA-256 hex of the canonical mesh JSON
    /// - Returns: Hex-encoded HMAC-SHA256 signature
    ///
    /// CRITICAL: The challenge MUST be hex-decoded (not UTF-8 encoded).
    /// Using String.data(using: .utf8) instead of hex decoding will cause
    /// the binding proof to never validate on the server.
    static func generateBindingProof(
        meshBindingChallenge: String,
        frameHash: String,
        meshDigest: String
    ) -> String {
        // MUST use hex decode, NOT TextEncoder/UTF-8
        let challengeBytes = SymmetricKey(data: Data(hexString: meshBindingChallenge))

        // Message format: "frameHash:meshDigest" (colon-separated)
        let message = "\(frameHash):\(meshDigest)"
        let messageData = Data(message.utf8)

        let signature = HMAC<SHA256>.authenticationCode(for: messageData, using: challengeBytes)
        return Data(signature).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Hex String Extension

extension Data {
    /// Initialize Data from a hex-encoded string.
    /// CRITICAL: This is the correct way to decode the mesh_binding_challenge.
    init(hexString: String) {
        self.init()
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                append(byte)
            }
            index = nextIndex
        }
    }
}
#endif
