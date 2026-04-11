#if canImport(CryptoKit)
import XCTest
@testable import UseSenseSDK

/// Tests for `BindingProofGenerator.formatCanonicalDouble`, the Double-to-string
/// serializer that feeds every byte into `meshDigest`. The function has to match
/// JavaScript's `JSON.stringify` (really `Number.prototype.toString()`) exactly
/// because the backend validator at
/// `usesense-watchtower/supabase/functions/watchtower-api/mesh-integrity-validator.tsx`
/// re-computes the mesh digest from the uploaded numbers via `JSON.stringify`,
/// and any byte-level divergence breaks the binding-proof HMAC.
///
/// The expected outputs in this file are Node.js / V8 / JS spec outputs for
/// `JSON.stringify(value)`. Verified interactively against Node 20 (2026 era):
///
///     > JSON.stringify(1e-6)   // "0.000001"
///     > JSON.stringify(1e-7)   // "1e-7"
///     > JSON.stringify(1e20)   // "100000000000000000000"
///     > JSON.stringify(1e21)   // "1e+21"
///     > JSON.stringify(1.0)    // "1"
///     > JSON.stringify(-0.0)   // "0"
///     > JSON.stringify(NaN)    // "null"
///
/// Any failing case here is a regression that will silently reject live iOS
/// sessions in production — the failure mode is a binding-tier mismatch with
/// no explanation in the error response body.
final class FormatCanonicalDoubleTests: XCTestCase {

    // MARK: - Basics

