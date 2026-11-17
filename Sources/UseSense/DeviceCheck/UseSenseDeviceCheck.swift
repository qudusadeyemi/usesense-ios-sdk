import Foundation
#if os(iOS) && canImport(AVFoundation)
import AVFoundation
#endif

/// Silent device check (Your KYC): Sense device signals next to whatever KYC
/// provider SDK the app already uses, with no UI, no camera and no permission
/// prompt.
///
///   1. Your server calls `POST /v1/device-checks` and hands the app the
///      `deviceCheckId`, `token` (dct_) and `nonce` (dn_).
///   2. The app calls `start()` before the provider's SDK opens: the same
///      camera-free channel integrity a Device Trust step sends (App Attest
///      over the nonce, jailbreak and debugger checks, hardware, session
///      context), posted with `phase: "start"`.
///   3. Optionally, `finish()` after the provider closes: the camera
///      inventory (device listing only, no capture), posted with
///      `phase: "finish"`.
///
/// The server answers 202 and never returns a score: the result reaches your
/// server through Your KYC. Server contract: modules/device-checks in
/// usesense-watchtower (`POST /v1/sdk/device-checks/:id/signals`).
public struct DeviceCheckConfig: Sendable {
    /// The SDK API host. The request path is set by the SDK, so a base URL
    /// that already ends in `/v1` works too.
    public static let defaultBaseURL = URL(string: "https://api.usesense.ai")!
    /// Per-request hard cap, retry included per attempt.
    public static let defaultRequestTimeout: TimeInterval = 20

    /// The `dc_` id from `POST /v1/device-checks`.
    public let deviceCheckId: String
    /// The one-use `dct_` token from `POST /v1/device-checks`. Sent only in
    /// the Authorization header, never in a URL or a log line.
    public let token: String
    /// The `dn_` nonce from `POST /v1/device-checks`. App Attest signs over it.
    public let nonce: String
    public let baseURL: URL
    public let requestTimeout: TimeInterval

    public init(
        deviceCheckId: String,
        token: String,
        nonce: String,
        baseURL: URL = DeviceCheckConfig.defaultBaseURL,
        requestTimeout: TimeInterval = DeviceCheckConfig.defaultRequestTimeout
    ) {
        self.deviceCheckId = deviceCheckId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nonce = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout > 0 ? requestTimeout : DeviceCheckConfig.defaultRequestTimeout
    }
}

/// The two calls of a silent device check, in order.
public enum DeviceCheckPhase: String, Sendable, Equatable {
    case start
    case finish
}

/// Why a silent device check call did not reach the server or was refused.
public struct DeviceCheckError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        /// 401 invalid_token: missing or wrong dct_ token.
        case tokenInvalid = "token_invalid"
        /// 401 token_expired: more than 15 minutes after create. Create a new check.
        case tokenExpired = "token_expired"
        /// 400 nonce_mismatch: the nonce is not this check's.
        case nonceMismatch = "nonce_mismatch"
        /// 400 invalid_phase / invalid_input, or 413 too_large.
        case invalidInput = "invalid_input"
        /// 409 already_started / not_started / already_finished: start once,
        /// then finish once, in that order. Also returned locally, with no
        /// request, when the same phase was already sent from this object.
        case outOfOrder = "out_of_order"
        /// 404 not_found: unknown device check id.
        case notFound = "not_found"
        /// 503 (after one retry) or another 5xx: the server could not score now.
        case unavailable
        case networkUnavailable = "network_unavailable"
        /// The request did not finish within `requestTimeout`.
        case timeout
        /// The config cannot be sent (empty token or nonce, malformed id).
        case invalidConfig = "invalid_config"
        case unknown
    }

    public let code: Code
    public let message: String
    /// The server's `code` passed through verbatim when present.
    public let serverCode: String?
    /// The HTTP status when the server answered.
    public let httpStatus: Int?

    public init(code: Code, message: String, serverCode: String? = nil, httpStatus: Int? = nil) {
        self.code = code
        self.message = message
        self.serverCode = serverCode
        self.httpStatus = httpStatus
    }

    public var description: String { "DeviceCheckError(\(code.rawValue)): \(message)" }

    /// Whether calling the same phase again can help. A dead token, a wrong
    /// nonce or an out-of-order call cannot be fixed by resending.
    public var isRetryable: Bool {
        switch code {
        case .unavailable, .networkUnavailable, .timeout, .unknown: return true
        default: return false
        }
    }
}

