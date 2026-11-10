#if canImport(CryptoKit) && canImport(UIKit)
import XCTest
import SwiftUI
@testable import UseSenseSDK

/// EVIDENCE-v1 (capture-test-kit/EVIDENCE-v1.md): the `evidence` decoder, the
/// per-frame fields, the binding v2 digest and the capability flags. The
/// golden values marked "server" were computed by running Watchtower's own
/// `computeMeshDigest` and `evidenceDigestText` (origin/staging) under Deno on
/// the JSON this file builds (see `serverCrossCheckPackage`).
final class EvidenceTests: XCTestCase {

    // MARK: - Decoder (section 1)

    private func decodeSession(evidence: String?) throws -> CreateSessionResponse {
        let block = evidence.map { ", \"evidence\": \($0)" } ?? ""
        let json = """
        {"session_id":"s1","session_token":"t","expires_at":"2026-11-10T12:00:00.000Z","nonce":"n",
         "policy":{"requires_audio":false,"requires_stepup":false,"challenge_type":"none"},
         "upload":{"max_frames":24,"target_fps":8,"capture_duration_ms":3000}\(block)}
        """
        return try JSONDecoder().decode(CreateSessionResponse.self, from: Data(json.utf8))
    }

    static let fullBlock = """
    {"contract":"evidence-v1",
     "colour_sequence":{"id":"cs_7f3a9c21","colours":["#3D6BFF","#ffd23f","#B04DFF"],"segment_ms":600,"lead_in_ms":300,"opacity":0.35},
     "closer_step":{"enabled":true,"target_scale":1.4,"min_scale":1.25},
     "binding_v2":{"enabled":true},
     "landmarks":{"required":true,"format":"mp_norm_v1"}}
    """

    func testOldServerWithoutEvidenceStillDecodes() throws {
        let r = try decodeSession(evidence: nil)
        XCTAssertNil(r.evidence)
        XCTAssertNil(SessionData(from: r).evidence)
    }

    func testFullBlockDecodes() throws {
        let e = try XCTUnwrap(try decodeSession(evidence: Self.fullBlock).evidence)
        XCTAssertEqual(e.contract, "evidence-v1")
        XCTAssertEqual(e.colourSequence?.id, "cs_7f3a9c21")
        // Colours are uppercased; order is the server's.
        XCTAssertEqual(e.colourSequence?.colours, ["#3D6BFF", "#FFD23F", "#B04DFF"])
        XCTAssertEqual(e.colourSequence?.segmentMs, 600)
        XCTAssertEqual(e.colourSequence?.leadInMs, 300)
        XCTAssertEqual(e.colourSequence?.opacity, 0.35)
        XCTAssertEqual(e.colourSequence?.totalMs, 2100)
        XCTAssertEqual(e.closerStep, .init(enabled: true, targetScale: 1.4, minScale: 1.25))
        XCTAssertTrue(e.bindingV2Enabled)
        XCTAssertTrue(e.landmarksRequired)
        XCTAssertTrue(e.closerEnabled)
    }

