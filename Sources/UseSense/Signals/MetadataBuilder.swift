import Foundation

final class MetadataBuilder: @unchecked Sendable {

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Build the metadata payload matching the spec Section 7.1 schema.
    func build(
        sessionId: String? = nil,
        source: String = "sdk",
        challengeResponse: [String: Any]?,
        channelIntegrity: [String: Any],
        deviceTelemetry: [String: Any],
        captureStartTime: Date,
        captureEndTime: Date,
        framesCaptured: Int,
        framesDropped: Int,
        avgFrameIntervalMs: Int,
        captureConfig: [String: Any]? = nil,
        framesManifest: [[String: Any]]? = nil
    ) throws -> Data {
        var metadata: [String: Any] = [:]

        // Top-level fields per spec
        if let sid = sessionId {
            metadata["session_id"] = sid
        }
        metadata["sdk_version"] = UseSenseAPIClient.sdkVersion
        metadata["platform"] = "ios"
        metadata["source"] = source

        // Capture config (if provided)
        if let config = captureConfig {
            metadata["capture_config"] = config
        }

        // Timestamps
        metadata["timestamps"] = [
            "session_started_at_ms": Int(captureStartTime.timeIntervalSince1970 * 1000),
            "capture_started_at_ms": Int(captureStartTime.timeIntervalSince1970 * 1000),
            "capture_ended_at_ms": Int(captureEndTime.timeIntervalSince1970 * 1000)
        ]

        // Frames manifest (if provided)
        if let manifest = framesManifest {
            metadata["frames_manifest"] = manifest
        }

        // Challenge response (optional)
        if let cr = challengeResponse {
            metadata["challenge_response"] = cr
        }

        // Embed capture timing into channel_integrity
        var ci = channelIntegrity
        ci["capture_start_time"] = isoFormatter.string(from: captureStartTime)
        ci["capture_end_time"] = isoFormatter.string(from: captureEndTime)
        ci["capture_duration_ms"] = Int(captureEndTime.timeIntervalSince(captureStartTime) * 1000)
        ci["frames_captured"] = framesCaptured
        ci["frames_dropped"] = framesDropped
        ci["avg_frame_interval_ms"] = avgFrameIntervalMs

        metadata["channel_integrity"] = ci
        metadata["device_telemetry"] = deviceTelemetry

        return try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    }
}
