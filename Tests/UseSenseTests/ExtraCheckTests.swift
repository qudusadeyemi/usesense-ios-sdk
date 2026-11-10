import XCTest
@testable import UseSenseSDK

/// The extra check drawn on the scan screen (storyboard flows 4 to 6):
/// the challenge timeline, the pages it ends on, and the Speak Digits
/// microphone fallback.
final class ExtraCheckTests: XCTestCase {

    // MARK: Fixtures

    private func headTurn(_ dirs: [HeadDirection] = [.left, .right, .center], ms: Int = 1000) -> ChallengeRunner {
        let steps = dirs.enumerated().map { HeadTurnStep(direction: $0.element, durationMs: ms, index: $0.offset) }
        return ChallengeRunner(plan: .headTurn(steps))
    }

    private func followDot() -> ChallengeRunner {
        let pts: [(Float, Float)] = [(0.5, 0.3), (0.8, 0.25), (0.2, 0.6), (0.7, 0.5)]
        let wps = pts.enumerated().map { FollowDotWaypoint(x: $0.element.0, y: $0.element.1, durationMs: 1000, index: $0.offset) }
        return ChallengeRunner(plan: .followDot(wps))
    }

    private var clock: TimeInterval = 0

    @discardableResult
    private func run(_ r: inout ChallengeRunner, _ seconds: TimeInterval, face: Bool = true, yaw: Double? = 25,
                     pitch: Double? = 0, level: Double? = nil, held: Bool = false) -> ChallengeDisplay {
        var d = r.display()
        let end = clock + seconds
        while clock < end - 1e-9 {
            clock += 0.05
            d = r.advance(ChallengeObservation(time: clock, facePresent: face, yaw: yaw, pitch: pitch, level: level, held: held))
        }
        return d
    }

    override func setUp() {
        super.setUp()
        clock = 0
    }

    // MARK: Head Turn

    func testHeadTurnRunsEachStepWithItsInstructionAndFinishes() {
        var r = headTurn()
        var d = run(&r, 0.5)
        XCTAssertEqual(d.title, "Turn your head to the left")
        XCTAssertEqual(d.subtitle, "Slowly")
        XCTAssertEqual(d.arrow, .left)
        XCTAssertEqual(r.specStepIndex, 0)
        d = run(&r, 1.0)
        XCTAssertEqual(d.title, "Now to the right")
        XCTAssertNil(d.subtitle)
        XCTAssertEqual(d.arrow, .right)
        XCTAssertEqual(r.specStepIndex, 1)
        d = run(&r, 1.0)
        XCTAssertEqual(d.title, "Now look straight ahead")
        XCTAssertNil(d.arrow)
        d = run(&r, 0.6)
        XCTAssertTrue(d.finished)
        XCTAssertEqual(d.progress, 1)
        XCTAssertEqual(r.retriesLeft, 1, "no retry needed")
    }

    func testBeforeTheFaceIsSeenTheRingWaits() {
        var r = headTurn()
        let d = run(&r, 2, face: false)
        XCTAssertEqual(d.title, "Show your face in the oval")
        XCTAssertEqual(d.progress, 0)
        XCTAssertEqual(d.tone, .active)
    }

    func testFaceLeavingTheOvalPausesThenResumes() {
        var r = headTurn()
        run(&r, 0.5)
        let before = r.progress
        var d = run(&r, 1.5, face: false)
        XCTAssertEqual(d.tone, .warning)
        XCTAssertEqual(d.title, "Move your face to the centre")
        XCTAssertEqual(d.subtitle, "Then keep turning")
        XCTAssertNil(d.arrow)
        XCTAssertLessThan(r.progress - before, 0.11, "only the 0.3 s grace runs on")
        d = run(&r, 0.3)
        XCTAssertEqual(d.tone, .active)
        XCTAssertGreaterThan(r.progress, before)
    }

    func testAOneFrameDropDoesNotPause() {
        var r = headTurn()
        run(&r, 0.5)
        let d = run(&r, 0.1, face: false)
        XCTAssertEqual(d.tone, .active)
    }