/// What a silent device check call produced. The server never returns a
/// score to the device: `received` only means the signals arrived.
public enum DeviceCheckResult: Equatable, Sendable {
    case received(DeviceCheckPhase)
    case failed(DeviceCheckError)

    public var isReceived: Bool {
        if case .received = self { return true }
        return false
    }

    public var error: DeviceCheckError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

/// A headless silent device check. Create it with
/// `UseSense.deviceCheck(config:)`. Never shows UI, never opens the camera
/// and never asks for a permission. Every failure is returned as
/// `.failed(DeviceCheckError)`; nothing throws.
public final class UseSenseDeviceCheck: @unchecked Sendable {
    public typealias Fetcher = FlowsClient.Fetcher
    typealias Collector = @Sendable () async -> [String: Any]

    /// Wait before the single retry of a 503.
    static let retryDelaySeconds: TimeInterval = 1

    public let config: DeviceCheckConfig
    private let fetcher: Fetcher
    private let collectStart: Collector
    private let collectFinish: Collector
    private let retryDelay: TimeInterval

    private enum PhaseState { case idle, inFlight, received }
    private let lock = NSLock()
    private var startState: PhaseState = .idle
    private var finishState: PhaseState = .idle

    public convenience init(config: DeviceCheckConfig) {
        let session = FlowsClient.defaultSession
        self.init(config: config, fetcher: { request in try await session.data(for: request) })
    }

    /// Injectable transport and collectors, used by tests.
    init(
        config: DeviceCheckConfig,
        fetcher: @escaping Fetcher,
        collectStart: Collector? = nil,
        collectFinish: Collector? = nil,
        retryDelay: TimeInterval = UseSenseDeviceCheck.retryDelaySeconds
    ) {
        self.config = config
        self.fetcher = fetcher
        let nonce = config.nonce
        if let collectStart {
            self.collectStart = collectStart
        } else {
            self.collectStart = { await UseSenseDeviceCheck.defaultStartSignals(nonce: nonce) }
        }
        if let collectFinish {
            self.collectFinish = collectFinish
        } else {
            self.collectFinish = { await UseSenseDeviceCheck.defaultFinishSignals() }
        }
        self.retryDelay = retryDelay
    }

    // MARK: - Public calls

    /// Collect the camera-free device signals and send them with
    /// `phase: "start"`. Call once, before the provider's SDK opens.
    public func start() async -> DeviceCheckResult {
        await run(.start)
    }

    /// Send the camera inventory with `phase: "finish"`. Optional; call once,
    /// after the provider's SDK closes and after `start()` was received.
    public func finish() async -> DeviceCheckResult {
        await run(.finish)
    }

