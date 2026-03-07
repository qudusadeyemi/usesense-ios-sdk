import Foundation

public struct IOSIntegritySignals: Codable, Sendable {
    let isSimulator: Bool
    let isJailbroken: Bool
    let isDebuggerAttached: Bool
    let appAttestToken: String?
    let bundleId: String
    let deviceModel: String
    let osVersion: String
    let screenResolution: String
    let processorCount: Int
    let physicalMemoryMB: Int
    let battery: BatteryInfo?
    let connection: ConnectionInfo?
    let timezone: String
    let locale: String

    enum CodingKeys: String, CodingKey {
        case isSimulator = "is_simulator"
        case isJailbroken = "is_jailbroken"
        case isDebuggerAttached = "is_debugger_attached"
        case appAttestToken = "app_attest_token"
        case bundleId = "bundle_id"
        case deviceModel = "device_model"
        case osVersion = "os_version"
        case screenResolution = "screen_resolution"
        case processorCount = "processor_count"
        case physicalMemoryMB = "physical_memory_mb"
        case battery, connection, timezone, locale
    }
}

public struct BatteryInfo: Codable, Sendable {
    let level: Float
    let state: String
}

public struct ConnectionInfo: Codable, Sendable {
    let type: String
}
