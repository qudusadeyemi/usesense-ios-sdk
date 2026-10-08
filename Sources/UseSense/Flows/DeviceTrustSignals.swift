import Foundation

/// Camera-free Device Trust.
///
/// The Flows runner declares `device_signals_v1` on every load and advance, so
/// a Device Trust step arrives as a `device` capture: the runner collects the
/// same channel integrity it sends with a face capture, minus anything that
/// needs the camera or microphone, and posts it with the step's nonce. Without
/// the capability the server settles the step from the network alone, which is
/// what older SDKs get. Server contract: docs/sdk/device-trust-protocol.md in
/// usesense-watchtower.
enum DeviceSignalsCapability {
    static let deviceSignalsV1 = "device_signals_v1"

    /// Capabilities the Flows runner declares to the SDK Runner endpoints.
    static let all: [String] = [deviceSignalsV1]

    /// Server codes after which the run should be re-read instead of failing:
    /// the nonce moved on, or the step was already settled (a retry).
    static func needsReload(serverCode: String?) -> Bool {
        serverCode == "nonce_mismatch" || serverCode == "device_step_not_pending"
    }

    /// What the runner does with a device step that arrived without a nonce.
    enum MissingNonce: Equatable { case reload, fail }

    /// The server mints the nonce when the client declares the capability, so a
    /// device step without one is re-read once to pick it up. If it is still
    /// missing the run fails with a clear error rather than spinning forever.
    /// Same rule as the Android SDK.
    static func onMissingNonce(alreadyReloaded: Bool) -> MissingNonce {
        alreadyReloaded ? .fail : .reload
    }

    /// Error message when a device step still has no nonce after one re-read.
    static let missingNonceMessage = "Device Trust step is missing its nonce"
}

#if canImport(UIKit)
enum DeviceTrustSignals {
    /// App Attest is an Apple network call on first use; never let it hold up
    /// the step. The server treats a missing assertion as "unavailable", not a
    /// failure.
    static let attestTimeoutSeconds: Double = 5

    /// Motion samples arrive at ~2 Hz; a short window gives the scorer a few.
    static let sensorWindowSeconds: Double = 1.5

    /// Keys that describe the camera or microphone. Nothing was captured, and
    /// the server leaves the capture dimension out of the device-only score.
    static let captureOnlyKeys: Set<String> = [
        "camera_facing", "camera_resolution",
        "camera_permission_granted", "microphone_permission_granted",
    ]

    /// Collect channel integrity for a Device Trust step. App Attest signs over
    /// `nonce` (clientDataHash = SHA256(nonce)), exactly as a face session
    /// signs over its session nonce.
    static func collect(nonce: String) async -> [String: Any] {
        let collector = DeviceSignalCollector()
        collector.startSensorCollection()
        defer { collector.release() }

        async let attest = attestFields(nonce: nonce)
        try? await Task.sleep(nanoseconds: UInt64(sensorWindowSeconds * 1_000_000_000))
        let fields = await attest

        var ci = collector.collectChannelIntegrity(attestFields: fields)
        for key in captureOnlyKeys { ci.removeValue(forKey: key) }
        return ci
    }

    private static func attestFields(nonce: String) async -> [String: Any] {
        #if canImport(DeviceCheck) && canImport(CryptoKit)
        let manager = AppAttestManager()
        return await withTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { await manager.getAttestFields(sessionNonce: nonce) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(attestTimeoutSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ["app_attest_supported": true, "app_attest_timed_out": true]
        }
        #else
        return [:]
        #endif
    }
}
#endif
