import Foundation

struct CaptureMetadata: Codable {
    let sessionId: String
    let nonce: String
    let challengeSeed: String?
    let challengeType: String?
    let capturedAt: String
    let captureDurationMs: Int
    let frameCount: Int
    let frameTimestamps: [Double]
    let hasAudio: Bool
    let deviceInfo: DeviceInfo
    let iosIntegrity: IOSIntegritySignals?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case nonce
        case challengeSeed = "challenge_seed"
        case challengeType = "challenge_type"
        case capturedAt = "captured_at"
        case captureDurationMs = "capture_duration_ms"
        case frameCount = "frame_count"
        case frameTimestamps = "frame_timestamps"
        case hasAudio = "has_audio"
        case deviceInfo = "device_info"
        case iosIntegrity = "ios_integrity"
    }
}

struct DeviceInfo: Codable {
    let platform: String
    let osVersion: String
    let deviceModel: String
    let sdkVersion: String
    let screenWidth: Int
    let screenHeight: Int
    let cameraResolution: String

    enum CodingKeys: String, CodingKey {
        case platform
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case sdkVersion = "sdk_version"
        case screenWidth = "screen_width"
        case screenHeight = "screen_height"
        case cameraResolution = "camera_resolution"
    }
}

final class MetadataBuilder: @unchecked Sendable {
    private let encoder = JSONEncoder()

    func build(
        sessionId: String,
        nonce: String,
        challenge: ChallengeSpecWrapper?,
        captureDurationMs: Int,
        frameTimestamps: [TimeInterval],
        hasAudio: Bool,
        integritySignals: IOSIntegritySignals?
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let deviceInfo = DeviceInfo(
            platform: "ios",
            osVersion: integritySignals?.osVersion ?? "unknown",
            deviceModel: integritySignals?.deviceModel ?? "unknown",
            sdkVersion: "1.0.0",
            screenWidth: Int(screenWidth()),
            screenHeight: Int(screenHeight()),
            cameraResolution: "1280x720"
        )

        let metadata = CaptureMetadata(
            sessionId: sessionId,
            nonce: nonce,
            challengeSeed: challenge?.seed,
            challengeType: challenge?.challengeType.rawValue,
            capturedAt: formatter.string(from: Date()),
            captureDurationMs: captureDurationMs,
            frameCount: frameTimestamps.count,
            frameTimestamps: frameTimestamps,
            hasAudio: hasAudio,
            deviceInfo: deviceInfo,
            iosIntegrity: integritySignals
        )

        return try encoder.encode(metadata)
    }

    private func screenWidth() -> CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.nativeBounds.width
        #else
        return 0
        #endif
    }

    private func screenHeight() -> CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.nativeBounds.height
        #else
        return 0
        #endif
    }
}