    /// Completion-handler variant of `start()`. The completion runs on the main queue.
    public func start(completion: @escaping (DeviceCheckResult) -> Void) {
        Task {
            let result = await self.run(.start)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Completion-handler variant of `finish()`. The completion runs on the main queue.
    public func finish(completion: @escaping (DeviceCheckResult) -> Void) {
        Task {
            let result = await self.run(.finish)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Flow

    private func run(_ phase: DeviceCheckPhase) async -> DeviceCheckResult {
        if let invalid = Self.validate(config) { return .failed(invalid) }
        guard claim(phase) else {
            let serverCode = phase == .start ? "already_started" : "already_finished"
            return .failed(DeviceCheckError(
                code: .outOfOrder,
                message: "Phase \(phase.rawValue) was already sent for this device check",
                serverCode: serverCode
            ))
        }
        USTrace.log("device check \(phase.rawValue): collecting")
        let collect = phase == .start ? collectStart : collectFinish
        let signals = await collect()
        let result = await post(phase: phase, channelIntegrity: signals)
        settle(phase, received: result.isReceived)
        USTrace.log("device check \(phase.rawValue): \(result.isReceived ? "received" : (result.error?.code.rawValue ?? "failed"))")
        return result
    }

    /// Marks the phase in flight. False when it is already in flight or received.
    private func claim(_ phase: DeviceCheckPhase) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .start:
            guard startState == .idle else { return false }
            startState = .inFlight
        case .finish:
            guard finishState == .idle else { return false }
            finishState = .inFlight
        }
        return true
    }

    /// A failed phase can be sent again; a received one never is.
    private func settle(_ phase: DeviceCheckPhase, received: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let next: PhaseState = received ? .received : .idle
        switch phase {
        case .start: startState = next
        case .finish: finishState = next
        }
    }

    private struct Attempt {
        let result: DeviceCheckResult
        let retry: Bool
    }

    private func post(phase: DeviceCheckPhase, channelIntegrity: [String: Any]) async -> DeviceCheckResult {
        guard let url = Self.signalsURL(baseURL: config.baseURL, deviceCheckId: config.deviceCheckId) else {
            return .failed(DeviceCheckError(code: .invalidConfig, message: "deviceCheckId is not a device check id (dc_...)"))
        }
        let body = Self.body(nonce: config.nonce, phase: phase, channelIntegrity: channelIntegrity)
        // JSONSerialization raises an Objective-C exception (a crash) on a
        // value it cannot encode, so check first.
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failed(DeviceCheckError(code: .invalidInput, message: "Device signals could not be encoded as JSON"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeout
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("UseSense-iOS-SDK/\(UseSenseAPIClient.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = data

        var attempt = await sendWithDeadline(request, phase: phase)
        if attempt.retry {
            USTrace.log("device check \(phase.rawValue): 503, one retry")
            try? await Task.sleep(nanoseconds: UInt64(max(0, retryDelay) * 1_000_000_000))
            attempt = await sendWithDeadline(request, phase: phase)
        }
        return attempt.result
    }

    private func sendWithDeadline(_ request: URLRequest, phase: DeviceCheckPhase) async -> Attempt {
        let attempt = await Deadline.run(seconds: config.requestTimeout) {
            await self.sendOnce(request, phase: phase)
        }
        return attempt ?? Attempt(
            result: .failed(DeviceCheckError(code: .timeout, message: "The device check request timed out")),
            retry: false
        )
    }

    private func sendOnce(_ request: URLRequest, phase: DeviceCheckPhase) async -> Attempt {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetcher(request)
        } catch let error as URLError where error.code == .timedOut {
            return Attempt(result: .failed(DeviceCheckError(code: .timeout, message: error.localizedDescription)), retry: false)
        } catch {
            return Attempt(result: .failed(DeviceCheckError(code: .networkUnavailable, message: error.localizedDescription)), retry: false)
        }
        guard let http = response as? HTTPURLResponse else {
            return Attempt(result: .failed(DeviceCheckError(code: .unknown, message: "Non-HTTP response")), retry: false)
        }
        if (200..<300).contains(http.statusCode) {
            return Attempt(result: .received(phase), retry: false)
        }
        let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = envelope?["code"] as? String
        let message = (envelope?["error"] as? String) ?? "Request failed with status \(http.statusCode)"
        return Attempt(
            result: .failed(Self.translate(status: http.statusCode, code: code, message: message)),
            retry: Self.shouldRetry(status: http.statusCode)
        )
    }

    // MARK: - Pure helpers (tested directly)

    static func validate(_ config: DeviceCheckConfig) -> DeviceCheckError? {
        if !isValidId(config.deviceCheckId) {
            return DeviceCheckError(code: .invalidConfig, message: "deviceCheckId is not a device check id (dc_...)")
        }
        if config.token.isEmpty {
            return DeviceCheckError(code: .invalidConfig, message: "token is empty")
        }
        if config.nonce.isEmpty {
            return DeviceCheckError(code: .invalidConfig, message: "nonce is empty")
        }
        return nil
    }

    /// Same shape the server accepts: `dc_` then 8 to 64 ASCII letters or digits.
    static func isValidId(_ id: String) -> Bool {
        guard id.hasPrefix("dc_") else { return false }
        let rest = id.dropFirst(3).unicodeScalars
        guard (8...64).contains(rest.count) else { return false }
        return rest.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// `{base}/v1/sdk/device-checks/{id}/signals`. The path replaces any path
    /// on the base URL, as the Flows client does.
    static func signalsURL(baseURL: URL, deviceCheckId: String) -> URL? {
        guard isValidId(deviceCheckId),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/v1/sdk/device-checks/\(deviceCheckId)/signals"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func body(nonce: String, phase: DeviceCheckPhase, channelIntegrity: [String: Any]) -> [String: Any] {
        [
            "nonce": nonce,
            "phase": phase.rawValue,
            "channel_integrity": channelIntegrity,
            "client": ["sdk": "ios", "version": UseSenseAPIClient.sdkVersion],
        ]
    }

    /// The finish phase's `channel_integrity.camera_inventory`, under the keys
    /// the server's capture-source analysis reads.
    static func cameraInventory(labels: [String]) -> [String: Any] {
        ["video_input_count": labels.count, "labels": labels]
    }

    /// Map a refusal to the error taxonomy. Kept static so tests can verify
    /// the translation without any I/O.
    static func translate(status: Int, code: String?, message: String) -> DeviceCheckError {
        let mapped: DeviceCheckError.Code
        switch (status, code) {
        case (_, "token_expired"):
            mapped = .tokenExpired
        case (401, _):
            mapped = .tokenInvalid
        case (_, "nonce_mismatch"):
            mapped = .nonceMismatch
        case (400, _), (413, _):
            mapped = .invalidInput
        case (404, _):
            mapped = .notFound
        case (409, _):
            mapped = .outOfOrder
        case (500..., _):
            mapped = .unavailable
        default:
            mapped = .unknown
        }
        return DeviceCheckError(code: mapped, message: message, serverCode: code, httpStatus: status)
    }

    /// Only a 503 is retried, once: the server gives the start back to the
    /// device when scoring fails, so the same request can succeed.
    static func shouldRetry(status: Int) -> Bool {
        status == 503
    }

    // MARK: - Default collectors

    /// The Device Trust step's camera-free channel integrity (no camera or
    /// microphone fields), with App Attest over the check's nonce.
    static func defaultStartSignals(nonce: String) async -> [String: Any] {
        #if canImport(UIKit)
        return await DeviceTrustSignals.collect(nonce: nonce)
        #else
        return ["platform": "ios"]
        #endif
    }

    static func defaultFinishSignals() async -> [String: Any] {
        #if os(iOS) && canImport(AVFoundation)
        return ["camera_inventory": cameraInventory(labels: cameraLabels())]
        #else
        return [:]
        #endif
    }

    #if os(iOS) && canImport(AVFoundation)
    /// Lists the cameras by name. A discovery session only enumerates
    /// devices: it opens no capture session and needs no camera permission.
    static func cameraLabels() -> [String] {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera,
        ]
        if #available(iOS 17.0, *) {
            types.append(.external)
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return discovery.devices.map { $0.localizedName }
    }
    #endif
}

extension UseSense {
    /// A headless silent device check for Your KYC. See `UseSenseDeviceCheck`.
    ///
    ///     let check = UseSense.deviceCheck(config: DeviceCheckConfig(
    ///         deviceCheckId: id, token: token, nonce: nonce))
    ///     _ = await check.start()   // before the provider's SDK opens
    ///     _ = await check.finish()  // after it closes (optional)
    public static func deviceCheck(config: DeviceCheckConfig) -> UseSenseDeviceCheck {
        UseSenseDeviceCheck(config: config)
    }
}
