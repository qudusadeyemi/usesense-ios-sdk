#if canImport(AVFoundation) && canImport(UIKit)
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Upload side of EVIDENCE-v1: the per-frame fields (sections 4 and 5), the
/// per-session `metadata.evidence` object (sections 6 to 8) and the binding
/// v2 digest. Pure functions and value types, so the wire format is unit
/// tested without a camera.
enum Evidence {
    static let poseMethodV3 = "matrix_zyx_v3"
    static let poseMethodLegacy = "mediapipe_zyx_v2"

    /// Round half away from zero to `places` decimals. The server hashes the
    /// numbers it reads, so the SDK rounds before hashing and before sending.
    static func round(_ v: Double, _ places: Int) -> Double {
        guard v.isFinite else { return 0 }
        let f = pow(10.0, Double(places))
        let r = (v * f).rounded(.toNearestOrAwayFromZero) / f
        return r == 0 ? 0 : r // no -0
    }

    /// Flat `[x0, y0, z0, x1, ...]`, 5 decimals. MediaPipe runs on the same
    /// portrait, unmirrored pixel buffer the JPEG is encoded from (uniform
    /// downscale only), so normalised buffer coordinates are JPEG coordinates.
    static func flatLandmarks(_ lm: [(x: Double, y: Double, z: Double)]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(lm.count * 3)
        for p in lm {
            out.append(round(p.x, 5))
            out.append(round(p.y, 5))
            out.append(round(p.z, 5))
        }
        return out
    }

    /// Lowercase hex SHA-256 of the values as little-endian Float64, as the
    /// server's `new Float64Array(frame.landmarks)` hashes them.
    static func landmarksHash(_ flat: [Double]) -> String? {
        #if canImport(CryptoKit)
        guard !flat.isEmpty else { return nil }
        var bytes = Data(capacity: flat.count * 8)
        for v in flat {
            var le = v.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        return hex(SHA256.hash(data: bytes))
        #else
        return nil
        #endif
    }

    /// EVIDENCE-v1 section 5, exactly the server's `poseFromMatrix`, degrees.
    /// `m` is the row-major 4x4 facial transformation matrix.
    static func matrixPose(_ m: [Double]) -> HeadPose? {
        guard m.count == 16, m.allSatisfy(\.isFinite) else { return nil }
        let r = { (row: Int, col: Int) in m[row * 4 + col] }
        let toDeg = 180.0 / Double.pi
        return HeadPose(
            yaw: atan2(-r(2, 0), (r(0, 0) * r(0, 0) + r(1, 0) * r(1, 0)).squareRoot()) * toDeg,
            pitch: atan2(r(2, 1), r(2, 2)) * toDeg,
            roll: atan2(r(1, 0), r(0, 0)) * toDeg
        )
    }

    #if canImport(CryptoKit)
    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 {
        d.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }
    #endif
}

// MARK: - Per-frame evidence

/// What one uploaded frame adds under EVIDENCE-v1.
struct EvidenceFrameFields: Equatable {
    /// 5 decimals, JPEG space, unmirrored.
    var landmarks: [Double]
    /// Row-major 4x4, 5 decimals; nil when the landmarker returned none.
    var transformMatrix: [Double]?
    /// Pose from the rounded matrix, so the server's recomputation matches.
    var matrixPose: HeadPose?
    var eyeBlinkLeft: Double?
    var eyeBlinkRight: Double?

    init(mesh: FaceMeshResult) {
        landmarks = Evidence.flatLandmarks(mesh.landmarks)
        transformMatrix = mesh.gate.transformMatrix.flatMap { $0.count == 16 ? $0.map { Evidence.round($0, 5) } : nil }
        matrixPose = transformMatrix.flatMap(Evidence.matrixPose)
        eyeBlinkLeft = mesh.gate.eyeBlinkLeft.map { Evidence.round($0, 3) }
        eyeBlinkRight = mesh.gate.eyeBlinkRight.map { Evidence.round($0, 3) }
    }

    var blendshapesJSON: [String: Any]? {
        guard let l = eyeBlinkLeft, let r = eyeBlinkRight else { return nil }
        return ["eyeBlinkLeft": l, "eyeBlinkRight": r]
    }
}

extension HeadPose: Equatable {
    static func == (a: HeadPose, b: HeadPose) -> Bool { a.yaw == b.yaw && a.pitch == b.pitch && a.roll == b.roll }
}

// MARK: - Colour sequence (section 6)

struct ColourEvidence: Equatable {
    struct Segment: Equatable {
        var colour: String
        var startMs: Int
        var endMs: Int
    }

    var sequenceId: String
    var segments: [Segment] = []
    var screenBrightness: Double?
    var completed = false
    var interruptedReason: String?
    var awbLocked = false

    var json: [String: Any] {
        [
            "sequence_id": sequenceId,
            "segments": segments.map { ["colour": $0.colour, "start_ms": $0.startMs, "end_ms": $0.endMs] },
            "screen_brightness": screenBrightness.map { Evidence.round($0, 3) as Any } ?? NSNull(),
            "completed": completed,
            "interrupted_reason": interruptedReason.map { $0 as Any } ?? NSNull(),
            "awb_locked": awbLocked
        ]
    }
}

// MARK: - Closer step (section 7)

struct CloserEvidence: Equatable {
    enum SkipReason: String { case timeout, disabled }

    var farFrames: [Int] = []
    var nearFrames: [Int] = []
    var startedAtMs: Int?
    var endedAtMs: Int?
    var achievedScale: Double?
    var completed = false
    var skippedReason: SkipReason?

