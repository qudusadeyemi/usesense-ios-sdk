import XCTest
@testable import UseSenseSDK

/// Server step-up (round 2): the /signals response can ask for one more
/// challenge in the same session. Contract: usesense-watchtower
/// docs/sdk/step-up-protocol.md.
final class ServerStepUpTests: XCTestCase {

    private let headTurnJSON = """
    {"type":"head_turn","seed":"abc123","total_duration_ms":3000,"frames_per_step":2,
     "sequence":[{"direction":"left","duration_ms":1500,"index":0},{"direction":"right","duration_ms":1500,"index":1}]}
    """

    private func decode(_ json: String) throws -> UploadSignalsResponse {
        try JSONDecoder().decode(UploadSignalsResponse.self, from: Data(json.utf8))
    }

    func testRoundOneResponseWithStepUpDecodesTheInstruction() throws {
        let response = try decode("""
        {"received":true,"session_id":"s","frames_count":30,"audio_received":false,"metadata_received":true,
         "step_up":{"round":2,"challenge":\(headTurnJSON),"upload":{"max_frames":18}}}
        """)
        let instruction = StepUpInstruction(payload: response.stepUp)
        XCTAssertEqual(instruction?.challenge.challengeType, .headTurn)
        XCTAssertEqual(instruction?.challenge.seed, "abc123")
        XCTAssertEqual(instruction?.maxFrames, 18)
    }

    func testNoStepUpMeansNoInstruction() throws {
        let response = try decode(#"{"received":true,"session_id":"s","frames_count":30,"audio_received":false,"metadata_received":true}"#)
        XCTAssertNil(response.stepUp)
        XCTAssertNil(StepUpInstruction(payload: response.stepUp))
    }

    func testRoundTwoResponseWithoutAudioReceivedStillDecodes() throws {
        // The server's round-2 response has no audio_received; it used to be required.
        let response = try decode(#"{"received":true,"session_id":"s","round":2,"frames_count":12,"metadata_received":true,"total_size_bytes":1}"#)
        XCTAssertEqual(response.framesCount, 12)
        XCTAssertFalse(response.audioReceived)
    }

    func testAnUnknownChallengeTypeDoesNotFailTheUpload() throws {
        let response = try decode("""
        {"received":true,"session_id":"s","frames_count":30,"audio_received":false,"metadata_received":true,
         "step_up":{"round":2,"challenge":{"type":"blink_twice","seed":"x","total_duration_ms":1000}}}
        """)
        XCTAssertNil(StepUpInstruction(payload: response.stepUp))
    }

    func testInstructionsThisSDKCannotRenderAreIgnored() throws {
        let headTurn = try JSONDecoder().decode(ChallengeSpecWrapper.self, from: Data(headTurnJSON.utf8))
        XCTAssertNil(StepUpInstruction(payload: StepUpPayload(round: 3, challenge: headTurn, maxFrames: nil)))
        XCTAssertNil(StepUpInstruction(payload: nil))
        let instruction = StepUpInstruction(payload: StepUpPayload(round: 2, challenge: headTurn, maxFrames: nil))
        XCTAssertEqual(instruction?.maxFrames, StepUpInstruction.defaultMaxFrames)
    }

    func testCapabilitiesDeclareStepUp() {
        XCTAssertTrue(StepUpCapability.all.contains("step_up_v1"))
    }
}
