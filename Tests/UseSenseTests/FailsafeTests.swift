import XCTest
@testable import UseSenseSDK

/// The fail-safe contract: every async wait is bounded, a capture always ends
/// in a terminal state with a stable code, and an omission in an optional
/// server block degrades instead of killing the session.

// MARK: - Watchdog

final class SessionWatchdogTests: XCTestCase {
    func test_firesWithPhase_whenBudgetRunsOut() {
        let fired = expectation(description: "fired")
        let phase = LockedBox<SessionWatchdog.Phase>()
        let watchdog = SessionWatchdog { p in phase.set(p); fired.fulfill() }
        watchdog.arm(.capture, budget: .init(total: 0.1))
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(phase.value, .capture)
        XCTAssertNil(watchdog.armedPhase, "a fired phase is no longer armed")
    }

    func test_disarm_preventsFire() {
        let fired = expectation(description: "must not fire")
        fired.isInverted = true
        let watchdog = SessionWatchdog { _ in fired.fulfill() }
        watchdog.arm(.upload, budget: .init(total: 0.1))
        watchdog.disarm()
        wait(for: [fired], timeout: 0.4)
    }

    func test_rearm_replacesPhase_andFiresOnce() {
        let fired = expectation(description: "fired once")
        fired.expectedFulfillmentCount = 1
        fired.assertForOverFulfill = true
        let phase = LockedBox<SessionWatchdog.Phase>()
        let watchdog = SessionWatchdog { p in phase.set(p); fired.fulfill() }
        watchdog.arm(.capture, budget: .init(total: 0.1))
        watchdog.arm(.upload, budget: .init(total: 0.2))
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(phase.value, .upload)
        // Give a stale capture timer a chance to (wrongly) fire as well.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 1)
    }

    func test_stallWindow_kicksKeepItAlive_untilProgressStops() {
        let fired = expectation(description: "fired on stall")
        let firedAt = LockedBox<Date>()
        let watchdog = SessionWatchdog { _ in firedAt.set(Date()); fired.fulfill() }
        let start = Date()
        // Windows are generous so a loaded CI runner's scheduling jitter can't
        // make a kick land after the window it was meant to extend.
        watchdog.arm(.upload, budget: .init(total: 30, stall: 1.0))
        // Progress every 0.3s for ~1.5s (past one stall window), then silence.
        for i in 1...5 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3 * Double(i)) { watchdog.kick() }
        }
        wait(for: [fired], timeout: 10)
        let elapsed = firedAt.value!.timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 1.5, "kicks must push the stall deadline back")
        XCTAssertLessThan(elapsed, 8.0, "a stalled phase fails on the stall window, not the hard ceiling")
    }

    func test_phaseCodes_areStable() {
        XCTAssertEqual(SessionWatchdog.Phase.capture.errorCode.rawValue, "CAPTURE_TIMEOUT")
        XCTAssertEqual(SessionWatchdog.Phase.upload.errorCode.rawValue, "UPLOAD_TIMEOUT")
        XCTAssertEqual(SessionWatchdog.captureBudget.total, 120)
    }
}

// MARK: - Deadline

final class DeadlineTests: XCTestCase {
    func test_returnsValue_whenOperationIsFast() async {
        let value = await Deadline.run(seconds: 1) { 42 }
        XCTAssertEqual(value, 42)
    }

    /// The bug this replaced: a task-group race waits for every child, so an
    /// operation that ignores cancellation (App Attest) held the caller.
    func test_returnsAtDeadline_evenWhenOperationIgnoresCancellation() async {
        let start = Date()
        let value: Int? = await Deadline.run(seconds: 0.1) {
            await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.resume(returning: 1) }
            }
        }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func test_returnsNil_whenCallerIsCancelled() async {
        let task = Task { () -> Int? in
            await Deadline.run(seconds: 10) {
                await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.resume(returning: 1) }
                }
            }
        }
        let start = Date()
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}

// MARK: - Session wiring

#if canImport(AVFoundation) && canImport(UIKit)
final class SessionFailsafeTests: XCTestCase {
    private func makeSession() -> UseSenseSession {
        UseSenseSession(config: UseSenseConfig(apiKey: "sk_test"), sessionType: .enrollment)
    }

    func test_captureTimeout_movesUIToRetryableTerminalError_andEmitsCode() {
        let session = makeSession()
        let errorEvent = expectation(description: "error event")
        let code = LockedBox<String>()
        _ = session.addEventListener { event in
            if event.type == .error { code.set(event.data?["code"] ?? ""); errorEvent.fulfill() }
        }
        session.enterStateForTesting(.baseline(remaining: 2))
        session.handleWatchdogTimeout(.capture)
        wait(for: [errorEvent], timeout: 1)
        XCTAssertEqual(code.value, "CAPTURE_TIMEOUT")
        guard case .error(let error) = session.stateForTesting else {
            return XCTFail("expected a terminal error, got \(session.stateForTesting.debugName)")
        }
        XCTAssertEqual(error.code, .captureTimeout)
        XCTAssertTrue(error.isRetryable, "Try again must be offered")
        XCTAssertTrue(session.canRestartInPlace, "nothing was uploaded, so retry runs in place")
    }

