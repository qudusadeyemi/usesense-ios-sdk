import XCTest
import SwiftUI
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
        // Centre (the reference), up-right, left, right: the server's shape.
        let pts: [(Float, Float)] = [(0.5, 0.5), (0.8, 0.25), (0.2, 0.6), (0.7, 0.55)]
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

    // MARK: Head Turn (follows the movement)

    /// Device yaw/pitch for a head turned toward `d` (sign measured on device).
    private func pose(_ d: HeadDirection, _ deg: Double = 25) -> (yaw: Double, pitch: Double) {
        switch d {
        case .left: return (deg * ChallengeRunner.leftYawSign, 0)
        case .right: return (-deg * ChallengeRunner.leftYawSign, 0)
        case .up: return (0, deg * ChallengeRunner.upPitchSign)
        case .down: return (0, -deg * ChallengeRunner.upPitchSign)
        case .center: return (0, 0)
        }
    }

    @discardableResult
    private func hold(_ r: inout ChallengeRunner, _ d: HeadDirection, _ seconds: TimeInterval, deg: Double = 25) -> ChallengeDisplay {
        let p = pose(d, deg)
        return run(&r, seconds, yaw: p.yaw, pitch: p.pitch)
    }

    func testEachStepWaitsForTheMovementThenMovesOn() {
        var r = headTurn()   // left, right, centre; 1 s each from the server
        var d = hold(&r, .center, 2)
        XCTAssertEqual(d.title, "Turn your head to the left", "it waits: looking straight doesn't count")
        XCTAssertEqual(d.subtitle, "Slowly")
        XCTAssertEqual(d.arrow, .left)
        XCTAssertEqual(r.specStepIndex, 0)
        XCTAssertEqual(d.progress, 0)
        d = hold(&r, .right, 0.75)
        XCTAssertEqual(r.specStepIndex, 0, "the wrong side doesn't count")
        d = hold(&r, .left, 0.3)
        XCTAssertEqual(r.specStepIndex, 0, "held at the side, not yet long enough")
        XCTAssertGreaterThan(d.progress, 0)
        d = hold(&r, .left, 0.45)
        XCTAssertEqual(d.title, "Now to the right")
        XCTAssertEqual(r.specStepIndex, 1)
        d = hold(&r, .right, 0.75)
        XCTAssertEqual(d.title, "Now look straight ahead")
        d = hold(&r, .right, 2)
        XCTAssertFalse(d.finished, "still turned: the centre step waits for the head to come back")
        d = hold(&r, .center, 0.75)
        XCTAssertTrue(d.finished)
        XCTAssertEqual(d.progress, 1)
        XCTAssertEqual(r.retriesLeft, 1, "no hint needed")
    }

    func testAShortTurnGetsOneHintThenTheServerDecides() {
        var r = headTurn([.left, .right, .center])
        var d = hold(&r, .left, ChallengeRunner.hintAfter + 0.1, deg: 8)
        XCTAssertEqual(d.title, "Let's try that again")
        XCTAssertEqual(d.subtitle, "Turn a little further to the left")
        XCTAssertEqual(d.arrow, .left)
        XCTAssertEqual(r.specStepIndex, 0, "the same step, more time")
        d = hold(&r, .left, ChallengeRunner.hintAfter + 0.1, deg: 8)
        XCTAssertEqual(r.specStepIndex, 1, "still short: it moves on and the server judges")
        XCTAssertEqual(d.title, "Let's try the next one", "and says so")
        d = hold(&r, .right, ChallengeRunner.hintAfter + 0.1, deg: 8)
        XCTAssertEqual(r.specStepIndex, 2, "the hint is once per challenge")
    }

    func testAHintedStepStillEndsWhenTheTurnArrives() {
        var r = headTurn([.left, .center])
        hold(&r, .left, ChallengeRunner.hintAfter + 0.1, deg: 8)
        let d = hold(&r, .left, 0.75)
        XCTAssertEqual(d.title, "Now look straight ahead")
    }

    func testUpAndDownUsePitch() {
        var r = headTurn([.up, .center])
        var d = hold(&r, .center, 0.3)
        XCTAssertEqual(d.title, "Look up")
        XCTAssertEqual(d.arrow, .up)
        d = hold(&r, .down, 0.75)
        XCTAssertEqual(r.specStepIndex, 0)
        d = hold(&r, .up, 0.75)
        XCTAssertEqual(d.title, "Now look straight ahead")
    }

    func testNoPoseReadingsFallBackToTheServersTime() {
        var r = headTurn([.left, .center])
        let d = run(&r, 1.05, yaw: nil, pitch: nil)
        XCTAssertEqual(d.title, "Now look straight ahead")
    }

    func testTheMeasuredSignsMatchTheDeviceRun() {
        // iPhone 17 Pro, 2026-11-10: left -42, right +33, up pitch +33.
        XCTAssertEqual(ChallengeRunner.atTarget(.left, yaw: -42, pitch: 0), true)
        XCTAssertEqual(ChallengeRunner.atTarget(.right, yaw: 33, pitch: 0), true)
        XCTAssertEqual(ChallengeRunner.atTarget(.left, yaw: 33, pitch: 0), false)
        XCTAssertEqual(ChallengeRunner.atTarget(.up, yaw: 0, pitch: 33), true)
        XCTAssertEqual(ChallengeRunner.atTarget(.center, yaw: -23.5, pitch: 15.9), false,
                       "the pose the server failed as centre in that run")
        XCTAssertNil(ChallengeRunner.atTarget(.left, yaw: nil, pitch: nil))
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
        hold(&r, .left, 0.75)
        var d = run(&r, 1.5, face: false)
        XCTAssertEqual(d.tone, .warning)
        XCTAssertEqual(d.title, "Move your face to the centre")
        XCTAssertEqual(d.subtitle, "Then keep turning to the right", "the paused detail names the step's side")
        XCTAssertNil(d.arrow)
        d = hold(&r, .right, 0.3)
        XCTAssertEqual(d.tone, .active)
        XCTAssertEqual(d.title, "Now to the right")
    }

    func testAOneFrameDropDoesNotPause() {
        var r = headTurn()
        hold(&r, .center, 0.5)
        let d = run(&r, 0.1, face: false)
        XCTAssertEqual(d.tone, .active)
    }

    func testNeverFailsOnTheDeviceWhileTheFaceIsAway() {
        var r = headTurn()
        hold(&r, .center, 0.5)
        let d = run(&r, 120, face: false)
        XCTAssertFalse(d.finished)
        XCTAssertEqual(d.tone, .warning)
    }

    func testTheLeaveDialogHoldsTheTimeline() {
        var r = headTurn()
        hold(&r, .center, 0.5)
        let d = run(&r, 30, yaw: 0, pitch: 0, held: true)
        XCTAssertEqual(r.specStepIndex, 0)
        XCTAssertNotEqual(d.title, "Let's try that again", "no time passes while the dialog is open")
    }

    // MARK: Follow Dot (the dot waits for the head)

    /// Device yaw/pitch for a head pointing right/up by these degrees.
    @discardableResult
    private func point(_ r: inout ChallengeRunner, right: Double, up: Double, _ seconds: TimeInterval) -> ChallengeDisplay {
        run(&r, seconds, yaw: right * -ChallengeRunner.leftYawSign, pitch: up * ChallengeRunner.upPitchSign)
    }

    func testTheDotWaitsUntilTheHeadMovesTheWayTheDotMoved() {
        var r = followDot()   // centre, up-right, left-down, right
        var d = point(&r, right: 0, up: 0, 1.2)          // first waypoint: straight face
        XCTAssertEqual(r.specStepIndex, 1)
        d = point(&r, right: 0, up: 0, 3)                // dot went up-right, head didn't move
        XCTAssertEqual(r.specStepIndex, 1, "the dot waits")
        XCTAssertEqual(d.title, "Follow the dot with your head")
        XCTAssertEqual(d.dot!.x, 0.8, accuracy: 0.01, "glided there and stays")
        d = point(&r, right: 0, up: 15, 1.2)             // up only: the dot moved more right than up
        XCTAssertEqual(r.specStepIndex, 1, "the main direction (right) is missing")
        d = point(&r, right: 20, up: 15, 1.2)            // up-right: reached
        XCTAssertEqual(r.specStepIndex, 2)
        XCTAssertEqual(d.trail.count, 3, "waypoints passed plus the dot")
        d = point(&r, right: 20, up: 15, 2)              // dot went left-down, head stays: waits
        XCTAssertEqual(r.specStepIndex, 2, "staying put never counts as following")
        d = point(&r, right: -5, up: 0, 1.2)             // moved left and down from (20, 15)
        XCTAssertEqual(r.specStepIndex, 3)
        XCTAssertEqual(d.title, "Keep following")
        d = point(&r, right: 10, up: 0, 1.2)             // right by 15 from -5
        XCTAssertTrue(d.finished)
        XCTAssertEqual(r.stepLog.map(\.reached), [true, true, true, true])
    }

    func testTheDeviceRunCaseAHeadAlreadyRaisedDoesNotReachTheNextRaisedDot() {
        // Device run: dot 1 at (0.76, 0.30), dot 2 at (0.39, 0.31). With the head
        // still up and right from dot 1, dot 2 (moved left) must not count.
        let ry = 15 * -ChallengeRunner.leftYawSign, rp = 12 * ChallengeRunner.upPitchSign
        XCTAssertEqual(ChallengeRunner.atDotTarget(CGPoint(x: 0.39, y: 0.31), from: CGPoint(x: 0.76, y: 0.30),
                                                   yaw: ry, pitch: rp, refYaw: ry, refPitch: rp), false)
        XCTAssertEqual(ChallengeRunner.atDotTarget(CGPoint(x: 0.39, y: 0.31), from: CGPoint(x: 0.76, y: 0.30),
                                                   yaw: 0, pitch: rp, refYaw: ry, refPitch: rp), true,
                       "a 15 degree move left; the dot's 0.01 drop asks for no pitch")
        XCTAssertNil(ChallengeRunner.atDotTarget(.zero, from: .zero, yaw: nil, pitch: nil, refYaw: 0, refPitch: 0))
    }

    func testDiagonalDotsAreJudgedOnTheirMainDirection() {
        let r = -ChallengeRunner.leftYawSign, u = ChallengeRunner.upPitchSign
        func reach(_ to: CGPoint, from: CGPoint, right: Double, up: Double) -> Bool? {
            ChallengeRunner.atDotTarget(to, from: from, yaw: right * r, pitch: up * u, refYaw: 0, refPitch: 0)
        }
        // Run 10, spot 2: dot right 0.36 and up 0.2; head right 35, dipped 7.3.
        XCTAssertEqual(reach(CGPoint(x: 0.86, y: 0.3), from: CGPoint(x: 0.5, y: 0.5), right: 35.7, up: -7.3), true)
        // Run 10, spot 3: dot left and down; head left 20, tilted up 4.3.
        XCTAssertEqual(reach(CGPoint(x: 0.3, y: 0.65), from: CGPoint(x: 0.8, y: 0.4), right: -20.2, up: 4.3), true)
        // The main direction is required.
        XCTAssertEqual(reach(CGPoint(x: 0.86, y: 0.3), from: CGPoint(x: 0.5, y: 0.5), right: 4, up: 15), false)
        // The other direction clearly the wrong way fails.
        XCTAssertEqual(reach(CGPoint(x: 0.86, y: 0.3), from: CGPoint(x: 0.5, y: 0.5), right: 30, up: -14), false)
        // A mostly vertical move is judged on pitch.
        XCTAssertEqual(reach(CGPoint(x: 0.55, y: 0.85), from: CGPoint(x: 0.45, y: 0.3), right: 0, up: -12), true)
        XCTAssertEqual(reach(CGPoint(x: 0.55, y: 0.85), from: CGPoint(x: 0.45, y: 0.3), right: 15, up: 0), false)
    }

    func testTheDotGetsOneHintThenMovesOnForTheServer() {
        var r = followDot()
        point(&r, right: 0, up: 0, 1.2)
        var d = point(&r, right: 0, up: 0, ChallengeRunner.hintAfter + 0.1)
        XCTAssertEqual(d.title, "Let's try that again")
        XCTAssertEqual(d.subtitle, "Turn your head toward the dot")
        XCTAssertEqual(d.dot!.x, 0.8, accuracy: 0.01, "the dot doesn't replay its glide")
        d = point(&r, right: 0, up: 0, ChallengeRunner.hintAfter + 0.1)
        XCTAssertEqual(r.specStepIndex, 2)
        XCTAssertEqual(r.stepLog.count, 2)
        XCTAssertEqual(r.stepLog.last?.reached, false)
    }

    func testAMissedStepNeverLooksConfirmed() {
        var r = followDot()
        point(&r, right: 0, up: 0, 1.2)                                   // first: reached
        let one = r.progress
        point(&r, right: 0, up: 0, ChallengeRunner.hintAfter * 2 + 0.3)   // hint, then times out
        XCTAssertEqual(r.specStepIndex, 2)
        XCTAssertEqual(r.stepLog.last?.reached, false)
        let d = r.display()
        XCTAssertEqual(d.title, "Let's try the next one")
        XCTAssertEqual(d.tone, .warning)
        XCTAssertEqual(r.progress, one, accuracy: 0.001, "the missed spot's segment stays empty")
        let later = point(&r, right: 0, up: 0, ChallengeRunner.missedNotice + 0.1)
        XCTAssertEqual(later.title, "Keep following", "the notice is brief")
    }

    func testAMissedHeadTurnStepSaysSoToo() {
        var r = headTurn([.left, .right, .center])
        hold(&r, .left, ChallengeRunner.hintAfter * 2 + 0.3, deg: 5)
        let d = r.display()
        XCTAssertEqual(d.title, "Let's try the next one")
        XCTAssertEqual(r.progress, 0, accuracy: 0.001)
    }

    func testFollowDotSaysThePreviewIsMirrored() throws {
        let spec = try JSONDecoder().decode(ChallengeSpecWrapper.self, from: Data(#"{"type":"follow_dot","seed":"s","dot_size_px":24,"total_duration_ms":1000,"waypoints":[{"x":0.5,"y":0.5,"duration_ms":1000,"index":0}]}"#.utf8))
        XCTAssertEqual(ChallengeResponseBuilder().build(challenge: spec)["preview_mirrored"] as? Bool, true)
    }

    func testTheDotWaitsWhileTheFaceIsAway() {
        var r = followDot()
        point(&r, right: 0, up: 0, 1.2)
        point(&r, right: 0, up: 0, 1.0)
        let paused = run(&r, 0.4, face: false)
        let lost = run(&r, 3, face: false)
        XCTAssertEqual(lost.title, "Show your face in the oval")
        XCTAssertEqual(lost.subtitle, "The dot will wait for you")
        XCTAssertEqual(lost.tone, .warning)
        XCTAssertEqual(lost.dot!.x, paused.dot!.x, accuracy: 0.001)
        XCTAssertEqual(r.specStepIndex, 1)
    }

    func testEveryDotSpotSendsFramesEvenWhenThePhoneThinksItWasMissed() {
        var r = followDot()
        point(&r, right: 0, up: 0, 1.2)                  // first spot done
        point(&r, right: 0, up: 0, 0.3)                  // dot still gliding to spot 2
        XCTAssertEqual(r.bankReason, .none, "the dot hasn't arrived and settled")
        point(&r, right: 0, up: 0, 0.7)                  // arrived + settled, head not on it
        XCTAssertEqual(r.bankReason, .settled, "a couple of frames go up for the server anyway")
        point(&r, right: 20, up: 15, 0.2)                // head on the dot
        XCTAssertEqual(r.bankReason, .onTarget)
        XCTAssertEqual(UseSenseSession.settledFramesPerStep, 2)
    }

    func testHeadTurnStillBanksOnlyOnTheTarget() {
        var r = headTurn([.left, .center])
        hold(&r, .center, 3)
        XCTAssertEqual(r.bankReason, .none, "big, unambiguous poses: the phone's verdict is reliable")
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

    // MARK: Inline step-up on the guided screen

    func testRMASShowsEachActionAsItsWindowOpensAndReadsTheLivePose() async {
        let actions = RMASChallenge.actionPool.filter { ["turn_left", "turn_right", "blink"].contains($0.type) }
            .sorted { $0.type < $1.type }   // blink, turn_left, turn_right
        let shown = Locked<[String]>([])
        let result = await RMASChallenge().run(
            actions: actions,
            getCurrentPose: {
                switch shown.value.last {
                case "turn_left": return HeadPose(yaw: -20, pitch: 0, roll: 0)
                case "turn_right": return HeadPose(yaw: 20, pitch: 0, roll: 0)
                default: return HeadPose(yaw: 0, pitch: 0, roll: 0)
                }
            },
            getCurrentEAR: { shown.value.last == "blink" ? (left: 0.1, right: 0.1) : (left: 0.3, right: 0.3) },
            onAction: { _, action in shown.mutate { $0.append(action.type) } })
        XCTAssertEqual(shown.value, ["blink", "turn_left", "turn_right"])
        XCTAssertEqual(result.actionsCompleted, 3)
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.actions.map(\.label), ["Blink twice", "Turn head left", "Turn head right"],
                       "the upload keeps RMAS's own labels")
    }

    func testFlashReflectionPutsEachColourOnScreenAndSeesItReflected() async {
        let current = Locked<String?>(nil)
        let calls = Locked<[String]>([])
        let result = await FlashReflectionChallenge().run(
            captureFrame: { Self.solid(current.value) },
            onFlash: { i, hex in current.mutate { $0 = hex }; calls.mutate { $0.append("\(i):\(hex ?? "-")") } })
        XCTAssertEqual(calls.value.count, 7, "off/on for three flashes, then off")
        XCTAssertEqual(calls.value.last?.hasSuffix(":-"), true, "the screen ends clear")
        XCTAssertTrue(result.passed)
        XCTAssertGreaterThan(result.overallColorDelta, 3, "no longer the hard-reject floor")
    }

    func testInlinePromptCopyAndRing() {
        let blink = InlineStepUpDisplay(.action(type: "blink", step: 0, steps: 3))
        XCTAssertEqual(blink.title, "Blink twice")
        XCTAssertEqual(blink.progress, 1.0 / 3, accuracy: 1e-9, "the ring shows amber from the first step")
        XCTAssertNil(blink.flashColor)
        XCTAssertEqual(InlineStepUpDisplay(.action(type: "turn_left", step: 2, steps: 3)).title, "Turn your head to the left")
        let flash = InlineStepUpDisplay(.flash(color: "#FF0000", step: 3, steps: 6))
        XCTAssertEqual(flash.title, "Hold still")
        XCTAssertEqual(flash.subtitle, "Your screen will change colour")
        XCTAssertEqual(flash.flashColor, "#FF0000")
        XCTAssertEqual(flash.progress, 4.0 / 6, accuracy: 1e-9)
    }

    func testGuidedSessionRunsTheInlineStepUpAndPublishesItsPrompts() async throws {
        let session = UseSenseSession(config: UseSenseConfig(apiKey: "pk_sandbox_x"), sessionType: .authentication)
        session.injectHostedSessionData(try sessionResponse(policy: Self.inlinePolicy(enabled: true)))
        let prompts = Locked<[InlineStepUpDisplay]>([])
        session.onInlineStepUpUpdate = { d in prompts.mutate { $0.append(d) } }
        let result = await session.runInlineStepUpForTesting(engine: SuspicionEngine(config: nil))
        let r = try XCTUnwrap(result, "runs when the policy enables it")
        XCTAssertEqual(r.challengesRun, ["rmas"])
        XCTAssertEqual(r.rmas?.actionsTotal, 3)
        XCTAssertEqual(prompts.value.first, .preparing)
        XCTAssertEqual(prompts.value.dropFirst().count, 3, "each micro-action is shown")
        if case .inlineStepUp = session.stateForTesting {} else { XCTFail(session.stateForTesting.debugName) }
    }

    func testInlineStepUpStaysOffWhenThePolicyDisablesIt() async throws {
        let session = UseSenseSession(config: UseSenseConfig(apiKey: "pk_sandbox_x"), sessionType: .authentication)
        session.injectHostedSessionData(try sessionResponse(policy: Self.inlinePolicy(enabled: false)))
        let result = await session.runInlineStepUpForTesting(engine: SuspicionEngine(config: nil))
        XCTAssertNil(result)
    }

    static func inlinePolicy(enabled: Bool) -> String {
        #"{"requires_audio":false,"requires_stepup":false,"challenge_type":"none","inline_step_up":{"enabled":\#(enabled),"suspicion_threshold":55,"preferred_challenge":"rmas"}}"#
    }

    /// A frame that reflects `hex` strongly (grey when nil).
    static func solid(_ hex: String?) -> UIImage {
        var rgb: (CGFloat, CGFloat, CGFloat) = (0.5, 0.5, 0.5)
        if let hex, let c = FlowAppearance.parseHexComponents(hex) {
            rgb = (0.3 + 0.4 * c.r, 0.3 + 0.4 * c.g, 0.3 + 0.4 * c.b)
        }
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }

    // MARK: The quality gate during a challenge

    /// A face that passes every scan check.
    private func goodFace(_ t: TimeInterval, yaw: Double = 0, pitch: Double = 0, eye: Double = 0.24,
                          cover: FaceCover? = nil, anchors: [CGPoint]? = nil) -> GateObservation {
        GateObservation(time: t, faceCount: 1, ovalExtent: 0.9, faceCentreOffset: .zero, eyeDistance: eye,
                        yaw: yaw, pitch: pitch, roll: 0,
                        face: FaceRegionQuality(meanLuma: 120, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 400),
                        eyeBlinkLeft: 0.1, eyeBlinkRight: 0.1,
                        anchors: anchors ?? [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.5, y: 0.3)],
                        cover: cover)
    }

    private func settle(_ gate: inout QualityGate, rules: ChallengeGateRules?, yaw: Double = 0,
                        make: ((TimeInterval) -> GateObservation)? = nil) -> QualityGate.Evaluation {
        var e = QualityGate.Evaluation()
        for i in 0..<12 {
            let t = Double(i) * 0.05
            e = gate.evaluate(make?(t) ?? goodFace(t, yaw: yaw), scanning: true, challenge: rules)
        }
        return e
    }

    func testOnlyPoseRelaxesAndOnlyTowardTheStepsMovement() {
        var scan = QualityGate()
        XCTAssertNotNil(settle(&scan, rules: nil, yaw: 30).blocking[.pose], "the scan wants a straight face")
        var turn = QualityGate()
        XCTAssertTrue(settle(&turn, rules: .turnSideways, yaw: 30).blocking.isEmpty, "a sideways step allows the turn")
        var tooFar = QualityGate()
        XCTAssertNotNil(settle(&tooFar, rules: .turnSideways, yaw: 60).blocking[.pose])
        var upDown = QualityGate()
        XCTAssertNotNil(settle(&upDown, rules: .turnUpDown, yaw: 40).blocking[.pose], "an up/down step doesn't open yaw")
    }

    func testEveryOtherScanCheckStillHoldsAChallenge() {
        let rules = ChallengeGateRules.turnSideways
        var g = QualityGate()
        XCTAssertEqual(settle(&g, rules: rules) { self.goodFace($0, cover: FaceCover(bodySkin: 0.5, other: 0.4)) }.blocking[.covered], .uncovered)
        g = QualityGate()
        XCTAssertEqual(settle(&g, rules: rules) { self.goodFace($0, eye: 0.10) }.blocking[.distance], .moveCloser)
        g = QualityGate()
        XCTAssertNil(settle(&g, rules: rules) { self.goodFace($0, eye: 0.33) }.blocking[.distance],
                     "the scan's hold margin applies")
        g = QualityGate()
        XCTAssertNotNil(settle(&g, rules: rules) { t in var o = self.goodFace(t); o.faceCount = 2; return o }.blocking[.onePerson])
        g = QualityGate()
        XCTAssertNotNil(settle(&g, rules: rules) { t in var o = self.goodFace(t); o.eyeBlinkLeft = 0.9; o.eyeBlinkRight = 0.9; return o }.blocking[.eyesOpen])
        g = QualityGate()
        // Sharpness gives way while the head moves (a turning head blurs in
        // the dark, Android A03 run); Speak Digits keeps it.
        XCTAssertNil(settle(&g, rules: rules) { t in
            var o = self.goodFace(t); o.face = FaceRegionQuality(meanLuma: 120, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 10); return o
        }.blocking[.sharpness])
        g = QualityGate()
        XCTAssertNotNil(settle(&g, rules: .digits) { t in
            var o = self.goodFace(t); o.face = FaceRegionQuality(meanLuma: 120, clippedHighRatio: 0, clippedLowRatio: 0, sharpness: 10); return o
        }.blocking[.sharpness])
        g = QualityGate()
        XCTAssertNotNil(settle(&g, rules: rules) { t in var o = self.goodFace(t); o.ovalExtent = 1.6; o.faceCentreOffset = CGPoint(x: 0.5, y: 0); return o }.blocking[.inFrame])
        g = QualityGate()
        XCTAssertEqual(settle(&g, rules: rules) { _ in GateObservation.noFace(at: 0) }.blocking[.faceFound], .showFace)
    }

    func testStillnessOnlyWhereTheStepDoesNotAskForMovement() {
        let shaking: (TimeInterval) -> GateObservation = { t in
            let dx = CGFloat(Int(t * 20) % 2) * 0.05
            return self.goodFace(t, anchors: [CGPoint(x: 0.5 + dx, y: 0.5), CGPoint(x: 0.4 + dx, y: 0.4),
                                              CGPoint(x: 0.6 + dx, y: 0.4), CGPoint(x: 0.5 + dx, y: 0.3)])
        }
        var turn = QualityGate()
        XCTAssertNil(settle(&turn, rules: .followDot, make: shaking).blocking[.stillness])
        var digits = QualityGate()
        XCTAssertEqual(settle(&digits, rules: .digits, make: shaking).blocking[.stillness], .holdStill)
    }

    func testGuideNamesTheFailingCheckDuringAChallenge() {
        var guide = CaptureGuide()
        var snap = GuideSnapshot.initial
        for i in 0..<20 {
            snap = guide.update(goodFace(Double(i) * 0.05, cover: FaceCover(bodySkin: 0.5, other: 0.4)), challenge: .turnSideways)
        }
        XCTAssertFalse(snap.allPass)
        XCTAssertEqual(snap.hint, .uncovered)
    }

    func testTheRunnerFollowsTheStepsGateRules() {
        var r = headTurn([.left, .up, .center])
        XCTAssertEqual(r.gateRules, .turnSideways)
        hold(&r, .left, 0.75)
        XCTAssertEqual(r.gateRules, .turnUpDown)
        hold(&r, .up, 0.75)
        XCTAssertEqual(r.gateRules, .returning)
        XCTAssertEqual(followDot().gateRules, .followDot)
        XCTAssertEqual(ChallengeRunner(plan: .digits(phrase: "1 2", durationMs: 3000)).gateRules, .digits)
    }

    func testAPausedChallengeNamesWhatTheGateSaw() {
        var r = headTurn()
        hold(&r, .center, 0.5)
        var d = r.display()
        for _ in 0..<10 {
            clock += 0.05
            d = r.advance(ChallengeObservation(time: clock, facePresent: false, yaw: 20, pitch: 0, hint: .uncovered))
        }
        XCTAssertEqual(d.tone, .warning)
        XCTAssertEqual(d.title, "Keep your face uncovered")
        XCTAssertEqual(d.subtitle, "Then keep turning to the left")
    }

    // MARK: Round 2 upload signals

    func testRoundTwoCarriesTheSameSignalBlocksAsRoundOne() async throws {
        let session = UseSenseSession(config: UseSenseConfig(apiKey: "pk_sandbox_x"), sessionType: .authentication)
        session.injectHostedSessionData(try sessionResponse(policy: Self.passivePolicy))
        let spec = try decodeSpec(#"{"type":"head_turn","seed":"r2","total_duration_ms":1000,"sequence":[{"direction":"left","duration_ms":1000,"index":0}]}"#)
        let stepUp = try XCTUnwrap(StepUpInstruction(payload: StepUpPayload(round: 2, challenge: spec, maxFrames: 12)))
        let frame = Self.solid(nil).jpegData(compressionQuality: 0.5)!
        let m1 = await session.captureMetadataForTesting(frames: [frame], round2: nil)
        let m2 = await session.captureMetadataForTesting(frames: [frame], round2: stepUp)
        let r1 = try XCTUnwrap(m1)
        let r2 = try XCTUnwrap(m2)
        for key in ["channel_integrity", "device_telemetry", "suspicion", "frame_hashes", "frames_manifest", "timestamps"] {
            XCTAssertNotNil(r1[key], "round 1 \(key)")
            XCTAssertNotNil(r2[key], "round 2 \(key)")
        }
        XCTAssertEqual(r2["step_up_round"] as? Int, 2)
        XCTAssertEqual(r2["capture_channel"] as? String, "ios")
        XCTAssertEqual((r2["challenge_response"] as? [String: Any])?["seed"] as? String, "r2")
        XCTAssertNotNil((r2["channel_integrity"] as? [String: Any])?["screen_detection"])
        XCTAssertNil(r2["covered_check"], "round-1 only")
        XCTAssertNil(r2["inline_step_up"], "round-1 only")
        XCTAssertNil(r1["step_up_round"])
    }

    // MARK: Shutter copy (device finding)

    func testTheShutterNeverHidesACheckThatHoldsTheScan() {
        typealias V = GuidedCaptureView<EmptyView>
        XCTAssertEqual(V.guidance(hint: .uncovered, mode: .align, paused: false, showShutter: true).title,
                       "Keep your face uncovered")
        XCTAssertEqual(V.guidance(hint: .onePerson, mode: .align, paused: false, showShutter: true).title,
                       "Only you in the picture")
        XCTAssertEqual(V.guidance(hint: .holdStill, mode: .align, paused: false, showShutter: true).title,
                       "Tap the button when you're ready")
        XCTAssertEqual(V.guidance(hint: .faceALight, mode: .align, paused: false, showShutter: true).title,
                       "Tap the button when you're ready", "light is advice only")
        XCTAssertEqual(V.guidance(hint: nil, mode: .align, paused: false, showShutter: true).title,
                       "Tap the button when you're ready")
    }

    // MARK: Step timing for the server (replay defence)

    func testEachStepLogsWhenItWasPromptedAndReached() {
        var r = headTurn([.left, .right, .center])
        hold(&r, .center, 0.7)             // prompted, not yet turning
        hold(&r, .left, 0.75)               // reached ~0.7 s after the prompt
        hold(&r, .right, ChallengeRunner.hintAfter + 0.1, deg: 8)   // short: hint
        hold(&r, .right, 0.75)              // then reached
        hold(&r, .center, 0.75)
        let log = r.stepLog
        XCTAssertEqual(log.map(\.index), [0, 1, 2])
        XCTAssertEqual(log.map(\.reached), [true, true, true])
        XCTAssertEqual(log.map(\.hinted), [false, true, false])
        let reaction = log[0].reachedAt! - log[0].promptedAt
        XCTAssertEqual(reaction, 0.75, accuracy: 0.11)
        XCTAssertLessThan(log[0].endedAt, log[1].promptedAt + 0.06, "the next step is prompted as one ends")

        let builder = ChallengeResponseBuilder()
        builder.setStepEvents(log, start: Date(timeIntervalSince1970: 1000))
        let spec = ChallengeSpecWrapper.headTurn(HeadTurnChallenge(type: "head_turn", seed: "s", sequence: [],
                                                                    totalDurationMs: 0, framesPerStep: nil, captureFpsHint: nil))
        let events = builder.build(challenge: spec)["step_events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 3)
        XCTAssertEqual(events?.first?["outcome"] as? String, "reached")
        XCTAssertEqual(events?[1]["hinted"] as? Bool, true)
        XCTAssertNotNil(events?.first?["reaction_ms"] as? Int)
    }

    func testAStepThatNeverArrivesIsLoggedAsTimedOut() {
        var r = headTurn([.left, .center])
        hold(&r, .left, ChallengeRunner.hintAfter * 2 + 0.3, deg: 5)
        XCTAssertEqual(r.stepLog.first?.reached, false)
        XCTAssertNil(r.stepLog.first?.reachedAt)
    }

    // MARK: First move (step_events v2)

    private func events(_ log: [ChallengeStepLog]) -> [[String: Any]] {
        let builder = ChallengeResponseBuilder()
        builder.setStepEvents(log, start: Date(timeIntervalSince1970: 1000))
        let spec = ChallengeSpecWrapper.headTurn(HeadTurnChallenge(type: "head_turn", seed: "s", sequence: [],
                                                                    totalDurationMs: 0, framesPerStep: nil, captureFpsHint: nil))
        return builder.build(challenge: spec)["step_events"] as? [[String: Any]] ?? []
    }

    func testAHeadThatTurnsTheRightWayFirstMovesTowardTheTarget() {
        var r = headTurn([.left, .center])
        hold(&r, .center, 0.5)              // prompted, still
        hold(&r, .left, 0.2, deg: 3)        // under 4 degrees: not a move yet
        hold(&r, .left, 0.2, deg: 6)        // the first move, toward the left
        hold(&r, .left, 0.75)               // reached
        hold(&r, .center, 0.75)             // back to the centre
        let log = r.stepLog
        XCTAssertEqual(log.map(\.reached), [true, true])
        XCTAssertEqual(log[0].firstMoveDeg ?? .nan, 6, accuracy: 0.01)
        XCTAssertEqual(Double(log[0].firstMoveMs ?? -1), 700, accuracy: 60)
        XCTAssertEqual(log[0].maxAwayDeg, 0)
        XCTAssertEqual(log[1].firstMoveDeg ?? .nan, 25, accuracy: 0.01, "centre: the distance from straight ahead shrinks")
        XCTAssertEqual(log[1].maxAwayDeg, 0)

        let e = events(log)
        XCTAssertEqual(e[0]["first_move_deg"] as? Double, 6)
        XCTAssertNotNil(e[0]["first_move_ms"] as? Int)
        XCTAssertEqual(e[0]["max_away_deg"] as? Double, 0)
    }

    func testAHeadThatMovesAwayFirstIsLoggedNegative() {
        var r = headTurn([.left, .center])
        hold(&r, .center, 0.3)
        hold(&r, .right, 0.2, deg: 8)       // the wrong way first
        hold(&r, .right, 0.2, deg: 12)      // and further
        hold(&r, .left, 0.75)               // then the asked side
        hold(&r, .right, 0.2, deg: 30)      // after reaching: no longer the way there
        hold(&r, .center, 0.75)
        let log = r.stepLog
        XCTAssertEqual(log[0].reached, true)
        XCTAssertEqual(log[0].firstMoveDeg ?? .nan, -8, accuracy: 0.01)
        XCTAssertEqual(Double(log[0].firstMoveMs ?? -1), 300, accuracy: 60)
        XCTAssertEqual(log[0].maxAwayDeg ?? .nan, 12, accuracy: 0.01)

        let e = events(log)
        XCTAssertEqual(e[0]["first_move_deg"] as? Double, -8)
        XCTAssertEqual(e[0]["max_away_deg"] as? Double, 12)
    }

    func testAStillHeadHasNoFirstMove() {
        var r = headTurn([.left, .center])
        hold(&r, .center, ChallengeRunner.hintAfter * 2 + 0.3)
        XCTAssertNil(r.stepLog.first?.firstMoveDeg)
        XCTAssertNil(r.stepLog.first?.firstMoveMs)
        XCTAssertEqual(r.stepLog.first?.maxAwayDeg, 0)
        XCTAssertNil(events(r.stepLog).first?["first_move_deg"])
    }

    func testFollowDotFirstMoveIsMeasuredFromThePreviousWaypoint() {
        var r = followDot()   // centre, up-right, left-down, right
        point(&r, right: 0, up: 0, 1.2)       // waypoint 0: the reference
        point(&r, right: -8, up: 0, 0.3)      // the dot went right: head left first
        point(&r, right: 20, up: 15, 1.2)     // then follows
        point(&r, right: -5, up: 0, 1.2)      // left-down from (20, 15): the right way
        point(&r, right: 10, up: 0, 1.2)
        let log = r.stepLog
        XCTAssertEqual(log.map(\.reached), [true, true, true, true])
        XCTAssertNil(log[0].firstMoveDeg, "waypoint 0 has nothing to move toward")
        XCTAssertNil(log[0].maxAwayDeg)
        XCTAssertEqual(log[1].firstMoveDeg ?? .nan, -8, accuracy: 0.01)
        XCTAssertEqual(log[1].maxAwayDeg ?? .nan, 8, accuracy: 0.01)
        XCTAssertEqual(log[2].firstMoveDeg ?? .nan, 25, accuracy: 0.01, "moved with the dot (left)")
        XCTAssertEqual(log[2].maxAwayDeg, 0)
        XCTAssertNil(events(log)[0]["max_away_deg"])
    }

    // MARK: Which frames count for a step (device finding)

    func testHeadTurnBanksOnlyWhileTheAskedPoseIsHeld() {
        var r = headTurn([.left, .center])
        hold(&r, .center, 0.5)
        XCTAssertFalse(r.banksNow, "not turned yet: these frames would show the wrong pose")
        hold(&r, .right, 0.3)
        XCTAssertFalse(r.banksNow)
        hold(&r, .left, 0.2)
        XCTAssertTrue(r.banksNow, "holding the asked side")
        var noPose = headTurn([.left])
        run(&noPose, 0.2, yaw: nil, pitch: nil)
        XCTAssertTrue(noPose.banksNow, "no pose to judge: bank as before")
        XCTAssertTrue(followDot().banksNow)
    }

    func testScanFramesAreNoStepsEvidence() {
        let b = ChallengeResponseBuilder()
        b.setCurrentStep(-1)
        b.recordFrame(frameIndex: 0, timestampMs: 1)
        b.recordFrame(frameIndex: 1, timestampMs: 2)
        b.setCurrentStep(0)
        b.recordFrame(frameIndex: 2, timestampMs: 3)
        let spec = ChallengeSpecWrapper.headTurn(HeadTurnChallenge(type: "head_turn", seed: "s", sequence: [],
                                                                    totalDurationMs: 0, framesPerStep: nil, captureFpsHint: nil))
        let json = b.build(challenge: spec)
        XCTAssertEqual(json["step_frames"] as? [String: [Int]], ["0": [2]])
        XCTAssertEqual((json["frame_timestamps"] as? [Int64])?.count, 3, "timestamps stay aligned with the frames")
    }

    // MARK: Frame budget per step (device finding)

    func testEveryStepKeepsAShareOfTheFrames() {
        // The device run: 30 frames, 4 banked by the scan, 4 steps.
        var remaining = 26
        var perStep: [Int] = []
        for stepsLeft in stride(from: 4, through: 1, by: -1) {
            let q = UseSenseSession.stepFrameQuota(remaining: remaining, stepsLeft: stepsLeft)
            perStep.append(q)
            remaining -= q
        }
        XCTAssertEqual(perStep, [6, 6, 7, 7])
        XCTAssertTrue(perStep.allSatisfy { $0 >= 2 }, "every step, the last one included, gets frames")
        XCTAssertEqual(UseSenseSession.stepFrameQuota(remaining: 3, stepsLeft: 4), 2)
        XCTAssertEqual(UseSenseSession.stepFrameQuota(remaining: 0, stepsLeft: 2), 0)
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

/// A value shared with escaping callbacks in tests.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
