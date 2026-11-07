import XCTest
@testable import UseSenseSDK

// MARK: - Lenient verdict decoding

/// Real shapes from production/sandbox on 2026-11-06/07. On Android each of
/// these failed the whole verdict decode and turned a decision into error 2001.
final class VerdictDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> FinalDecisionObject {
        try JSONDecoder().decode(FinalDecisionObject.self, from: Data(json.utf8))
    }

    func test_pillarObjects_andFractionalScores_decode() throws {
        let d = try decode(#"""
        {"session_id":"sess_1","session_type":"enrollment","decision":"REJECT",
         "channel_trust_score":81.5,"liveness_score":89,"dedupe_risk_score":92.8,
         "pillar_verdicts":{"deepsense":{"score":82,"verdict":"PASS"},
                            "livesense":{"score":91.5,"verdict":"PASS"},
                            "dedupe":{"score":100,"verdict":"FAIL"}},
         "dedupe_analysis":{"duplicateSearchPerformed":true,"highestDuplicateSimilarity":92.8,"crossIdentityRisk":30.4},
         "reasons":["High similarity with existing enrolled identity"],
         "timestamp":"2026-11-06T21:44:26.430Z"}
        """#)
        XCTAssertEqual(d.decision, "REJECT")
        XCTAssertEqual(d.dedupeRiskScore, 92.8)
        XCTAssertEqual(d.pillarVerdicts?.dedupe?.verdict, "FAIL")
        XCTAssertEqual(d.pillarVerdicts?.livesense?.score, 91.5)
        XCTAssertEqual(d.dedupeAnalysis?.highestDuplicateSimilarity, 92.8, "camelCase keys are read (were silently nil)")
        XCTAssertEqual(d.dedupeAnalysis?.crossIdentityRisk, 30.4)
        XCTAssertEqual(d.redacted().decision, "REJECT")
    }

    func test_snakeCaseDedupeKeys_stillRead() throws {
        let d = try decode(#"{"session_id":"s","decision":"APPROVE","timestamp":"t","dedupe_analysis":{"highest_duplicate_similarity":12.5}}"#)
        XCTAssertEqual(d.dedupeAnalysis?.highestDuplicateSimilarity, 12.5)
    }

    func test_malformedDetailBlocks_areDropped_notFatal() throws {
        let d = try decode(#"""
        {"session_id":"s","decision":"APPROVE","timestamp":"t",
         "pillar_verdicts":{"deepsense":"PASS","livesense":{"score":"93","verdict":"PASS"},"dedupe":[1]},
         "verdict_metadata":{"source":7},
         "geometric_coherence":"oops",
         "sensei_step_up":[1,2],
         "challenge_validation":{"stepsCompliant":2.5},
         "reasons":"not an array"}
        """#)
        XCTAssertEqual(d.decision, "APPROVE")
        XCTAssertNil(d.pillarVerdicts?.deepsense, "an odd pillar is dropped alone")
        XCTAssertEqual(d.pillarVerdicts?.livesense?.score, 93, "numeric strings are read")
        XCTAssertNil(d.pillarVerdicts?.dedupe)
        XCTAssertEqual(d.verdictMetadata?.source, "7")
        XCTAssertNil(d.geometricCoherence)
        XCTAssertNil(d.senseiStepUp)
        XCTAssertEqual(d.challengeValidation?.stepsCompliant, 2.5)
        XCTAssertNil(d.reasons)
    }

    func test_v4Envelope_mapsVerdictToDecision_andToleratesNoTimestamp() throws {
        let d = try decode(#"{"session_id":"s","verdict":"pass","confidence":"high","completed_at":"2026-11-07T01:00:00Z"}"#)
        XCTAssertEqual(d.decision, "APPROVE")
        XCTAssertEqual(d.timestamp, "2026-11-07T01:00:00Z")
        XCTAssertEqual(try decode(#"{"session_id":"s","verdict":"fail"}"#).decision, "REJECT")
        XCTAssertEqual(try decode(#"{"session_id":"s","verdict":"review"}"#).decision, "MANUAL_REVIEW")
        XCTAssertFalse(try decode(#"{"session_id":"s","verdict":"review"}"#).timestamp.isEmpty)
    }

    func test_noDecisionAtAll_stillFails() {
        XCTAssertThrowsError(try decode(#"{"session_id":"s","timestamp":"t"}"#))
    }

    func test_decodingError_isDescribedWithoutSwiftProse() {
        do {
            _ = try decode(#"{"decision":"APPROVE"}"#)
            XCTFail("session_id is required")
        } catch let e as DecodingError {
            XCTAssertEqual(UseSenseAPIClient.describe(e), "key_not_found@.session_id")
        } catch { XCTFail("\(error)") }
    }
}

// MARK: - Subject-facing error copy

final class SubjectErrorCopyTests: XCTestCase {
    func test_serverText_neverShown() {
        let raw = "On-device mesh data failed integrity validation at tier \"binding\"."
        let error = UseSenseError(code: .invalidRequest, message: raw, details: "mesh_integrity_failed")
        let copy = SubjectErrorCopy.forError(error)
        XCTAssertEqual(copy, .generic)
        XCTAssertFalse(copy.body.contains("mesh"))
        XCTAssertEqual(SubjectErrorCopy.caption(for: error), "Error code: INVALID_REQUEST (mesh_integrity_failed)")
    }

    func test_integrationProblems_readAsUnavailable_notCapture() {
        for status in [401, 402, 403, 429, 503] {
            let e = UseSenseError.fromHTTP(statusCode: status, serverCode: nil, serverMessage: "Authentication failed. Check API key.")
            XCTAssertEqual(SubjectErrorCopy.forError(e), .unavailable, "HTTP \(status)")
        }
    }

    func test_buckets() {
        XCTAssertEqual(SubjectErrorCopy.forError(UseSenseError(code: .networkError)), .connection)
        XCTAssertEqual(SubjectErrorCopy.forError(UseSenseError(code: .uploadTimeout)), .connection)
        XCTAssertEqual(SubjectErrorCopy.forError(UseSenseError(code: .noFramesCaptured)), .capture)
        XCTAssertEqual(SubjectErrorCopy.forError(UseSenseError(code: .captureTimeout)), .capture)
        XCTAssertEqual(SubjectErrorCopy.forError(UseSenseError(code: .sessionExpired)), .expired)
        XCTAssertEqual(SubjectErrorCopy.forError(UseSenseError(code: .responseInvalid)), .generic)
    }

    func test_freeTextDetails_notInCaption() {
        let e = UseSenseError(code: .captureTimeout, details: "watchdog: capture phase exceeded its budget")
        XCTAssertEqual(SubjectErrorCopy.caption(for: e), "Error code: CAPTURE_TIMEOUT")
    }

    func test_wireCodes_matchAndroid() {
        XCTAssertEqual(UseSenseErrorCode.noFramesCaptured.rawValue, "NO_FRAMES_CAPTURED")
        XCTAssertEqual(UseSenseErrorCode.captureTimeout.rawValue, "CAPTURE_TIMEOUT")
        XCTAssertEqual(UseSenseErrorCode.uploadTimeout.rawValue, "UPLOAD_TIMEOUT")
    }
}

// MARK: - Session: guards, first frame, resume

#if canImport(AVFoundation) && canImport(UIKit)
final class SessionRetryAndGuardTests: XCTestCase {
    private func makeSession() -> UseSenseSession {
        // Port 9 (discard) on loopback: every request fails fast and never
        // reaches a real server.
        UseSenseSession(config: UseSenseConfig(apiEndpoint: "http://127.0.0.1:9/v1", apiKey: "sk_test"), sessionType: .enrollment)
    }

    private func sessionData() throws -> CreateSessionResponse {
        let json = #"""
        {"session_id":"sess_t","session_token":"tok","expires_at":"2099-01-01T00:00:00.000Z","nonce":"n",
         "policy":{"requires_audio":false,"requires_stepup":false,"challenge_type":"none"},
         "upload":{"max_frames":30,"target_fps":3,"capture_duration_ms":2500}}
        """#
        return try JSONDecoder().decode(CreateSessionResponse.self, from: Data(json.utf8))
    }

    func test_claimOnce_firstCallerWins() {
        let session = makeSession()
        XCTAssertTrue(session.claimOnce("baseline"))
        XCTAssertFalse(session.claimOnce("baseline"), "a double tap can't start a second baseline")
        XCTAssertTrue(session.claimOnce("challenge-complete:1"))
        XCTAssertFalse(session.claimOnce("challenge-complete:1"))
        XCTAssertTrue(session.claimOnce("challenge-complete:2"), "the step-up round completes separately")
    }

    func test_claimOnce_racingCallers_onlyOneWins() {
        let session = makeSession()
        let lock = NSLock()
        var wins = 0
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if session.claimOnce("baseline") { lock.lock(); wins += 1; lock.unlock() }
        }
        XCTAssertEqual(wins, 1)
    }

    func test_firstFrameGate_waitsForTheCamera() async throws {
        let session = makeSession()
        session.firstFrameBudget = 2
        session.setCameraLive(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { session.setCameraLive(true) }
        let started = Date()
        let live = try await session.waitForFirstFrame()
        XCTAssertTrue(live)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15, "the clock didn't start before the first frame")
    }

    func test_firstFrameGate_givesUp_withinBudget() async throws {
        let session = makeSession()
        session.firstFrameBudget = 0.2
        session.setCameraLive(false)
        let live = try await session.waitForFirstFrame()
        XCTAssertFalse(live)
    }

    func test_cannotResume_withoutACapture() throws {
        let session = makeSession()
        session.injectHostedSessionData(try sessionData())
        XCTAssertFalse(session.canResumeFinalization)
    }

    func test_resume_afterAcceptedSignals_goesStraightToComplete() throws {
        let session = makeSession()
        session.injectHostedSessionData(try sessionData())
        session.setFinalizationCheckpointForTesting(pendingFrames: [Data([0xFF])], signalsAccepted: true)
        session.enterStateForTesting(.error(UseSenseError(code: .networkError, isRetryable: true)))
        XCTAssertTrue(session.canResumeFinalization)

        let firstState = expectation(description: "first state after resume")
        let seen = LockedBox<String>()
        session.onStateChange = { state in
            if seen.value == nil { seen.set(state.debugName); firstState.fulfill() }
        }
        Task { await session.resumeFinalization() }
        wait(for: [firstState], timeout: 2)
        session.cancel()
        XCTAssertEqual(seen.value, SessionState.completing.debugName, "no re-upload, no recapture")
    }

    func test_resume_afterFailedUpload_reuploadsTheSameCapture() throws {
        let session = makeSession()
        session.injectHostedSessionData(try sessionData())
        session.setFinalizationCheckpointForTesting(pendingFrames: [Data([0xFF])], signalsAccepted: false)
        session.enterStateForTesting(.error(UseSenseError(code: .uploadTimeout, isRetryable: true)))

        let firstState = expectation(description: "first state after resume")
        let seen = LockedBox<String>()
        session.onStateChange = { state in
            if seen.value == nil { seen.set(state.debugName); firstState.fulfill() }
        }
        Task { await session.resumeFinalization() }
        wait(for: [firstState], timeout: 2)
        session.cancel()
        XCTAssertEqual(seen.value, SessionState.uploading(progress: 0).debugName, "same session, no new capture")
    }

    func test_startOver_dropsTheKeptCapture() async throws {
        let session = makeSession()
        session.injectHostedSessionData(try sessionData())
        session.setFinalizationCheckpointForTesting(pendingFrames: [Data([0xFF])], signalsAccepted: true)
        XCTAssertTrue(session.canResumeFinalization)
        let retrying = Task { await session.retry() }
        try await Task.sleep(nanoseconds: 100_000_000)
        session.cancel()
        retrying.cancel()
        XCTAssertFalse(session.canResumeFinalization)
    }
}
#endif