    func test_realWatchdog_firesThroughSession() {
        let session = makeSession()
        let reachedError = expectation(description: "terminal error")
        session.onStateChange = { state in
            if case .error(let e) = state, e.code == .uploadTimeout { reachedError.fulfill() }
        }
        session.enterStateForTesting(.uploading(progress: 0))
        session.uploadBudget = .init(total: 0.1)
        session.armWatchdogForTesting(.upload)
        wait(for: [reachedError], timeout: 2)
    }

    func test_timeout_isIgnored_onceTerminal() {
        let session = makeSession()
        session.enterStateForTesting(.error(UseSenseError(code: .sessionExpired)))
        session.handleWatchdogTimeout(.upload)
        guard case .error(let error) = session.stateForTesting else { return XCTFail() }
        XCTAssertEqual(error.code, .sessionExpired, "a timeout never overwrites a real outcome")
    }

    func test_terminalState_disarmsWatchdog() {
        let session = makeSession()
        session.enterStateForTesting(.baseline(remaining: 2))
        session.armWatchdogForTesting(.capture)
        XCTAssertEqual(session.watchdogPhaseForTesting, .capture)
        session.enterStateForTesting(.error(UseSenseError(code: .captureFailed)))
        XCTAssertNil(session.watchdogPhaseForTesting)
    }
}
#endif

// MARK: - Tolerant decoding

