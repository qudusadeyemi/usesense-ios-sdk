import Foundation

// Legacy compatibility types - kept for any external references.
// The DeviceSignalCollector now returns [String: Any] dictionaries directly.

public struct BatteryInfo: Codable, Sendable {
    let level: Float
    let state: String
}

public struct ConnectionInfo: Codable, Sendable {
    let type: String
}
