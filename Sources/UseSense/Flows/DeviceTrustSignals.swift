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

/// The device binding a face init-session carries: the stable signals the
/// server hashes into the DeepSense device fingerprint, plus the App Attest key
/// id. The server reuses a Device Trust check from earlier in the run for the
/// face step only when these match it. Server contract:
/// docs/sdk/device-trust-protocol.md §5 in usesense-watchtower.
enum DeviceBinding {
    /// Must match DEVICE_FINGERPRINT_KEYS on the server, in this order.
    static let fingerprintKeys: [String] = [
        "canvas_hash", "webgl_renderer", "webgl_vendor", "webgl_extensions",
        "screen_resolution", "hardware_concurrency", "device_memory", "max_touch_points",
        "platform", "color_depth", "timezone", "audio_fingerprint",
    ]

    /// Collection never holds up the face step longer than this.
    static let timeoutSeconds: Double = 1.5

    /// The `device_binding` body for init-session, or nil when there is nothing
    /// to send (the server then matches on platform and device model).
    static func body(channelIntegrity: [String: Any], appAttestKeyId: String?) -> [String: Any]? {
        var components: [String: Any] = [:]
        for key in fingerprintKeys {
            if let value = channelIntegrity[key], !(value is NSNull) { components[key] = value }
        }
        var body: [String: Any] = [:]
        if !components.isEmpty { body["components"] = components }
        if let keyId = appAttestKeyId, !keyId.isEmpty { body["app_attest_key_id"] = keyId }
        return body.isEmpty ? nil : body
    }
}

#if canImport(UIKit)
extension DeviceBinding {
    /// Collect the binding from the same signal collector the Device Trust
    /// step used, with no App Attest network call: only an existing key id is
    /// read. Capped at `timeoutSeconds`; a slow collection sends none.
    static func collect() async -> [String: Any]? {
        await withTaskGroup(of: [String: Any]??.self) { group in
            group.addTask {
                let ci = await MainActor.run { () -> [String: Any] in
                    let collector = DeviceSignalCollector()
                    defer { collector.release() }
                    return collector.collectChannelIntegrity()
                }
                var keyId: String?
                #if canImport(DeviceCheck) && canImport(CryptoKit)
                keyId = await AppAttestManager().existingKeyId()
                #endif
                return .some(body(channelIntegrity: ci, appAttestKeyId: keyId))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return .some(nil)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }
}

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
