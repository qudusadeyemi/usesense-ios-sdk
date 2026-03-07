import Foundation

struct MetadataBuilder {
    static func build(
        challengeResponse: ChallengeResponsePayload?,
        webIntegrity: [String: Any],
        deviceTelemetry: [String: Any],
        captureStartTime: Date,
        captureEndTime: Date,
        framesCount: Int,
        frameTimestamps: [Int]
    ) -> Data? {
        var metadata: [String: Any] = [:]

        if let challengeResponse = challengeResponse {
            metadata["challenge_response"] = challengeResponse.toDictionary()
        }

        var integrity = webIntegrity
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        integrity["capture_start_time"] = formatter.string(from: captureStartTime)
        integrity["capture_end_time"] = formatter.string(from: captureEndTime)
        integrity["capture_duration_ms"] = Int(captureEndTime.timeIntervalSince(captureStartTime) * 1000)
        integrity["frames_captured"] = framesCount

        metadata["web_integrity"] = integrity
        metadata["device_telemetry"] = deviceTelemetry

        return try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    }
}

struct ChallengeResponsePayload {
    let type: String
    let seed: String
    let completed: Bool
    let waypointFrames: [String: [Int]]?
    let stepFrames: [String: [Int]]?
    let startedAt: Date?
    let completedAt: Date?
    let frameTimestamps: [Int]

    func toDictionary() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var dict: [String: Any] = [
            "type": type,
            "seed": seed,
            "completed": completed,
            "frame_timestamps": frameTimestamps
        ]

        if let waypointFrames = waypointFrames {
            dict["waypoint_frames"] = waypointFrames
        }

        if let stepFrames = stepFrames {
            dict["step_frames"] = stepFrames
        }

        if let startedAt = startedAt {
            dict["started_at"] = formatter.string(from: startedAt)
        }

        if let completedAt = completedAt {
            dict["completed_at"] = formatter.string(from: completedAt)
        }

        return dict
    }
}