    func testNeverFailsOnTheDeviceWhileTheFaceIsAway() {
        var r = headTurn()
        run(&r, 0.5)
        let d = run(&r, 120, face: false)
        XCTAssertFalse(d.finished)
        XCTAssertEqual(d.tone, .warning)
    }

    func testAShortTurnGetsOneRetryWithAHintThenTheServerDecides() {
        var r = headTurn([.left, .center])
        var d = run(&r, 1.05, yaw: 3)
        XCTAssertEqual(d.title, "Let's try that again")
        XCTAssertEqual(d.subtitle, "Turn a little further to the left")
        XCTAssertEqual(d.arrow, .left)
        XCTAssertEqual(r.specStepIndex, 0, "the same step again")
        XCTAssertEqual(r.retriesLeft, 0)
        d = run(&r, 1.0, yaw: 3)
        XCTAssertEqual(d.title, "Now look straight ahead", "a second short turn moves on")
        d = run(&r, 1.1)
        XCTAssertTrue(d.finished)
    }

    func testTheRetryIsOnlyOnceAcrossTheWholeChallenge() {
        var r = headTurn([.left, .right, .center])
        run(&r, 1.05, yaw: 2)          // left short: retry
        run(&r, 1.0, yaw: 20)          // left ok
        let d = run(&r, 1.05, yaw: 2)  // right short: no retries left
        XCTAssertNotEqual(d.title, "Let's try that again")
        XCTAssertEqual(r.specStepIndex, 2)
    }

    func testNoPoseReadingsMeansNoRetry() {
        var r = headTurn([.left, .center])
        let d = run(&r, 1.05, yaw: nil)
        XCTAssertEqual(d.title, "Now look straight ahead")
    }

    func testUpAndDownUsePitch() {
        var r = headTurn([.up, .center])
        var d = run(&r, 0.3, yaw: 0, pitch: 2)
        XCTAssertEqual(d.title, "Look up")
        XCTAssertEqual(d.arrow, .up)
        d = run(&r, 0.8, yaw: 0, pitch: 2)
        XCTAssertEqual(d.subtitle, "Look a little further up")
    }

    func testTheLeaveDialogHoldsTheTimeline() {
        var r = headTurn()
        run(&r, 0.5)
        let before = r.progress
        let d = run(&r, 5, held: true)
        XCTAssertEqual(r.progress, before, accuracy: 0.001)
        XCTAssertEqual(d.tone, .active)
    }

    // MARK: Follow Dot

    func testFollowDotGlidesToEachWaypointAndLeavesATrail() {
        var r = followDot()
        var d = run(&r, 0.3)
        XCTAssertEqual(d.title, "Follow the dot with your head")
        XCTAssertEqual(d.dot!.x, 0.5, accuracy: 0.001)
        d = run(&r, 1.2)   // 0.5 s into step 1: the glide (0.4 s) is done
        XCTAssertEqual(d.dot!.x, 0.8, accuracy: 0.01)
        XCTAssertEqual(d.trail.count, 2)
        d = run(&r, 1.0)
        XCTAssertEqual(d.title, "Keep following")
        d = run(&r, 1.9)
        XCTAssertTrue(d.finished)
    }

    func testTheDotWaitsWhileTheFaceIsAway() {
        var r = followDot()
        run(&r, 1.1)
        let paused = run(&r, 0.4, face: false)
        let lost = run(&r, 3, face: false)
        XCTAssertEqual(lost.title, "Show your face in the oval")
        XCTAssertEqual(lost.subtitle, "The dot will wait for you")
        XCTAssertEqual(lost.tone, .warning)
        XCTAssertEqual(lost.dot!.x, paused.dot!.x, accuracy: 0.001)
        XCTAssertEqual(lost.progress, paused.progress, accuracy: 0.001)
    }

    // MARK: Speak Digits