    func testOtherContractIsAbsent() throws {
        XCTAssertNil(try decodeSession(evidence: #"{"contract":"evidence-v2","binding_v2":{"enabled":true}}"#).evidence)
        XCTAssertNil(try decodeSession(evidence: #"{"binding_v2":{"enabled":true}}"#).evidence)
        XCTAssertNil(try decodeSession(evidence: "null").evidence)
        XCTAssertNil(try decodeSession(evidence: "[1,2]").evidence)
        XCTAssertNil(try decodeSession(evidence: #""evidence-v1""#).evidence)
    }

    func testEveryKeyOptionalAndUnknownKeysIgnored() throws {
        let e = try XCTUnwrap(try decodeSession(evidence: #"{"contract":"evidence-v1","future_key":{"x":1},"depth":[1]}"#).evidence)
        XCTAssertNil(e.colourSequence)
        XCTAssertNil(e.closerStep)
        XCTAssertFalse(e.bindingV2Enabled)
        XCTAssertFalse(e.landmarksRequired)
        XCTAssertFalse(e.closerEnabled)

        let partial = try XCTUnwrap(try decodeSession(evidence: """
        {"contract":"evidence-v1","colour_sequence":{"id":"cs_1","colours":["#22C55E","#FF4D4D","#00C2D1"],"new":true},
         "closer_step":{"enabled":false},"binding_v2":{"enabled":"yes"}}
        """).evidence)
        // Server defaults fill missing timings; a mistyped flag reads as off.
        XCTAssertEqual(partial.colourSequence?.segmentMs, 600)
        XCTAssertEqual(partial.colourSequence?.leadInMs, 300)
        XCTAssertEqual(partial.colourSequence?.opacity, 0.35)
        XCTAssertEqual(partial.closerStep?.enabled, false)
        XCTAssertEqual(partial.closerStep?.targetScale, 1.4)
        XCTAssertFalse(partial.bindingV2Enabled)
    }

    func testMalformedSubBlocksDropOnlyThemselves() throws {
        let e = try XCTUnwrap(try decodeSession(evidence: """
        {"contract":"evidence-v1","colour_sequence":{"id":"cs_1","colours":["blue","#FFD23F"]},
         "closer_step":"on","binding_v2":{"enabled":true}}
        """).evidence)
        XCTAssertNil(e.colourSequence, "a colour that isn't #RRGGBB makes the sequence unplayable")
        XCTAssertNil(e.closerStep)
        XCTAssertTrue(e.bindingV2Enabled)
        XCTAssertNil(try decodeSession(evidence: ##"{"contract":"evidence-v1","colour_sequence":{"colours":["#3D6BFF"]}}"##)
            .evidence?.colourSequence, "a sequence needs an id")
    }

    func testHostedInitDecodesEvidenceAndKeepsWorkingWithout() throws {
        let base = """
        "success":true,"session_id":"s","session_token":"t","nonce":"n",
        "policy":{"requires_audio":false,"requires_stepup":false,"challenge_type":"none"},
        "upload":{"max_frames":24,"target_fps":8,"capture_duration_ms":3000}
        """
        let old = try JSONDecoder().decode(HostedInitSessionResponse.self, from: Data("{\(base)}".utf8))
        XCTAssertNil(old.toCreateSessionResponse().evidence)
        let new = try JSONDecoder().decode(HostedInitSessionResponse.self,
                                           from: Data("{\(base),\"evidence\":\(Self.fullBlock)}".utf8))
        XCTAssertEqual(new.toCreateSessionResponse().evidence?.colourSequence?.id, "cs_7f3a9c21")
    }

    func testEvidenceRoundTripsThroughEncode() throws {
        let e = try XCTUnwrap(try decodeSession(evidence: Self.fullBlock).evidence)
        let again = try JSONDecoder().decode(EvidenceConfig.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(again, e)
    }

    // MARK: - Rounding and hashing (section 4)

    func testRoundingFiveDecimals() {
        XCTAssertEqual(Evidence.round(0.123456789, 5), 0.12346)
        XCTAssertEqual(Evidence.round(-0.000004, 5), 0)
        XCTAssertEqual(Evidence.round(0.000005, 5), 0.00001)
        XCTAssertEqual(Evidence.round(1.5, 0), 2)
        XCTAssertEqual(Evidence.round(.nan, 5), 0)
        XCTAssertEqual(Evidence.round(0.0412, 3), 0.041)
        XCTAssertEqual(Evidence.round(-0.0, 5).sign, .plus)
    }

    /// server: crypto.subtle.digest("SHA-256", new Float64Array([0.5, -1, 0.12346]).buffer)
    func testLandmarksHashIsFloat64LittleEndian() {
        XCTAssertEqual(Evidence.landmarksHash([0.5, -1, 0.12346]), Self.float64Golden)
        XCTAssertNil(Evidence.landmarksHash([]))
    }

    static let float64Golden = "1e2bb76954bd77bd1a69f9a6df16651fa59b50d856b558cec139cdc64273e786"

    func testMatrixPoseIsTheServerFormula() throws {
        // Rz(roll 10) * Ry(yaw 20) * Rx(pitch -5), row-major 4x4.
        let d = Double.pi / 180
        let (y, p, r) = (20 * d, -5 * d, 10 * d)
        let rz: [[Double]] = [[cos(r), -sin(r), 0], [sin(r), cos(r), 0], [0, 0, 1]]
        let ry: [[Double]] = [[cos(y), 0, sin(y)], [0, 1, 0], [-sin(y), 0, cos(y)]]
        let rx: [[Double]] = [[1, 0, 0], [0, cos(p), -sin(p)], [0, sin(p), cos(p)]]
        func mul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
            (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
        }
        let m3 = mul(mul(rz, ry), rx)
        var m = [Double](repeating: 0, count: 16)
        for i in 0..<3 { for j in 0..<3 { m[i * 4 + j] = m3[i][j] } }
        m[15] = 1
        let pose = try XCTUnwrap(Evidence.matrixPose(m))
        XCTAssertEqual(pose.yaw, 20, accuracy: 1e-9)
        XCTAssertEqual(pose.pitch, -5, accuracy: 1e-9)
        XCTAssertEqual(pose.roll, 10, accuracy: 1e-9)
        // Agrees with the gate's own formula away from gimbal lock.
        let gate = FaceMeshManager.zyxPose { m[$0 * 4 + $1] }
        XCTAssertEqual(gate.yaw, pose.yaw, accuracy: 1e-9)
        XCTAssertNil(Evidence.matrixPose(Array(m.prefix(9))))
    }

    // MARK: - Per-frame fields (sections 3 to 5)

    /// A deterministic 478-point mesh, a matrix and blendshapes.
    static func mesh(seed: Int, captureMs: Int, matrix: Bool = true) -> FaceMeshResult {
        let lm: [(x: Double, y: Double, z: Double)] = (0..<478).map { i in
            let a = Double(i * 7 + seed)
            return (x: 0.3 + 0.4 * (sin(a) + 1) / 2 + 0.0000123, y: 0.25 + 0.5 * (cos(a * 1.3) + 1) / 2, z: -0.05 * sin(a * 0.7))
        }
        var gate = FaceGateSignals(faceCount: 1, matrixPose: nil, eyeBlinkLeft: 0.04123, eyeBlinkRight: 0.0625)
        if matrix {
            let t = Double(seed) * 0.01
            gate.transformMatrix = [cos(t), -sin(t), 0.0012345678, 0.5,
                                    sin(t), cos(t), 0.0234567891, -1.25,
                                    -0.0012345678, -0.0234567891, 0.9997, -40.123456789,
                                    0, 0, 0, 1]
        }
        return FaceMeshResult(frameIndex: seed, timestampMs: 98_765_000 + Int64(seed), captureMs: captureMs,
                              headPose: HeadPose(yaw: 1, pitch: 2, roll: 3), leftEAR: 0.3, rightEAR: 0.3,
                              bbox: NormalizedRect(x: 0.3, y: 0.25, w: 0.4, h: 0.5), landmarks: lm, gate: gate)
    }

    static func fit(_ k: Int) -> ThreeDMMFitResult {
        ThreeDMMFitResult(shapeParams: (0..<12).map { Double($0 - 6) * 0.01 + Double(k) * 0.001 },
                          pose: HeadPose(yaw: 1, pitch: 2, roll: 3), depthPlausibility: 72.5,
                          geometricRatios: [0.4, 0.5, 0.6, 0.7, 0.8, 0.9], poseRatios2D: [1, 1.1, 1.2, 1.3, 1.4])
    }

    static func hash(_ k: Int) -> String { String(repeating: String(format: "%x", k % 16), count: 64) }

    private func package(evidence: Bool, fits: [ThreeDMMFitResult?]? = nil, hashes: [String]? = nil) throws -> [[String: Any]] {
        let meshes = (0..<4).map { Self.mesh(seed: $0, captureMs: 1000 + $0 * 83, matrix: $0 != 3) }
        let pkg = try XCTUnwrap(VerificationPackageBuilder().build(
            meshResults: meshes, fittingResults: fits ?? (0..<4).map { Self.fit($0) },
            frameHashes: hashes ?? (0..<4).map(Self.hash), meshBindingChallenge: "00ff", attestFields: [:],
            evidence: evidence))
        return try XCTUnwrap(pkg["frames"] as? [[String: Any]])
    }

    func testEvidenceFramesCarryLandmarksMatrixPoseAndEyes() throws {
        let frames = try package(evidence: true)
        XCTAssertEqual(frames.count, 4)
        let f0 = frames[0]
        let lm = try XCTUnwrap(f0["landmarks"] as? [Double])
        XCTAssertEqual(lm.count, 478 * 3)
        XCTAssertTrue(lm.allSatisfy { Evidence.round($0, 5) == $0 }, "landmarks are sent at 5 decimals")
        let raw = Self.mesh(seed: 0, captureMs: 0).landmarks[0]
        XCTAssertEqual(lm[0], Evidence.round(raw.x, 5), "x is the JPEG-space value, not mirrored")
        XCTAssertEqual(lm[1], Evidence.round(raw.y, 5))
        XCTAssertEqual(f0["poseNormalizationMethod"] as? String, "matrix_zyx_v3")
        let m = try XCTUnwrap(f0["transformMatrix"] as? [Double])
        XCTAssertEqual(m.count, 16)
        XCTAssertEqual(m[2], 0.00123)
        XCTAssertEqual(m[11], -40.12346)
        let pose = try XCTUnwrap(f0["pose"] as? [String: Double])
        let expected = try XCTUnwrap(Evidence.matrixPose(m))
        XCTAssertEqual(pose["yaw"], expected.yaw, "pose is recomputable from the uploaded (rounded) matrix")
        XCTAssertEqual(pose["pitch"], expected.pitch)
        XCTAssertEqual(pose["roll"], expected.roll)
        XCTAssertEqual(f0["blendshapes"] as? [String: Double], ["eyeBlinkLeft": 0.041, "eyeBlinkRight": 0.063])
        XCTAssertEqual(f0["timestamp"] as? Int64, 1000, "capture clock, not camera PTS")
        // No matrix: legacy label and pose, but landmarks still go.
        XCTAssertEqual(frames[3]["poseNormalizationMethod"] as? String, "mediapipe_zyx_v2")
        XCTAssertNil(frames[3]["transformMatrix"])
        XCTAssertNotNil(frames[3]["landmarks"])
    }

    func testWithoutEvidenceThePackageIsUnchanged() throws {
        let frames = try package(evidence: false)
        for f in frames {
            XCTAssertNil(f["landmarks"])
            XCTAssertNil(f["transformMatrix"])
            XCTAssertNil(f["blendshapes"])
            XCTAssertEqual(f["poseNormalizationMethod"] as? String, "mediapipe_zyx_v2")
        }
        XCTAssertEqual(frames[0]["timestamp"] as? Int64, 98_765_000)
        let fit = Self.fit(0)
        XCTAssertEqual(frames[0]["meshDigest"] as? String,
                       BindingProofGenerator.meshDigest(shapeParams: fit.shapeParams, pose: fit.pose,
                                                        depthPlausibility: fit.depthPlausibility))
    }

    func testFrameIndexIsUploadPositionWithNoCopiedMesh() throws {
        // Frame 1's fit failed: it has no entry, and frame 2 keeps index 2.
        let fits: [ThreeDMMFitResult?] = [Self.fit(0), nil, Self.fit(2), Self.fit(3)]
        let frames = try package(evidence: true, fits: fits)
        XCTAssertEqual(frames.map { $0["frameIndex"] as? Int }, [0, 2, 3])
        XCTAssertEqual(frames.map { $0["frameHash"] as? String }, [Self.hash(0), Self.hash(2), Self.hash(3)])
        // Two uploads with the same bytes: one entry only.
        let dup = try package(evidence: true, hashes: [Self.hash(0), Self.hash(0), Self.hash(2), Self.hash(3)])
        XCTAssertEqual(dup.map { $0["frameIndex"] as? Int }, [0, 2, 3])
        // Fewer uploaded frames than meshes (cap): entries stop at the upload.
        let capped = try package(evidence: true, hashes: [Self.hash(0), Self.hash(1)])
        XCTAssertEqual(capped.map { $0["frameIndex"] as? Int }, [0, 1])
    }

    func testMeshDigestBindsTheRoundedLandmarks() throws {
        let f0 = try package(evidence: true)[0]
        let lm = try XCTUnwrap(f0["landmarks"] as? [Double])
        let pose = try XCTUnwrap(f0["pose"] as? [String: Double])
        let fit = Self.fit(0)
        let expected = BindingProofGenerator.meshDigest(
            shapeParams: fit.shapeParams,
            pose: HeadPose(yaw: pose["yaw"]!, pitch: pose["pitch"]!, roll: pose["roll"]!),
            depthPlausibility: fit.depthPlausibility, landmarksHash: Evidence.landmarksHash(lm))
        XCTAssertEqual(f0["meshDigest"] as? String, expected)
        XCTAssertEqual(f0["bindingProof"] as? String, BindingProofGenerator.generateBindingProof(
            meshBindingChallenge: "00ff", frameHash: Self.hash(0), meshDigest: expected))
    }

    /// The server hashes the numbers JSON.parse reads from our JSON text.
    /// (Foundation's own JSON parser is not correctly rounded, so parse the
    /// written tokens with Double(String), which is.) The Deno cross-check
    /// behind `serverDigestGolden` covers the same on the server's code.
    func testRoundedValuesSurviveJSONSerialization() throws {
        let lm = try XCTUnwrap(try package(evidence: true)[0]["landmarks"] as? [Double])
        let data = try JSONSerialization.data(withJSONObject: ["l": lm])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let body = text.drop { $0 != "[" }.dropFirst().prefix { $0 != "]" }
        let parsed = body.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(parsed, lm)
    }

    // MARK: - Binding v2 digest (section 8)

    func testDigestGoldenVector() {
        let text = EvidenceDigest.text(sessionId: "s", challenge: "c", frames: [], colour: nil, closer: nil)
        XCTAssertEqual(text, "usesense-evidence-v1\nsession:s\nchallenge:c\ncolour:none\ncloser:none")
        XCTAssertEqual(EvidenceDigest.digest(sessionId: "s", challenge: "c", frames: [], colour: nil, closer: nil),
                       "42c6249ed7be90ff3d6c4f64e9fe507bd0b6d79298c96d051394ac520828ba78")
    }

    func testDigestLines() {
        var colour = ColourEvidence(sequenceId: "cs_7f3a9c21")
        colour.segments = [.init(colour: "#3D6BFF", startMs: 1830, endMs: 2431),
                           .init(colour: "#FFD23F", startMs: 2431, endMs: 3030)]
        let closer = CloserEvidence(farFrames: [14, 15, 16], nearFrames: [21, 22, 23], completed: true)
        let text = EvidenceDigest.text(sessionId: "sess", challenge: "ab",
                                       frames: [.init(frameIndex: 0, frameHash: "h0", meshDigest: "d0"),
                                                .init(frameIndex: 2, frameHash: "h2", meshDigest: "d2")],
                                       colour: colour, closer: closer)
        XCTAssertEqual(text, """
        usesense-evidence-v1
        session:sess
        challenge:ab
        frame:0:h0:d0
        frame:2:h2:d2
        colour:cs_7f3a9c21:#3D6BFF@1830-2431,#FFD23F@2431-3030
        closer:14,15,16|21,22,23
        """)
        // A sequence that never showed a colour, and a timed-out closer.
        let none = EvidenceDigest.text(sessionId: "s", challenge: "c", frames: [],
                                       colour: ColourEvidence(sequenceId: "cs_1"), closer: .skipped(.timeout))
        XCTAssertTrue(none.hasSuffix("colour:none\ncloser:none"))
    }

    func testDigestFramesReadThePackageInOrder() throws {
        let frames = try package(evidence: true, fits: [Self.fit(0), nil, Self.fit(2), Self.fit(3)])
        let d = EvidenceDigest.frames(fromPackage: ["frames": frames])
        XCTAssertEqual(d.map(\.frameIndex), [0, 2, 3])
        XCTAssertEqual(d.first?.meshDigest, frames[0]["meshDigest"] as? String)
    }

    /// The same package and evidence the Deno cross-check ran on, against the
    /// digest Watchtower's `evidenceDigestText` + `sha256Hex` produced.
    func testDigestMatchesServerOnARealPackage() throws {
        let (pkg, colour, closer) = try serverCrossCheckPackage()
        let digest = EvidenceDigest.digest(sessionId: "sess_x", challenge: "a1b2c3",
                                           frames: EvidenceDigest.frames(fromPackage: pkg), colour: colour, closer: closer)
        XCTAssertEqual(digest, Self.serverDigestGolden)
    }

    static let serverDigestGolden = "3b2a37b2328e6e52f32273595a7498ea556515fc4dca48b3984c62c6d5a1f5ab"

    private func serverCrossCheckPackage() throws -> ([String: Any], ColourEvidence, CloserEvidence) {
        let meshes = (0..<4).map { Self.mesh(seed: $0, captureMs: 1000 + $0 * 83, matrix: $0 != 3) }
        let pkg = try XCTUnwrap(VerificationPackageBuilder().build(
            meshResults: meshes, fittingResults: (0..<4).map { Self.fit($0) },
            frameHashes: (0..<4).map(Self.hash), meshBindingChallenge: "a1b2c3", attestFields: [:], evidence: true))
        var colour = ColourEvidence(sequenceId: "cs_7f3a9c21")
        colour.segments = [.init(colour: "#3D6BFF", startMs: 1300, endMs: 1901),
                           .init(colour: "#FFD23F", startMs: 1901, endMs: 2500),
                           .init(colour: "#B04DFF", startMs: 2500, endMs: 3102)]
        colour.completed = true
        colour.screenBrightness = 1
        colour.awbLocked = true
        let closer = CloserEvidence(farFrames: [0, 1], nearFrames: [2, 3], startedAtMs: 3200, endedAtMs: 4100,
                                    achievedScale: 1.31, completed: true)
        if let out = ProcessInfo.processInfo.environment["EVIDENCE_DUMP"] {
            let block = EvidenceUploadBlock(capability: .current(meshAvailable: true, guided: true, appAttest: true),
                                            colour: colour, closer: closer, binding: nil)
            let data = try JSONSerialization.data(withJSONObject: ["verification_package": pkg, "evidence": block.json],
                                                  options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: out))
        }
        return (pkg, colour, closer)
    }

    // MARK: - metadata.evidence and capability

    func testCapabilityIsHonest() {
        let full = EvidenceCapability.current(meshAvailable: true, guided: true, appAttest: true)
        XCTAssertEqual(full.json as NSDictionary, ["landmarks": true, "blendshapes": true, "pose_method": "matrix_zyx_v3",
                                                   "closer_step": true, "binding_v2": true] as NSDictionary)
        let noMesh = EvidenceCapability.current(meshAvailable: false, guided: true, appAttest: true)
        XCTAssertEqual(noMesh.json as NSDictionary, ["landmarks": false, "blendshapes": false, "pose_method": NSNull(),
                                                     "closer_step": false, "binding_v2": true] as NSDictionary)
        let legacyUI = EvidenceCapability.current(meshAvailable: true, guided: false, appAttest: false)
        XCTAssertFalse(legacyUI.closerStep, "the closer step only exists on the guided scan")
        XCTAssertFalse(legacyUI.bindingV2, "no App Attest (simulator), no v2")
    }

    func testUploadBlockShape() {
        var colour = ColourEvidence(sequenceId: "cs_1")
        colour.segments = [.init(colour: "#3D6BFF", startMs: 10, endMs: 611)]
        colour.interruptedReason = "gate_pause"
        let block = EvidenceUploadBlock(capability: .current(meshAvailable: true, guided: true, appAttest: true),
                                        colour: colour, closer: .skipped(.timeout),
                                        binding: BindingV2Evidence(digest: "d", keyId: "k", assertion: "a")).json
        XCTAssertEqual(block["contract"] as? String, "evidence-v1")
        XCTAssertEqual(block["clock"] as? String, "capture_monotonic_ms")
        let c = block["colour"] as? [String: Any]
        XCTAssertEqual(c?["completed"] as? Bool, false)
        XCTAssertEqual(c?["interrupted_reason"] as? String, "gate_pause")
        XCTAssertEqual((c?["segments"] as? [[String: Any]])?.first?["start_ms"] as? Int, 10)
        let closer = block["closer"] as? [String: Any]
        XCTAssertEqual(closer?["skipped_reason"] as? String, "timeout")
        XCTAssertEqual(closer?["far_frames"] as? [Int], [])
        let b = block["binding"] as? [String: Any]
        XCTAssertEqual(b?["version"] as? String, "binding_v2")
        XCTAssertEqual(b?["ios"] as? [String: String], ["key_id": "k", "assertion": "a"])
        XCTAssertNil(b?["error"])
        let failed = BindingV2Evidence(digest: "d", error: (name: "DCErrorDomain#2", message: "invalid key")).json
        XCTAssertEqual(failed["error"] as? [String: String], ["name": "DCErrorDomain#2", "message": "invalid key"])
        XCTAssertNil(failed["ios"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(block))
    }

    func testCloserRestrictedToMeshedFrames() {
        let c = CloserEvidence(farFrames: [4, 5, 6], nearFrames: [9, 10, 11], completed: true)
        XCTAssertEqual(c.restricted(to: Set(0...11)), c)
        let partial = c.restricted(to: [4, 6, 9, 10, 11])
        XCTAssertEqual(partial.farFrames, [4, 6])
        XCTAssertTrue(partial.completed)
        let lost = c.restricted(to: [4, 5, 6])
        XCTAssertFalse(lost.completed)
        XCTAssertEqual(lost.skippedReason, .timeout)
        XCTAssertEqual(lost.farFrames, [])
    }

    // MARK: - Colour player (section 6)

    private final class Host: ColourTintHost {
        var shown: [String?] = []
        var held = 0
        func showTint(_ colour: String?, opacity: Double) { shown.append(colour) }
        func holdFullBrightness() -> Double? { held += 1; return 1 }
        func releaseFullBrightness() { held -= 1 }
    }

    private func player(_ host: Host) -> ColourSequencePlayer {
        let seq = EvidenceConfig.ColourSequence(id: "cs_1", colours: ["#3D6BFF", "#FFD23F", "#B04DFF"])
        let p = ColourSequencePlayer(sequence: seq) { t in Int((t * 1000).rounded()) } // clock = host ms
        p.host = host
        p.lockWhiteBalance = { $0 }
        return p
    }

    func testPlayerRecordsWhatWasShown() {
        let host = Host()
        let p = player(host)
        p.play(now: 10)
        XCTAssertEqual(host.held, 1)
        p.advance(to: 10.2)  // lead-in still running
        XCTAssertTrue(p.record.segments.isEmpty)
        p.advance(to: 10.3166)
        p.advance(to: 10.9333)
        p.advance(to: 11.55)
        p.advance(to: 12.16)
        XCTAssertTrue(p.finished)
        XCTAssertEqual(p.record.segments, [.init(colour: "#3D6BFF", startMs: 10317, endMs: 10933),
                                           .init(colour: "#FFD23F", startMs: 10933, endMs: 11550),
                                           .init(colour: "#B04DFF", startMs: 11550, endMs: 12160)])
        XCTAssertTrue(p.record.completed)
        XCTAssertNil(p.record.interruptedReason)
        XCTAssertTrue(p.record.awbLocked)
        XCTAssertEqual(p.record.screenBrightness, 1)
        XCTAssertEqual(host.shown, ["#3D6BFF", "#FFD23F", "#B04DFF", nil])
        XCTAssertEqual(host.held, 0, "brightness handed back")
        p.play(now: 20)
        XCTAssertEqual(p.runs, 1, "a finished sequence never plays again")
    }

    func testPlayerPauseRecordsTheRunAndReplays() {
        let host = Host()
        let p = player(host)
        p.play(now: 0)
        p.advance(to: 0.31)
        p.advance(to: 0.5)
        p.interrupt(now: 0.5)
        XCTAssertEqual(p.record.segments, [.init(colour: "#3D6BFF", startMs: 310, endMs: 500)])
        XCTAssertFalse(p.record.completed)
        XCTAssertEqual(p.record.interruptedReason, "gate_pause")
        XCTAssertEqual(host.shown.last, .some(nil))
        XCTAssertEqual(host.held, 0)
        p.play(now: 2)
        XCTAssertEqual(p.runs, 2)
        for t in [2.31, 2.92, 3.53, 4.14] { p.advance(to: t) }
        XCTAssertTrue(p.finished)
        XCTAssertTrue(p.record.completed)
        XCTAssertNil(p.record.interruptedReason)
        XCTAssertEqual(p.record.segments.map(\.colour), ["#3D6BFF", "#3D6BFF", "#FFD23F", "#B04DFF"])
    }

    func testPlayerWithoutWhiteBalanceLockSaysSo() {
        let host = Host()
        let p = player(host)
        p.lockWhiteBalance = { _ in false }
        p.play(now: 0)
        XCTAssertFalse(p.record.awbLocked)
    }

    func testPlayerWaitsForTheCaptureClock() {
        let host = Host()
        let seq = EvidenceConfig.ColourSequence(id: "cs_1", colours: ["#3D6BFF"])
        let p = ColourSequencePlayer(sequence: seq) { _ in nil }
        p.host = host
        p.play(now: 0)
        p.advance(to: 1)
        XCTAssertTrue(p.record.segments.isEmpty, "no camera frame yet: nothing to time the colour against")
        XCTAssertTrue(p.isPlaying)
        p.cancel()
    }

    // MARK: - Closer step display

    func testCloserGuidanceUsesExistingCopy() {
        let g = GuidedCaptureView<EmptyView>.guidance(hint: nil, mode: .scan, paused: false, showShutter: false,
                                                       needsCloser: true)
        XCTAssertEqual(g.title, "Move a little closer")
        XCTAssertTrue(g.action)
        let held = GuidedCaptureView<EmptyView>.guidance(hint: nil, mode: .scan, paused: false, showShutter: false)
        XCTAssertEqual(held.title, "Hold still")
        // A failing check during the closer step still names that check.
        let paused = GuidedCaptureView<EmptyView>.guidance(hint: .lookStraight, mode: .scan, paused: true,
                                                            showShutter: false, needsCloser: true)
        XCTAssertEqual(paused.title, "Look straight ahead")
    }

    func testOvalScalesAboutItsCentre() {
        let size = CGSize(width: 390, height: 844)
        let a = CaptureOvalLayout.ovalRect(in: size)
        let b = CaptureOvalLayout.ovalRect(in: size, scale: 1.4)
        XCTAssertEqual(b.midX, a.midX, accuracy: 1e-9)
        XCTAssertEqual(b.midY, a.midY, accuracy: 1e-9)
        XCTAssertEqual(b.width, a.width * 1.4, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(b.minY, 0, "the grown oval stays on screen")
    }
}
#endif
