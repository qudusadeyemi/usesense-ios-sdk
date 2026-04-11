#if canImport(CryptoKit)
import Foundation
import CryptoKit

/// Generates cryptographic binding proofs that tie mesh data to actual JPEG frame data.
/// This prevents attackers from fabricating mesh data.
///
/// CRITICAL IMPLEMENTATION NOTES:
/// - The mesh_binding_challenge MUST be hex-decoded, NOT UTF-8 encoded
/// - Shape params MUST use Double (Float64) precision
/// - Canonical JSON format MUST match the backend's exactly, including:
///   * Field order: s, p, d, l
///   * `p` is an ARRAY [yaw, pitch, roll], NOT an object {y, p, r}
///   * `l` is the SHA-256 hex of the raw Float64 landmarks bytes when
///     landmarks are included in the verification package, otherwise the
///     literal string "none". Since the iOS SDK does NOT include landmarks
///     in verification_package.frames, we always emit "none" here and the
///     backend's computeMeshDigest() also computes "none" for the same reason.
///   * Float formatting uses the shortest-round-trip representation that
///     JavaScript's JSON.stringify produces. Swift's String(Double) is
///     compatible for most values; see formatCanonicalDouble() below.
///
/// This format must stay byte-identical to
/// usesense-watchtower/supabase/functions/watchtower-api/mesh-integrity-validator.tsx::computeMeshDigest
final class BindingProofGenerator {