    func testDigitsShowTheNumbersAndSayWhenItIsTooQuiet() {
        var r = ChallengeRunner(plan: .digits(phrase: "4 7 2 9", durationMs: 8000))
        var d = run(&r, 1, level: 0.5)
        XCTAssertEqual(d.title, "Say these numbers")
        XCTAssertEqual(d.digits, "4 7 2 9")
        d = run(&r, 1.9, level: 0.02)
        XCTAssertEqual(d.title, "Say these numbers", "not yet 2 s")
        d = run(&r, 0.2, level: 0.02)
        XCTAssertEqual(d.title, "We can't hear you")
        XCTAssertEqual(d.subtitle, "Speak a little louder")
        XCTAssertEqual(d.tone, .warning)
        d = run(&r, 0.1, level: 0.6)
        XCTAssertEqual(d.title, "Say these numbers")
        d = run(&r, 5, level: 0.6)
        XCTAssertTrue(d.finished)
    }

    func testMeterScale() {
        XCTAssertEqual(AudioCaptureManager.normalised(decibels: -160), 0)
        XCTAssertEqual(AudioCaptureManager.normalised(decibels: 0), 1)
        XCTAssertLessThan(AudioCaptureManager.normalised(decibels: -42), ChallengeRunner.quietLevel)
        XCTAssertGreaterThan(AudioCaptureManager.normalised(decibels: -25), ChallengeRunner.quietLevel)
    }

    // MARK: Presence

    func testFaceInOval() {
        XCTAssertTrue(ChallengeRunner.faceInOval(centreOffset: CGPoint(x: 0.3, y: -0.2)))
        XCTAssertFalse(ChallengeRunner.faceInOval(centreOffset: CGPoint(x: 0.7, y: 0)))
        XCTAssertFalse(ChallengeRunner.faceInOval(centreOffset: nil))
    }

    // MARK: Sheet copy

