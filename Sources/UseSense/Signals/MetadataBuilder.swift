import Foundation

final class MetadataBuilder: @unchecked Sendable {

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Build the metadata payload matching Android's structure:
    /// `{ challenge_response, channel_integrity, device_telemetry }`
    func build(
        challengeResponse: [String: Any]?,
        channelIntegrity: [String: Any],
        deviceTelemetry: [String: Any],
        captureStartTime: Date,
        captureEndTime: Date,
        framesCaptured: Int,
        framesDropped: Int,
        avgFrameIntervalMs: Int
    ) throws -> Data {
        var metadata: [String: Any] = [:]

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
