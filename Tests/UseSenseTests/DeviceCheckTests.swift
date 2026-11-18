import XCTest
@testable import UseSenseSDK

/// Silent device check (Your KYC). Load-bearing:
///
///   1. Payload: Bearer dct_ header, the signals path, and the body the
///      server reads (nonce, phase, channel_integrity, client).
///   2. Error mapping: 401 / 400 / 404 / 409 / 503 to DeviceCheckError, a
///      single retry on 503 only, and no resend of a phase after a 202.
final class DeviceCheckTests: XCTestCase {
    private let baseURL = URL(string: "https://api.usesense.ai")!
    private let id = "dc_6f1c0a9b2e7d4c11"
    private let token = "dct_9a4e000000000000000000000000000000000000000000"
    private let nonce = "dn_2b7d0000"

    private func config(id: String? = nil, token: String? = nil, nonce: String? = nil) -> DeviceCheckConfig {
        DeviceCheckConfig(deviceCheckId: id ?? self.id, token: token ?? self.token, nonce: nonce ?? self.nonce, baseURL: baseURL)
    }

    /// A fetcher that answers each call with the next status in `statuses`
    /// (the last one repeats) and records every request.
    private func fetcher(
        statuses: [Int],
        body: [String: Any] = [:],
        requests: RequestLog
    ) -> UseSenseDeviceCheck.Fetcher {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return { request in
            let n = requests.append(request)
            let status = statuses[min(n - 1, statuses.count - 1)]
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response)
        }
    }

    private func check(
        _ config: DeviceCheckConfig? = nil,
        statuses: [Int] = [202],
        body: [String: Any] = ["received": true],
        requests: RequestLog
    ) -> UseSenseDeviceCheck {
        UseSenseDeviceCheck(
            config: config ?? self.config(),
            fetcher: fetcher(statuses: statuses, body: body, requests: requests),
            collectStart: { ["platform": "ios", "is_jailbroken": false, "app_attest_key_id": "key_1"] },
            collectFinish: { ["camera_inventory": UseSenseDeviceCheck.cameraInventory(labels: ["Front Camera", "Back Camera"])] },
            retryDelay: 0
        )
    }

    private func json(_ request: URLRequest?) throws -> [String: Any] {
        let body = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - Payload building

    func test_body_hasNoncePhaseChannelIntegrityAndClient() {
        let body = UseSenseDeviceCheck.body(nonce: "dn_1", phase: .start, channelIntegrity: ["is_jailbroken": false])
        XCTAssertEqual(body["nonce"] as? String, "dn_1")
        XCTAssertEqual(body["phase"] as? String, "start")
        XCTAssertEqual((body["channel_integrity"] as? [String: Any])?["is_jailbroken"] as? Bool, false)
        let client = body["client"] as? [String: Any]
        XCTAssertEqual(client?["sdk"] as? String, "ios")
        XCTAssertEqual(client?["version"] as? String, UseSense.version)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func test_cameraInventory_usesServerKeys() {
        let inv = UseSenseDeviceCheck.cameraInventory(labels: ["Front Camera", "Back Camera"])
        XCTAssertEqual(inv["video_input_count"] as? Int, 2)
        XCTAssertEqual(inv["labels"] as? [String], ["Front Camera", "Back Camera"])
    }

    func test_signalsURL_replacesBasePath() {
        let a = UseSenseDeviceCheck.signalsURL(baseURL: baseURL, deviceCheckId: id)
        XCTAssertEqual(a?.absoluteString, "https://api.usesense.ai/v1/sdk/device-checks/\(id)/signals")
        let b = UseSenseDeviceCheck.signalsURL(baseURL: URL(string: "https://staging.api.usesense.ai/v1")!, deviceCheckId: id)
        XCTAssertEqual(b?.absoluteString, "https://staging.api.usesense.ai/v1/sdk/device-checks/\(id)/signals")
    }

    func test_isValidId_matchesServerShape() {
        XCTAssertTrue(UseSenseDeviceCheck.isValidId(id))
        XCTAssertFalse(UseSenseDeviceCheck.isValidId("dc_short"))
        XCTAssertFalse(UseSenseDeviceCheck.isValidId("fr_6f1c0a9b2e7d4c11"))
        XCTAssertFalse(UseSenseDeviceCheck.isValidId("dc_6f1c0a9b/../x"))
        XCTAssertFalse(UseSenseDeviceCheck.isValidId("dc_6f1c0a9b2e7d4c11\n"))
        XCTAssertNil(UseSenseDeviceCheck.signalsURL(baseURL: baseURL, deviceCheckId: "dc_6f1c0a9b/../x"))
    }

    func test_start_postsBearerToken_toSignalsPath_withCollectedSignals() async throws {
        let log = RequestLog()
        let result = await check(requests: log).start()
        XCTAssertEqual(result, .received(.start))
        let req = try XCTUnwrap(log.last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/v1/sdk/device-checks/\(id)/signals")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(req.url?.absoluteString.contains(token) ?? true, "token must not appear in the URL")
        let body = try json(req)
        XCTAssertEqual(body["nonce"] as? String, nonce)
        XCTAssertEqual(body["phase"] as? String, "start")
        let ci = body["channel_integrity"] as? [String: Any]
        XCTAssertEqual(ci?["app_attest_key_id"] as? String, "key_1")
        XCTAssertEqual(ci?["is_jailbroken"] as? Bool, false)
    }

    func test_finish_postsCameraInventory() async throws {
        let log = RequestLog()
        let c = check(requests: log)
        _ = await c.start()
        let result = await c.finish()
        XCTAssertEqual(result, .received(.finish))
        let body = try json(log.last)
        XCTAssertEqual(body["phase"] as? String, "finish")
        let inv = (body["channel_integrity"] as? [String: Any])?["camera_inventory"] as? [String: Any]
        XCTAssertEqual(inv?["video_input_count"] as? Int, 2)
    }

    #if canImport(UIKit)
    func test_defaultStartSignals_dropCameraAndMicrophoneFields() {
        // The start phase reuses the Device Trust collector, which strips these.
        for key in ["camera_facing", "camera_resolution", "camera_permission_granted", "microphone_permission_granted"] {
            XCTAssertTrue(DeviceTrustSignals.captureOnlyKeys.contains(key), key)
        }
    }
    #endif

    // MARK: - Error mapping

    func test_translate_mapsServerCodes() {
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 401, code: "invalid_token", message: "m").code, .tokenInvalid)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 401, code: "token_expired", message: "m").code, .tokenExpired)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 400, code: "nonce_mismatch", message: "m").code, .nonceMismatch)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 400, code: "invalid_phase", message: "m").code, .invalidInput)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 400, code: "invalid_input", message: "m").code, .invalidInput)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 413, code: "too_large", message: "m").code, .invalidInput)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 404, code: "not_found", message: "m").code, .notFound)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 409, code: "already_started", message: "m").code, .outOfOrder)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 409, code: "not_started", message: "m").code, .outOfOrder)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 503, code: "scoring_failed", message: "m").code, .unavailable)
        XCTAssertEqual(UseSenseDeviceCheck.translate(status: 418, code: nil, message: "m").code, .unknown)
        let e = UseSenseDeviceCheck.translate(status: 409, code: "already_finished", message: "done")
        XCTAssertEqual(e.serverCode, "already_finished")
        XCTAssertEqual(e.httpStatus, 409)
        XCTAssertEqual(e.message, "done")
    }

    func test_onlyA503IsRetried() {
        XCTAssertTrue(UseSenseDeviceCheck.shouldRetry(status: 503))
        for status in [400, 401, 404, 409, 413, 500, 502] {
            XCTAssertFalse(UseSenseDeviceCheck.shouldRetry(status: status), "\(status)")
        }
    }

    func test_401_isTokenInvalid_andNotRetried() async {
        let log = RequestLog()
        let result = await check(statuses: [401], body: ["error": "Missing or wrong device check token", "code": "invalid_token"], requests: log).start()
        XCTAssertEqual(result.error?.code, .tokenInvalid)
        XCTAssertEqual(result.error?.serverCode, "invalid_token")
        XCTAssertEqual(result.error?.isRetryable, false)
        XCTAssertEqual(log.count, 1)
    }

    func test_400_nonceMismatch() async {
        let log = RequestLog()
        let result = await check(statuses: [400], body: ["error": "Nonce does not match this device check", "code": "nonce_mismatch"], requests: log).start()
        XCTAssertEqual(result.error?.code, .nonceMismatch)
        XCTAssertEqual(log.count, 1)
    }

    func test_409_outOfOrder() async {
        let log = RequestLog()
        let result = await check(statuses: [409], body: ["error": "Send phase start before finish", "code": "not_started"], requests: log).finish()
        XCTAssertEqual(result.error?.code, .outOfOrder)
        XCTAssertEqual(result.error?.serverCode, "not_started")
    }

    func test_503_retriesOnce_thenSucceeds() async {
        let log = RequestLog()
        let result = await check(statuses: [503, 202], body: ["error": "Device scoring failed; send start again", "code": "scoring_failed"], requests: log).start()
        XCTAssertEqual(result, .received(.start))
        XCTAssertEqual(log.count, 2)
    }

    func test_503_twice_isUnavailable_afterExactlyOneRetry() async {
        let log = RequestLog()
        let result = await check(statuses: [503], body: ["error": "Device scoring failed; send start again", "code": "scoring_failed"], requests: log).start()
        XCTAssertEqual(result.error?.code, .unavailable)
        XCTAssertEqual(result.error?.isRetryable, true)
        XCTAssertEqual(log.count, 2)
    }

    func test_start_isNeverResentAfter202() async {
        let log = RequestLog()
        let c = check(requests: log)
        let first = await c.start()
        XCTAssertEqual(first, .received(.start))
        let again = await c.start()
        XCTAssertEqual(again.error?.code, .outOfOrder)
        XCTAssertEqual(again.error?.serverCode, "already_started")
        XCTAssertEqual(log.count, 1, "a second start must not reach the network")
    }

    func test_failedStart_canBeSentAgain() async {
        let log = RequestLog()
        let c = check(statuses: [500, 202], requests: log)
        let failed = await c.start()
        XCTAssertEqual(failed.error?.code, .unavailable)
        let retried = await c.start()
        XCTAssertEqual(retried, .received(.start))
        XCTAssertEqual(log.count, 2)
    }

    func test_networkError_isNetworkUnavailable() async {
        let c = UseSenseDeviceCheck(
            config: config(),
            fetcher: { _ in throw URLError(.notConnectedToInternet) },
            collectStart: { ["platform": "ios"] },
            retryDelay: 0
        )
        let result = await c.start()
        XCTAssertEqual(result.error?.code, .networkUnavailable)
    }

    func test_urlTimeout_isTimeout() async {
        let c = UseSenseDeviceCheck(
            config: config(),
            fetcher: { _ in throw URLError(.timedOut) },
            collectStart: { ["platform": "ios"] },
            retryDelay: 0
        )
        let result = await c.start()
        XCTAssertEqual(result.error?.code, .timeout)
    }

    func test_invalidConfig_neverReachesNetwork() async {
        let log = RequestLog()
        let badId = await check(config(id: "fr_123"), requests: log).start()
        XCTAssertEqual(badId.error?.code, .invalidConfig)
        let noToken = await check(config(token: "  "), requests: log).start()
        XCTAssertEqual(noToken.error?.code, .invalidConfig)
        let noNonce = await check(config(nonce: ""), requests: log).start()
        XCTAssertEqual(noNonce.error?.code, .invalidConfig)
        XCTAssertEqual(log.count, 0)
    }

    func test_unencodableSignals_failWithoutCrashing() async {
        let log = RequestLog()
        let c = UseSenseDeviceCheck(
            config: config(),
            fetcher: fetcher(statuses: [202], requests: log),
            collectStart: { ["not_json": Date()] },
            retryDelay: 0
        )
        let result = await c.start()
        XCTAssertEqual(result.error?.code, .invalidInput)
        XCTAssertEqual(log.count, 0)
    }

    func test_completionVariant_deliversOnMain() {
        let log = RequestLog()
        let c = check(requests: log)
        let done = expectation(description: "completion")
        c.start { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result, .received(.start))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testDeviceTrustPayloadCarriesTelemetryWithoutCaptureKeys() {
        let collected: [String: Any] = [
            "device_model": "iPhone18,1",
            "cpu_abi": "from-collector",
            "camera_resolution": "1280x720",
            "camera_permission_granted": true,
        ]
        let telemetry: [String: Any] = [
            "cpu_abi": "arm64",
            "total_ram_mb": 8192,
            "storage_available_mb": 40000,
        ]
        let ci = DeviceTrustSignals.build(collected: collected, telemetry: telemetry)
        XCTAssertEqual(ci["total_ram_mb"] as? Int, 8192)
        XCTAssertEqual(ci["storage_available_mb"] as? Int, 40000)
        XCTAssertEqual(ci["device_model"] as? String, "iPhone18,1")
        // Collector values win on a clash.
        XCTAssertEqual(ci["cpu_abi"] as? String, "from-collector")
        // Nothing was captured.
        XCTAssertNil(ci["camera_resolution"])
        XCTAssertNil(ci["camera_permission_granted"])
    }

    func testRealTelemetryHasTheHardwareSignalsTheServerScores() {
        let telemetry = DeviceSignalCollector().collectDeviceTelemetry()
        XCTAssertNotNil(telemetry["cpu_abi"])
        XCTAssertNotNil(telemetry["total_ram_mb"])
    }
}

/// Records every request a fetcher saw, thread-safely.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    /// Appends and returns the new count.
    func append(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return requests.count
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
}