    static func skipped(_ reason: SkipReason) -> CloserEvidence {
        CloserEvidence(completed: false, skippedReason: reason)
    }

    var json: [String: Any] {
        [
            "far_frames": farFrames,
            "near_frames": nearFrames,
            "started_at_ms": startedAtMs.map { $0 as Any } ?? NSNull(),
            "ended_at_ms": endedAtMs.map { $0 as Any } ?? NSNull(),
            "achieved_scale": achievedScale.map { Evidence.round($0, 3) as Any } ?? NSNull(),
            "completed": completed,
            "skipped_reason": skippedReason.map { $0.rawValue as Any } ?? NSNull()
        ]
    }

    /// Keep only frames that were uploaded and carry a mesh entry, so every
    /// index the server reads points at real landmarks.
    func restricted(to indices: Set<Int>) -> CloserEvidence {
        var c = self
        c.farFrames = farFrames.filter(indices.contains)
        c.nearFrames = nearFrames.filter(indices.contains)
        if c.completed && (c.farFrames.isEmpty || c.nearFrames.isEmpty) {
            c.completed = false
            c.skippedReason = .timeout
            c.farFrames = []
            c.nearFrames = []
        }
        return c
    }
}

// MARK: - Capability

/// What this build can do, whether or not it happened in this session. The
/// server reads a missing signal from a capable SDK as a failed step.
struct EvidenceCapability: Equatable {
    var landmarks: Bool
    var blendshapes: Bool
    var poseMethod: String?
    var closerStep: Bool
    var bindingV2: Bool

    /// `meshAvailable`: MediaPipe is linked and its model loaded.
    /// `guided`: the guided scan (the only UI that runs the closer step).
    /// `appAttest`: App Attest is supported on this device.
    static func current(meshAvailable: Bool, guided: Bool, appAttest: Bool) -> EvidenceCapability {
        EvidenceCapability(
            landmarks: meshAvailable,
            blendshapes: meshAvailable,
            poseMethod: meshAvailable ? Evidence.poseMethodV3 : nil,
            closerStep: meshAvailable && guided,
            bindingV2: appAttest
        )
    }

    var json: [String: Any] {
        [
            "landmarks": landmarks,
            "blendshapes": blendshapes,
            "pose_method": poseMethod.map { $0 as Any } ?? NSNull(),
            "closer_step": closerStep,
            "binding_v2": bindingV2
        ]
    }
}

// MARK: - Binding v2 digest (section 8)

enum EvidenceDigest {
    struct Frame: Equatable {
        var frameIndex: Int
        var frameHash: String
        var meshDigest: String
    }

    /// The digest text, lines joined with "\n", no trailing newline.
    static func text(sessionId: String, challenge: String, frames: [Frame],
                     colour: ColourEvidence?, closer: CloserEvidence?) -> String {
        var lines = ["usesense-evidence-v1", "session:\(sessionId)", "challenge:\(challenge)"]
        for f in frames { lines.append("frame:\(f.frameIndex):\(f.frameHash):\(f.meshDigest)") }
        if let colour, !colour.segments.isEmpty, !colour.sequenceId.isEmpty {
            lines.append("colour:\(colour.sequenceId):"
                + colour.segments.map { "\($0.colour)@\($0.startMs)-\($0.endMs)" }.joined(separator: ","))
        } else {
            lines.append("colour:none")
        }
        let far = closer?.farFrames ?? [], near = closer?.nearFrames ?? []
        if far.isEmpty && near.isEmpty {
            lines.append("closer:none")
        } else {
            lines.append("closer:" + far.map(String.init).joined(separator: ",") + "|"
                + near.map(String.init).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    #if canImport(CryptoKit)
    static func digest(sessionId: String, challenge: String, frames: [Frame],
                       colour: ColourEvidence?, closer: CloserEvidence?) -> String {
        Evidence.sha256Hex(text(sessionId: sessionId, challenge: challenge, frames: frames, colour: colour, closer: closer))
    }
    #endif

    /// The verification package's frames, in array order, as the digest reads them.
    static func frames(fromPackage package: [String: Any]?) -> [Frame] {
        guard let list = package?["frames"] as? [[String: Any]] else { return [] }
        return list.compactMap { f in
            guard let i = f["frameIndex"] as? Int, let h = f["frameHash"] as? String,
                  let d = f["meshDigest"] as? String else { return nil }
            return Frame(frameIndex: i, frameHash: h, meshDigest: d)
        }
    }
}

/// The binding block: a signed digest, or the reason signing failed.
struct BindingV2Evidence {
    var digest: String
    var keyId: String?
    var assertion: String?
    var error: (name: String, message: String)?

    var json: [String: Any] {
        var b: [String: Any] = ["version": "binding_v2", "digest": digest]
        if let keyId, let assertion {
            b["ios"] = ["key_id": keyId, "assertion": assertion]
        } else {
            let e = error ?? (name: "BindingUnavailable", message: "no App Attest key")
            b["error"] = ["name": e.name, "message": String(e.message.prefix(256))]
        }
        return b
    }
}

/// `metadata.evidence`.
struct EvidenceUploadBlock {
    var capability: EvidenceCapability
    var colour: ColourEvidence?
    var closer: CloserEvidence?
    var binding: BindingV2Evidence?

    var json: [String: Any] {
        var e: [String: Any] = [
            "contract": EvidenceConfig.contractV1,
            "clock": "capture_monotonic_ms",
            "capability": capability.json
        ]
        if let colour { e["colour"] = colour.json }
        if let closer { e["closer"] = closer.json }
        if let binding { e["binding"] = binding.json }
        return e
    }
}
#endif