    func testSheetSentencePerChallenge() throws {
        let head = try decodeSpec(#"{"type":"head_turn","seed":"s","total_duration_ms":3500,"sequence":[{"direction":"right","duration_ms":2000,"index":0},{"direction":"up","duration_ms":2000,"index":1},{"direction":"center","duration_ms":1500,"index":2}]}"#)
        XCTAssertEqual(ExtraCheckCopy.sheetBody(for: head), "Slowly turn your head to the right, then up.")
        XCTAssertEqual(ExtraCheckCopy.sheetBody(.headTurn), "Slowly turn your head to the left, then to the right.")
        XCTAssertEqual(ExtraCheckCopy.sheetBody(.followDot), "Keep your face in the oval and follow the dot with your head.")
    }

    // MARK: Pages

    func testDecisionPages() {
        XCTAssertEqual(GuidedScreen.forDecision("APPROVE", retriesLeft: 0), .approved)
        XCTAssertEqual(GuidedScreen.forDecision("MANUAL_REVIEW", retriesLeft: 0), .review)
        XCTAssertEqual(GuidedScreen.forDecision("REJECT", retriesLeft: 0), .rejected(canRetry: false, onceMore: false))
        XCTAssertEqual(GuidedScreen.forDecision("reject", retriesLeft: 1), .rejected(canRetry: true, onceMore: true))
        XCTAssertEqual(GuidedScreen.forDecision("REJECT", retriesLeft: 2), .rejected(canRetry: true, onceMore: false))
        let retry = GuidedScreen.rejected(canRetry: true, onceMore: true).content(appName: "Acme")
        XCTAssertEqual(retry.primary, "Try again")
        XCTAssertEqual(retry.secondary, "Not now")
        XCTAssertEqual(retry.tips.count, 2)
        XCTAssertEqual(GuidedScreen.rejected(canRetry: false, onceMore: false).content(appName: "Acme").body,
                       "Please contact Acme for help.")
        XCTAssertEqual(GuidedScreen.review.content(appName: "the app").body,
                       "This can take a few minutes. The app will let you know.")
    }

    func testErrorPages() {
        func screen(_ code: UseSenseErrorCode, resume: Bool = false) -> GuidedScreen {
            GuidedScreen.forError(UseSenseError(code: code), canResume: resume)
        }
        XCTAssertEqual(screen(.cameraPermissionDenied), .cameraDenied)
        XCTAssertEqual(screen(.captureFailed), .cameraStopped)
        XCTAssertEqual(screen(.networkError), .offline)
        XCTAssertEqual(screen(.networkError, resume: true), .uploadFailed)
        XCTAssertEqual(screen(.uploadTimeout, resume: true), .uploadFailed)
        XCTAssertEqual(screen(.sessionExpired), .expired)
        XCTAssertEqual(screen(.serverError), .error)
        XCTAssertEqual(screen(.responseInvalid), .error)
    }

    func testNoEmDashesInAnyCopy() {
        let screens: [GuidedScreen] = [.primerTwoSteps(digits: false), .primerTwoSteps(digits: true), .approved, .review,
                                       .rejected(canRetry: true, onceMore: true), .rejected(canRetry: false, onceMore: false),
                                       .cameraDenied, .cameraStopped, .offline, .expired, .error, .micNeeded, .uploadFailed]
        for s in screens {
            let c = s.content(appName: "Acme")
            for text in [c.title, c.body, c.primary, c.secondary ?? ""] + c.tips {
                XCTAssertFalse(text.contains("\u{2014}"), text)
            }
        }
    }

    // MARK: Options

    func testResultOptionsDefaults() {
        let o = SDKOptions()
        XCTAssertTrue(o.showsResultScreen)
        XCTAssertEqual(o.retriesAfterReject, 0, "retry after a reject is off unless the app allows it")
        XCTAssertEqual(SDKOptions(retriesAfterReject: -3).retriesAfterReject, 0)
    }

    // MARK: Before-scan check

    func testBeforeScanCheckIsTheChallengeOrSpeakDigits() throws {
        let digits = UseSenseSession(config: UseSenseConfig(apiKey: "pk_sandbox_x"), sessionType: .authentication)
        digits.injectHostedSessionData(try sessionResponse(policy: Self.speakDigitsPolicy))
        if case .speakPhrase(let c) = digits.beforeScanCheck { XCTAssertEqual(c.phrase, "4 7 2 9") } else { XCTFail() }

        let passive = UseSenseSession(config: UseSenseConfig(apiKey: "pk_sandbox_x"), sessionType: .authentication)
        passive.injectHostedSessionData(try sessionResponse(policy: Self.passivePolicy))
        XCTAssertNil(passive.beforeScanCheck)
    }

    // MARK: Round 2 sheet

    func testAStepUpOpensTheOneMoreQuickCheckSheet() async throws {
        let session = UseSenseSession(config: UseSenseConfig(apiKey: "pk_sandbox_x"), sessionType: .authentication)
        session.injectHostedSessionData(try sessionResponse(policy: Self.passivePolicy))
        let spec = try decodeSpec(#"{"type":"follow_dot","seed":"r2","dot_size_px":24,"total_duration_ms":2000,"waypoints":[{"x":0.5,"y":0.3,"duration_ms":1000,"index":0},{"x":0.7,"y":0.4,"duration_ms":1000,"index":1}]}"#)
        let stepUp = try XCTUnwrap(StepUpInstruction(payload: StepUpPayload(round: 2, challenge: spec, maxFrames: 12)))
        await session.startServerStepUpRoundForTesting(stepUp)
        guard case .extraCheckIntro(let shown) = session.stateForTesting else {
            return XCTFail("expected the sheet, got \(session.stateForTesting.debugName)")
        }
        XCTAssertEqual(shown.seed, "r2")
        XCTAssertNil(session.watchdogPhaseForTesting, "no timeout while the person reads the sheet")
        session.cancel()
    }

    func testLegacyScreensKeepTheCountdown() async throws {
        var options = SDKOptions()
        options.guidedCaptureEnabled = false
        let session = UseSenseSession(config: UseSenseConfig(apiKey: "pk_sandbox_x", options: options), sessionType: .authentication)
        session.injectHostedSessionData(try sessionResponse(policy: Self.passivePolicy))
        let spec = try decodeSpec(#"{"type":"head_turn","seed":"r2","total_duration_ms":1000,"sequence":[{"direction":"left","duration_ms":1000,"index":0}]}"#)
        let stepUp = try XCTUnwrap(StepUpInstruction(payload: StepUpPayload(round: 2, challenge: spec, maxFrames: 12)))
        let task = Task { await session.startServerStepUpRoundForTesting(stepUp) }
        try await Task.sleep(nanoseconds: 300_000_000)
        if case .countdown = session.stateForTesting {} else { XCTFail("got \(session.stateForTesting.debugName)") }
        task.cancel()
        session.cancel()
    }

    // MARK: Microphone fallback

    func testFallbackPostsTheReasonAndSwapsInFollowDot() async throws {
        StubProtocol.reset(status: 200, body: """
        {"session_id":"sess_1","policy":{"requires_audio":false,"requires_stepup":true,"challenge_type":"follow_dot",
         "challenge":{"type":"follow_dot","seed":"fd","dot_size_px":24,"total_duration_ms":4000,
         "waypoints":[{"x":0.5,"y":0.3,"duration_ms":1000,"index":0}]},"audio_challenge":null}}
        """)
        UseSenseAPIClient.protocolClassesForTesting = [StubProtocol.self]
        defer { UseSenseAPIClient.protocolClassesForTesting = nil }

        let session = UseSenseSession(config: UseSenseConfig(apiEndpoint: "https://staging.api.usesense.ai/v1", apiKey: "pk_sandbox_x"),
                                      sessionType: .authentication)
        session.injectHostedSessionData(try sessionResponse(policy: Self.speakDigitsPolicy))
        let policy = try await session.applyMovementFallbackForTesting()

        XCTAssertEqual(policy.challengeType, "follow_dot")
        if case .followDot(let c) = session.beforeScanCheck { XCTAssertEqual(c.seed, "fd") } else { XCTFail() }
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/sessions/sess_1/challenge-fallback")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Session-Token"), "tok")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(StubProtocol.lastBody)) as? [String: String]
        XCTAssertEqual(body, ["reason": "microphone_unavailable"])
    }