    func testZeroAndNegativeZero() {
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(0.0), "0")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-0.0), "0")
    }

    func testNonFinite() {
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(.nan), "null")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(.infinity), "null")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-.infinity), "null")
    }

    func testSmallIntegerValues() {
        // JS strips the ".0" from integer-valued floats.
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1.0), "1")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1.0), "-1")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(100.0), "100")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-42.0), "-42")
    }

    func testSimpleFractions() {
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(0.1), "0.1")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-0.1), "-0.1")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(0.5), "0.5")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1.5), "1.5")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-0.12345), "-0.12345")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(3.14159), "3.14159")
    }

    // MARK: - Small-magnitude cliff (1e-4 .. 1e-7)

    /// Swift's String(Double) switches to scientific notation at ~1e-4 but JS
    /// stays in fixed notation until 1e-7. These four values fall into the
    /// divergent zone and used to serialize differently.

    func testSmallMagnitudeInFixedRange() {
        // |x| in [1e-6, 1) — JS uses fixed notation. Swift may or may not.
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e-4), "0.0001")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e-5), "0.00001")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e-6), "0.000001")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1e-4), "-0.0001")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1e-5), "-0.00001")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1e-6), "-0.000001")
    }

    func testSmallMagnitudeInScientificRange() {
        // |x| < 1e-6 — JS uses scientific with a compact exponent (no leading zero).
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e-7), "1e-7")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e-8), "1e-8")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e-10), "1e-10")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1e-7), "-1e-7")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1e-8), "-1e-8")
    }

    func testSmallMagnitudeMantissaExpansion() {
        // Mantissas with a fractional part must be expanded into the full
        // positional decimal when JS uses fixed notation.
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1.23e-5), "0.0000123")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1.23e-5), "-0.0000123")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1.234e-6), "0.000001234")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1.234e-6), "-0.000001234")
    }

    func testSmallMagnitudeMantissaInScientific() {
        // Mantissas with a fractional part in the scientific range keep the
        // dot but shed the leading-zero exponent.
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1.23e-7), "1.23e-7")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1.23e-7), "-1.23e-7")
    }

    // MARK: - Large-magnitude cliff (1e17 .. 1e21)

    /// Swift's String(Double) switches to scientific notation somewhere around
    /// 1e17 but JS stays in fixed (decimal) notation all the way up to 1e21.
    /// These are the values in the divergent zone.

    func testLargeMagnitudeInFixedRange() {
        // |x| in [1e17, 1e21) — JS uses fixed integer notation.
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e17), "100000000000000000")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e18), "1000000000000000000")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e19), "10000000000000000000")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e20), "100000000000000000000")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1e20), "-100000000000000000000")
    }

    func testLargeMagnitudeWithFractionalMantissa() {
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1.5e20), "150000000000000000000")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1.5e20), "-150000000000000000000")
    }

    func testLargeMagnitudeInScientificRange() {
        // |x| >= 1e21 — JS uses scientific notation with an explicit "+" sign
        // on positive exponents.
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e21), "1e+21")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(1e22), "1e+22")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1e21), "-1e+21")
    }

    // MARK: - Shape-param production range

    /// The orthonormal projection in `OnDevice3DMMFitter` produces shape params
    /// in roughly [-0.3, 0.3]. These values fall inside Swift's native "fixed
    /// notation happy path" so the function just strips trailing `.0` (if any)
    /// and returns the Swift string unchanged. These tests catch a regression
    /// where someone breaks the fast path for the range that actually matters
    /// in practice.

    func testProductionShapeParamRange() {
        // Real values observed in production sessions.
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-0.024359098246481768), "-0.024359098246481768")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(0.06907142511302373), "0.06907142511302373")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-0.2907166959464121), "-0.2907166959464121")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(0.1271023302994762), "0.1271023302994762")
        // Real pose values (yaw/pitch/roll in degrees).
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-1.5670216083526611), "-1.5670216083526611")
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(-6.429241597652435), "-6.429241597652435")
        // Real depth plausibility.
        XCTAssertEqual(BindingProofGenerator.formatCanonicalDouble(91.46919540650092), "91.46919540650092")
    }

    // MARK: - meshDigest reproducibility

    func testMeshDigestIsDeterministic() {
        let shape: [Double] = [
            -0.024359098246481768, 0.06907142511302373, -0.04135227409639821,
            -0.1049513493716843, -0.1050226838828537, -0.2907166959464121,
            0.011467476260460177, 0.1271023302994762, 0.07579930411184385,
            -0.11210705280264638, -0.057633674354477915, -0.056385470528509014
        ]
        let pose = HeadPose(yaw: -1.5670216083526611, pitch: -6.429241597652435, roll: -1.115832029804103)

        let first = BindingProofGenerator.meshDigest(
            shapeParams: shape, pose: pose, depthPlausibility: 91.46919540650092, landmarkCount: 468
        )
        let second = BindingProofGenerator.meshDigest(
            shapeParams: shape, pose: pose, depthPlausibility: 91.46919540650092, landmarkCount: 468
        )
        XCTAssertEqual(first, second)
    }

    /// Verified against Node 20:
    ///
    ///     node -e '
    ///       const crypto = require("crypto");
    ///       const canonical = JSON.stringify({
    ///         s: [-0.024359098246481768,0.06907142511302373,-0.04135227409639821,
    ///             -0.1049513493716843,-0.1050226838828537,-0.2907166959464121,
    ///             0.011467476260460177,0.1271023302994762,0.07579930411184385,
    ///             -0.11210705280264638,-0.057633674354477915,-0.056385470528509014],
    ///         p: [-1.5670216083526611,-6.429241597652435,-1.115832029804103],
    ///         d: 91.46919540650092, l: "none"
    ///       });
    ///       console.log(crypto.createHash("sha256").update(canonical).digest("hex"));
    ///     '
    ///     // → cea707c90b432fa289a32b7a0f95519fa93cd27f4829d1592f44480014d8d263
    ///
    /// If this assertion fails, either the canonical format drifted on the
    /// Swift side or the Swift numeric serializer diverged from Node's.
    /// Either way the binding-tier HMAC will mismatch on the server.
    func testMeshDigestMatchesJSReferenceVector() {
        let shape: [Double] = [
            -0.024359098246481768, 0.06907142511302373, -0.04135227409639821,
            -0.1049513493716843, -0.1050226838828537, -0.2907166959464121,
            0.011467476260460177, 0.1271023302994762, 0.07579930411184385,
            -0.11210705280264638, -0.057633674354477915, -0.056385470528509014
        ]
        let pose = HeadPose(yaw: -1.5670216083526611, pitch: -6.429241597652435, roll: -1.115832029804103)
        let digest = BindingProofGenerator.meshDigest(
            shapeParams: shape, pose: pose, depthPlausibility: 91.46919540650092, landmarkCount: 468
        )
        XCTAssertEqual(digest, "cea707c90b432fa289a32b7a0f95519fa93cd27f4829d1592f44480014d8d263")
    }
}

#endif