final class TolerantDecodingTests: XCTestCase {
    private func response(geometricCoherence: String = "", policyExtra: String = "", drop: String? = nil) -> Data {
        var fields = [
            #""session_id": "ses_1""#,
            #""session_token": "tok_1""#,
            #""expires_at": "2026-11-01T12:00:00.000Z""#,
            #""nonce": "n_1""#,
            #""policy": {"requires_audio": false, "requires_stepup": false, "challenge_type": "none"\#(policyExtra)}"#,
            #""upload": {"max_frames": 30, "target_fps": 3, "capture_duration_ms": 8000}"#,
        ]
        if let drop { fields.removeAll { $0.hasPrefix("\"\(drop)\"") } }
        if !geometricCoherence.isEmpty { fields.append(#""geometric_coherence": \#(geometricCoherence)"#) }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    private func decode(_ data: Data) throws -> CreateSessionResponse {
        try JSONDecoder().decode(CreateSessionResponse.self, from: data)
    }

    /// The production failure: screen_illumination_enabled omitted and
    /// mesh_binding_challenge null threw "The data couldn't be read because it
    /// is missing." and killed the session.
    func test_geometricCoherence_missingBoolAndNullString_degrade() throws {
        let r = try decode(response(geometricCoherence: #"{"dual_path_enabled": true, "on_device_3dmm_required": true, "mesh_binding_challenge": null}"#))
        let gc = try XCTUnwrap(r.geometricCoherence)
        XCTAssertTrue(gc.dualPathEnabled)
        XCTAssertTrue(gc.onDevice3dmmRequired)
        XCTAssertFalse(gc.screenIlluminationEnabled)
        XCTAssertEqual(gc.meshBindingChallenge, "")
        XCTAssertNil(gc.meshBindingChallenge.nilIfEmpty, "an omitted challenge is treated as absent downstream")
    }

    func test_geometricCoherence_emptyObject_allOff() throws {
        let gc = try XCTUnwrap(try decode(response(geometricCoherence: "{}")).geometricCoherence)
        XCTAssertFalse(gc.dualPathEnabled)
        XCTAssertFalse(gc.screenIlluminationEnabled)
        XCTAssertFalse(gc.onDevice3dmmRequired)
        XCTAssertEqual(gc.meshBindingChallenge, "")
    }

    func test_geometricCoherence_mistypedValues_degrade() throws {
        let gc = try XCTUnwrap(try decode(response(geometricCoherence: #"{"dual_path_enabled": 1, "screen_illumination_enabled": "true", "on_device_3dmm_required": null, "mesh_binding_challenge": 7}"#)).geometricCoherence)
        XCTAssertTrue(gc.dualPathEnabled)
        XCTAssertTrue(gc.screenIlluminationEnabled)
        XCTAssertFalse(gc.onDevice3dmmRequired)
        XCTAssertEqual(gc.meshBindingChallenge, "")
    }

    func test_geometricCoherence_wrongShape_isDropped() throws {
        XCTAssertNil(try decode(response(geometricCoherence: #""oops""#)).geometricCoherence)
        XCTAssertNil(try decode(response(geometricCoherence: "null")).geometricCoherence)
    }

    func test_fullGeometricCoherence_stillDecodesExactly() throws {
        let gc = try XCTUnwrap(try decode(response(geometricCoherence: #"{"dual_path_enabled": true, "screen_illumination_enabled": true, "on_device_3dmm_required": false, "mesh_binding_challenge": "ab12"}"#)).geometricCoherence)
        XCTAssertTrue(gc.screenIlluminationEnabled)
        XCTAssertEqual(gc.meshBindingChallenge, "ab12")
    }

    func test_inlineStepUp_missingFields_useDefaults() throws {
        let r = try decode(response(policyExtra: #", "inline_step_up": {"suspicion_threshold": null}"#))
        let isu = try XCTUnwrap(r.policy.inlineStepUp)
        XCTAssertFalse(isu.enabled)
        XCTAssertEqual(isu.suspicionThreshold, 55)
        XCTAssertEqual(isu.preferredChallenge, "auto")
    }

    func test_malformedOptionalPolicyBlocks_areDropped() throws {
        let r = try decode(response(policyExtra: #", "screenIllumination": "x", "meshIntegrity": [1], "geometricCoherence": 3"#))
        XCTAssertNil(r.policy.screenIllumination)
        XCTAssertNil(r.policy.meshIntegrity)
        XCTAssertNil(r.policy.geometricCoherencePolicy)
    }

    func test_requiredIdentityFields_stayStrict() {
        for key in ["session_id", "session_token", "nonce"] {
            XCTAssertThrowsError(try decode(response(drop: key)), "\(key) must remain required")
        }
        let nullToken = Data(String(decoding: response(), as: UTF8.self)
            .replacingOccurrences(of: #""session_token": "tok_1""#, with: #""session_token": null"#).utf8)
        XCTAssertThrowsError(try decode(nullToken), "a null session_token must not decode")
    }

    /// End to end through the Flows client: the init-session body that broke
    /// production now yields a usable session.
    func test_flowsInitSession_withPartialGeometricCoherence_succeeds() async throws {
        let body: [String: Any] = [
            "session_id": "ses_1", "session_token": "tok_1", "nonce": "n_1",
            "policy": ["requires_audio": false, "requires_stepup": false, "challenge_type": "none"],
            "upload": ["max_frames": 30, "target_fps": 3, "capture_duration_ms": 8000],
            "geometric_coherence": ["dual_path_enabled": false, "on_device_3dmm_required": true, "mesh_binding_challenge": NSNull()],
        ]
        let client = FlowsClient(flowRunId: "fr_1", sdkToken: "t", apiBaseURL: URL(string: "https://api.usesense.ai")!) { request in
            XCTAssertEqual(request.timeoutInterval, FlowsClient.requestTimeout)
            let data = try JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let r = try await client.initSession(toolId: "face")
        XCTAssertEqual(r.sessionId, "ses_1")
        XCTAssertEqual(r.geometricCoherence?.onDevice3dmmRequired, true)
        XCTAssertEqual(r.geometricCoherence?.screenIlluminationEnabled, false)
    }
}

// MARK: - Flow error surface

final class FlowFailsafeErrorTests: XCTestCase {
    func test_retryability_andDisplayCode() {
        XCTAssertFalse(FlowError(code: .tokenExpired, message: "").isRetryable)
        XCTAssertFalse(FlowError(code: .tokenInvalid, message: "").isRetryable)
        XCTAssertTrue(FlowError(code: .networkUnavailable, message: "").isRetryable)
        XCTAssertTrue(FlowError(code: .stepTimeout, message: "").isRetryable)
        XCTAssertEqual(FlowError(code: .stepTimeout, message: "").displayCode, "STEP_TIMEOUT")
        XCTAssertEqual(FlowError(code: .providerUnavailable, message: "", serverCode: "CAPTURE_FAILED").displayCode, "CAPTURE_FAILED")
    }

    #if canImport(UIKit) && canImport(SafariServices)
    func test_captureErrors_keepTheirCode_intoTheFlow() {
        let timeout = FlowsRunnerViewController.flowError(fromCapture: UseSenseError(code: .captureTimeout, isRetryable: true))
        XCTAssertEqual(timeout.code, .captureTimeout)
        XCTAssertEqual(timeout.displayCode, "CAPTURE_TIMEOUT")
        let upload = FlowsRunnerViewController.flowError(fromCapture: UseSenseError(code: .uploadTimeout, isRetryable: true))
        XCTAssertEqual(upload.code, .uploadTimeout)
        let other = FlowsRunnerViewController.flowError(fromCapture: UseSenseError(code: .serverError))
        XCTAssertEqual(other.code, .providerUnavailable)
        XCTAssertEqual(other.displayCode, "SERVER_ERROR")
    }

    func test_subjectMessage_neverLeaksTransportOrDecoderText() {
        let raw = "Failed to decode init-session response: The data couldn't be read because it is missing."
        let message = FlowsRunnerViewController.subjectMessage(for: FlowError(code: .unknown, message: raw))
        XCTAssertFalse(message.contains("decode"))
    }
    #endif
}