    func testFallbackConflictsReadAsAPlainError() async throws {
        for code in ["capture_already_uploaded", "fallback_not_allowed"] {
            StubProtocol.reset(status: 409, body: #"{"error":{"code":"\#(code)","message":"no"}}"#)
            UseSenseAPIClient.protocolClassesForTesting = [StubProtocol.self]
            let session = UseSenseSession(config: UseSenseConfig(apiKey: "pk_sandbox_x"), sessionType: .authentication)
            session.injectHostedSessionData(try sessionResponse(policy: Self.speakDigitsPolicy))
            do {
                _ = try await session.applyMovementFallbackForTesting()
                XCTFail("expected an error")
            } catch let error as UseSenseError {
                XCTAssertEqual(error.code, .invalidRequest, code)
                XCTAssertEqual(error.details, code)
                XCTAssertEqual(GuidedScreen.forError(error, canResume: false), .error)
            }
            UseSenseAPIClient.protocolClassesForTesting = nil
        }
    }

    func testFallbackUnauthorizedStaysUnauthorized() {
        let e = UseSenseSession.fallbackError(UseSenseError.fromHTTP(statusCode: 401, serverCode: "unauthorized", serverMessage: nil))
        XCTAssertEqual(e.code, .unauthorized)
    }

    // MARK: Helpers

    private func decodeSpec(_ json: String) throws -> ChallengeSpecWrapper {
        try JSONDecoder().decode(ChallengeSpecWrapper.self, from: Data(json.utf8))
    }

    static let passivePolicy = #"{"requires_audio":false,"requires_stepup":false,"challenge_type":"none"}"#
    static let speakDigitsPolicy = #"{"requires_audio":true,"requires_stepup":false,"challenge_type":"speak_phrase","challenge":null,"audio_challenge":{"type":"speak_phrase","seed":"sd","phrase":"4 7 2 9","phrase_language":"numeric","total_duration_ms":8000}}"#

    private func sessionResponse(policy: String) throws -> CreateSessionResponse {
        let json = """
        {"session_id":"sess_1","session_token":"tok","expires_at":"2099-01-01T00:00:00.000Z","nonce":"n",
         "policy":\(policy),"upload":{"max_frames":30,"target_fps":3,"capture_duration_ms":8000}}
        """
        return try JSONDecoder().decode(CreateSessionResponse.self, from: Data(json.utf8))
    }
}

/// Answers every request with one canned response and remembers the last request.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