    /// Compute SHA-256 hash of JPEG frame bytes.
    static func frameHash(jpegData: Data) -> String {
        let digest = SHA256.hash(data: jpegData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Format a `Double` the way JavaScript's `JSON.stringify` (really
    /// `Number.prototype.toString()`) does. This is the canonical Double
    /// serialiser for every byte fed into `meshDigest` — any divergence
    /// from JS on even a single number would make the backend's
    /// re-computed mesh digest differ from the SDK's and cause binding
    /// verification to fail.
    ///
    /// Swift's `String(Double)` uses the shortest round-trip
    /// representation (Grisu/Ryu variant), which matches JS for most
    /// values, but the two serialisers diverge at three known cliffs:
    ///
    ///   1. Small magnitudes: JS uses fixed notation for `|x| >= 1e-6`
    ///      and scientific only for `|x| < 1e-6`. Swift uses scientific
    ///      as soon as `|x| < 1e-4` (or similar, exact boundary is
    ///      implementation-defined). Values in [1e-6, 1e-4) round-trip
    ///      to different strings (Swift "1e-05" vs JS "0.00001").
    ///   2. Scientific exponent format: Swift pads the exponent to two
    ///      digits ("1e-07"); JS uses the shortest form ("1e-7"). No
    ///      leading zero between the sign and the exponent digits.
    ///   3. Large magnitudes: JS uses fixed notation for `|x| < 1e21`
    ///      and scientific for `|x| >= 1e21`. Swift switches to
    ///      scientific much earlier. Values in [1e17, 1e21) round-trip
    ///      to different strings (Swift "1e+20" vs JS "100000000000000000000").
    ///
    /// The 3DMM shape params produced by
    /// `OnDevice3DMMFitter.projectionBasis` land comfortably in
    /// [-0.3, 0.3] for a typical face, so cliff (1) is the only one
    /// that could fire in practice (when a projection row happens to
    /// be nearly orthogonal to the per-frame landmark deviation). But
    /// the function has to be bullet-proof on all three because the
    /// wire format is a cryptographic commitment: the ONE time it
    /// diverges in production will silently reject an otherwise-valid
    /// session at the binding tier.
    ///
    /// `internal` (not `private`) so unit tests in
    /// `Tests/UseSenseTests/BindingProofGeneratorTests.swift` can
    /// exercise every cliff via `@testable import UseSenseSDK`.
    static func formatCanonicalDouble(_ value: Double) -> String {
        if value == 0 { return "0" }                // handles 0.0 and -0.0
        if value.isNaN || value.isInfinite {
            // JSON.stringify encodes NaN / ±Infinity as null.
            return "null"
        }

        let absValue = abs(value)
        // JS uses fixed notation for |x| in [1e-6, 1e21), scientific
        // notation otherwise. The boundary is exact: `1e-6` is fixed,
        // `1e-7` is scientific; `1e20` is fixed, `1e21` is scientific.
        let jsWantsFixed = absValue >= 1e-6 && absValue < 1e21

        let swiftStr = String(value)

        if swiftStr.contains("e") {
            // Swift produced scientific notation.
            if jsWantsFixed {
                // JS wants fixed notation for this magnitude. Expand
                // the scientific string into a positional decimal.
                return expandScientificToFixed(swiftStr)
            } else {
                // Both agree on scientific, but Swift pads the
                // exponent with a leading zero ("1e-07"). Strip it
                // so we match JS's "1e-7".
                return normalizeScientificExponent(swiftStr)
            }
        }

        // Swift produced fixed notation. For jsWantsFixed magnitudes,
        // this already matches JS — just strip trailing ".0" for exact
        // integers, which Swift emits as "1.0" and JS emits as "1".
        if !jsWantsFixed {
            // Swift produced fixed but JS wants scientific. The only
            // way this happens is if Swift's fixed threshold is wider
            // than JS's on one side. Empirically this does not happen
            // for the ranges shape params hit, but handle it as a
            // best-effort fall-through: re-format via %e printf and
            // normalise the exponent.
            return normalizeScientificExponent(String(format: "%.17e", value))
        }
        if let dotIndex = swiftStr.firstIndex(of: ".") {
            let fraction = swiftStr[swiftStr.index(after: dotIndex)...]
            if fraction == "0" {
                return String(swiftStr[..<dotIndex])
            }
        }
        return swiftStr
    }

    /// Given a Swift-produced scientific notation string such as
    /// "1e-06" or "1.23e+21", strip the leading zero from the exponent
    /// so it matches JS's format ("1e-6" / "1.23e+21"). The exponent
    /// sign is preserved unchanged. If there is no exponent at all,
    /// the input is returned verbatim.
    private static func normalizeScientificExponent(_ s: String) -> String {
        guard let eIdx = s.firstIndex(of: "e") else { return s }
        let mantissa = String(s[..<eIdx])
        var expPart = String(s[s.index(after: eIdx)...])
        var sign = ""
        if expPart.hasPrefix("+") {
            sign = "+"
            expPart = String(expPart.dropFirst())
        } else if expPart.hasPrefix("-") {
            sign = "-"
            expPart = String(expPart.dropFirst())
        }
        // Strip leading zeros from the exponent, keeping at least one
        // digit in case the exponent is literally "0".
        while expPart.count > 1 && expPart.hasPrefix("0") {
            expPart = String(expPart.dropFirst())
        }
        return "\(mantissa)e\(sign)\(expPart)"
    }

    /// Given a Swift-produced scientific notation string such as
    /// "1.234e-06" or "-1.5e+20", expand it into a positional decimal
    /// string with the decimal point shifted by the exponent:
    ///   "1.234e-06" → "0.000001234"
    ///   "-1.5e+20"  → "-150000000000000000000"
    ///   "1e-6"      → "0.000001"
    ///
    /// The output has no leading zeros on the integer part (other
    /// than a single "0" before the decimal point when the magnitude
    /// is less than one), no trailing zeros on the fractional part,
    /// and no trailing decimal point. That matches JS's fixed-form
    /// output from `Number.prototype.toString()`.
    private static func expandScientificToFixed(_ s: String) -> String {
        guard let eIdx = s.firstIndex(of: "e") else { return s }
        var mantissa = String(s[..<eIdx])
        let expStr = String(s[s.index(after: eIdx)...])
        let exp = Int(expStr) ?? 0

        // Separate sign from the mantissa so the arithmetic below
        // operates on magnitudes.
        var sign = ""
        if mantissa.hasPrefix("-") {
            sign = "-"
            mantissa = String(mantissa.dropFirst())
        } else if mantissa.hasPrefix("+") {
            mantissa = String(mantissa.dropFirst())
        }

        // Split the mantissa into integer and fractional digits. For a
        // Swift-produced string the mantissa is always in the form
        // "D" or "D.DDD..." where the leading digit is non-zero.
        var integerPart: String
        var fractionPart: String
        if let dotIdx = mantissa.firstIndex(of: ".") {
            integerPart = String(mantissa[..<dotIdx])
            fractionPart = String(mantissa[mantissa.index(after: dotIdx)...])
        } else {
            integerPart = mantissa
            fractionPart = ""
        }

        // Concatenate the digits and compute where the decimal point
        // should land after shifting by `exp` places. Positions are
        // measured from the start of the `digits` string.
        let digits = integerPart + fractionPart
        let newDecimalPos = integerPart.count + exp

        var result: String
        if newDecimalPos <= 0 {
            // |value| < 1: "0.00...digits"
            let leadingZeros = String(repeating: "0", count: -newDecimalPos)
            result = "0." + leadingZeros + digits
        } else if newDecimalPos >= digits.count {
            // Integer: "digits00..."
            let trailingZeros = String(repeating: "0", count: newDecimalPos - digits.count)
            result = digits + trailingZeros
        } else {
            // Mixed: split `digits` at `newDecimalPos`.
            let splitIdx = digits.index(digits.startIndex, offsetBy: newDecimalPos)
            result = String(digits[..<splitIdx]) + "." + String(digits[splitIdx...])
        }

        // Trim trailing zeros from the fractional part (if any), and
        // drop a dangling decimal point left over by the trim. JS
        // never emits "1." or "1.00" from JSON.stringify.
        if result.contains(".") {
            while result.last == "0" {
                result.removeLast()
            }
            if result.last == "." {
                result.removeLast()
            }
        }

        return sign + result
    }

    /// Compute the mesh digest from canonical JSON representation.
    /// MUST match the backend's canonical format byte-for-byte.
    static func meshDigest(
        shapeParams: [Double],
        pose: HeadPose,
        depthPlausibility: Double,
        landmarkCount: Int
    ) -> String {
        // Field order: s, p, d, l (matches backend JSON.stringify key order)
        let sArray = shapeParams.map { formatCanonicalDouble($0) }.joined(separator: ",")
        let yawStr = formatCanonicalDouble(pose.yaw)
        let pitchStr = formatCanonicalDouble(pose.pitch)
        let rollStr = formatCanonicalDouble(pose.roll)
        let depthStr = formatCanonicalDouble(depthPlausibility)

        // NOTE: `p` is an ARRAY [yaw, pitch, roll], NOT an object.
        // NOTE: `l` is the literal string "none" because the iOS SDK does
        // not include raw landmarks in verification_package.frames. If that
        // ever changes, this must change to the hex SHA-256 of the raw
        // Float64 landmarks bytes to stay in sync with the backend.
        let _ = landmarkCount  // intentionally unused; kept for API compatibility
        let canonical = "{\"s\":[\(sArray)],\"p\":[\(yawStr),\(pitchStr),\(rollStr)],\"d\":\(depthStr),\"l\":\"none\"}"

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
