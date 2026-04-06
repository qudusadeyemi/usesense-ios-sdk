import Foundation

final class MetadataBuilder: @unchecked Sendable {

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Build the v4.1 metadata payload with all required and conditional fields.
    func build(
        sessionId: String? = nil,
        source: String = "sdk",
        captureConfig: [String: Any]? = nil,
        captureStartTime: Date,
        captureEndTime: Date,
        sessionStartTime: Date? = nil,

        // Frames
        framesManifest: [[String: Any]]? = nil,
        frameHashes: [String]? = nil,
        framesCaptured: Int,
        framesDropped: Int,
        avgFrameIntervalMs: Int,

        // Challenge
        challengeResponse: [String: Any]?,

        // Channel integrity & telemetry
        channelIntegrity: [String: Any],
        deviceTelemetry: [String: Any],
        screenDetection: [String: Any]? = nil,

        // Face mesh signals (Chapter 6)
        faceMeshSignals: [String: Any]? = nil,

        // Geometric Coherence verification package (Chapter 6)
        verificationPackage: [String: Any]? = nil,

        // Suspicion Engine (Chapter 7) - ALWAYS included
        suspicion: [String: Any]? = nil,

        // Inline Step-Up (Chapter 7) - only when triggered
        inlineStepUp: [String: Any]? = nil
    ) throws -> Data {
        var metadata: [String: Any] = [:]

        // Top-level fields per spec
        if let sid = sessionId {
            metadata["session_id"] = sid
        }
        metadata["sdk_version"] = UseSenseAPIClient.sdkVersion
        metadata["platform"] = "ios"
        metadata["source"] = source

        // Capture config
        if let config = captureConfig {
            metadata["capture_config"] = config
        }

        // Timestamps
        metadata["timestamps"] = [
            "session_started_at_ms": Int((sessionStartTime ?? captureStartTime).timeIntervalSince1970 * 1000),
            "capture_started_at_ms": Int(captureStartTime.timeIntervalSince1970 * 1000),
            "capture_ended_at_ms": Int(captureEndTime.timeIntervalSince1970 * 1000)
        ]

        // Frames manifest
        if let manifest = framesManifest {
            metadata["frames_manifest"] = manifest
        }

        // Frame hashes (SHA-256 per JPEG - REQUIRED per spec)
        if let hashes = frameHashes {
            metadata["frame_hashes"] = hashes
        }

        // Challenge response (conditional: only when challenge_type != "none")
        if let cr = challengeResponse {
            metadata["challenge_response"] = cr
        }

        // Face mesh signals (conditional: when MediaPipe available)
        if let fms = faceMeshSignals {
            metadata["face_mesh_signals"] = fms
        }

        // Verification package (conditional: when dual_path_enabled)
        if let vp = verificationPackage {
            metadata["verification_package"] = vp
        }

        // Suspicion engine data (ALWAYS included per spec, even if step-up not triggered)
        if let sus = suspicion {
            metadata["suspicion"] = sus
        }

        // Inline step-up (only when triggered, otherwise null)
        if let isu = inlineStepUp {
            metadata["inline_step_up"] = isu
        }

        // Build channel_integrity with embedded capture timing and screen detection
        var ci = channelIntegrity
        ci["capture_start_time"] = isoFormatter.string(from: captureStartTime)
        ci["capture_end_time"] = isoFormatter.string(from: captureEndTime)
        ci["capture_duration_ms"] = Int(captureEndTime.timeIntervalSince(captureStartTime) * 1000)
        ci["frames_captured"] = framesCaptured
        ci["frames_dropped"] = framesDropped
        ci["avg_frame_interval_ms"] = avgFrameIntervalMs

        // Embed screen detection signals
        if let sd = screenDetection {
            ci["screen_detection"] = sd
        }

        metadata["channel_integrity"] = ci
        metadata["device_telemetry"] = deviceTelemetry

        return try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    }
}
