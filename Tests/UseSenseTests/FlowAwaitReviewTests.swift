import XCTest
@testable import UseSenseSDK

/// A run parked for manual review. The server (watchtower
/// modules/flows/runtime.ts + endpoints.ts hostedView) sets state
/// `awaiting_review` and pending action `{ kind: "await_review", stepId,
/// instructions }` together, so the runner must treat that pair as the end of
/// the person's part, never as an unsupported step.
final class FlowAwaitReviewTests: XCTestCase {
    private let baseURL = URL(string: "https://api.usesense.ai")!

    /// The exact shape `hostedView()` returns for a review hold.
    private let serverAwaitReviewPayload = """
    {
      "flowRun": {
        "id": "fr_review_1",
        "state": "awaiting_review",
        "outcome": null,
        "cursorStepId": "step_review",
        "pendingAction": {
          "kind": "await_review",
          "stepId": "step_review",
          "instructions": "Check the licence photo against the selfie."
        },
        "environment": "production",
        "lastCaptureError": null
      },
      "definitionSteps": [
        { "id": "step_face", "type": "tool", "label": "Face", "toolId": "liveness" },
        { "id": "step_review", "type": "manual_review", "label": "Manual review" }
      ],
      "stepRuns": [],
      "branding": null
    }
    """

    private func client(body: String) -> FlowsClient {
        FlowsClient(flowRunId: "fr_review_1", sdkToken: "t", apiBaseURL: baseURL) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        }
    }

    private func decode(_ body: String) throws -> FlowRunView {
        try FlowRunView.decode(try JSONSerialization.jsonObject(with: Data(body.utf8)))
    }

    // MARK: - Decode

    func test_exactServerPayload_decodesThroughClient() async throws {
        let view = try await client(body: serverAwaitReviewPayload).get()
        XCTAssertEqual(view.id, "fr_review_1")
        XCTAssertEqual(view.state, .awaitingReview)
        XCTAssertNil(view.outcome)
        XCTAssertEqual(view.cursorStepId, "step_review")
        XCTAssertEqual(view.pendingAction, .awaitReview(
            stepId: "step_review",
            instructions: "Check the licence photo against the selfie."
        ))
    }

    func test_awaitReview_withoutInstructions_decodes() throws {
        let action = try PendingAction.decode(["kind": "await_review", "stepId": "s1"])
        XCTAssertEqual(action, .awaitReview(stepId: "s1", instructions: nil))
    }

    func test_unknownKind_doesNotFailViewDecode() throws {
        let body = serverAwaitReviewPayload
            .replacingOccurrences(of: "\"awaiting_review\"", with: "\"stalled\"")
            .replacingOccurrences(of: "\"await_review\"", with: "\"capture_hologram\"")
        let view = try decode(body)
        XCTAssertEqual(view.state, .stalled)
        XCTAssertEqual(view.pendingAction, .unsupported(kind: "capture_hologram"))
        XCTAssertFalse(view.isSettled, "an unknown step is not the end of the run")
    }

    func test_unknownCaptureVariant_decodesAsUnsupported() {
        XCTAssertEqual(PendingAction.decodeLenient(["kind": "capture", "capture": "palm"]), .unsupported(kind: "capture:palm"))
    }

    func test_malformedKnownKind_decodesAsUnsupported() {
        XCTAssertEqual(PendingAction.decodeLenient(["kind": "info"]), .unsupported(kind: "info"))
        XCTAssertEqual(PendingAction.decodeLenient([:]), .unsupported(kind: "unknown"))
    }

    func test_strictDecode_stillThrowsForUnknownKind() {
        XCTAssertThrowsError(try PendingAction.decode(["kind": "capture_hologram"])) { error in
            XCTAssertEqual((error as? FlowError)?.code, .unsupportedAction)
        }
    }

    // MARK: - Settled run

    func test_exactServerPayload_settlesOnReviewScreen() throws {
        let view = try decode(serverAwaitReviewPayload)
        XCTAssertTrue(view.isAwaitingReview)
        XCTAssertTrue(view.isSettled)
        XCTAssertEqual(view.endScreen, .review)
        XCTAssertEqual(view.settledResult, FlowRunResult(flowRunId: "fr_review_1", state: .awaitingReview, outcome: nil))
    }

    func test_awaitingReviewState_withoutAction_settlesOnReviewScreen() throws {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(serverAwaitReviewPayload.utf8)) as? [String: Any])
        var run = try XCTUnwrap(root["flowRun"] as? [String: Any])
        run["pendingAction"] = NSNull()
        root["flowRun"] = run
        let view = try FlowRunView.decode(root)
        XCTAssertNil(view.pendingAction)
        XCTAssertTrue(view.isSettled)
        XCTAssertEqual(view.endScreen, .review)
        XCTAssertEqual(view.settledResult.state, .awaitingReview)
    }

    func test_awaitReviewAction_aloneIsEnough() throws {
        let body = serverAwaitReviewPayload.replacingOccurrences(of: "\"awaiting_review\"", with: "\"stalled\"")
        let view = try decode(body)
        XCTAssertEqual(view.state, .stalled)
        XCTAssertTrue(view.isSettled)
        XCTAssertEqual(view.endScreen, .review)
        XCTAssertEqual(view.settledResult.state, .awaitingReview)
    }

    func test_awaitingReview_keepsOutcome() throws {
        let body = serverAwaitReviewPayload.replacingOccurrences(of: "\"outcome\": null", with: "\"outcome\": \"MANUAL_REVIEW\"")
        let view = try decode(body)
        XCTAssertEqual(view.settledResult, FlowRunResult(flowRunId: "fr_review_1", state: .awaitingReview, outcome: .manualReview))
        XCTAssertEqual(view.endScreen, .review)
    }

    func test_terminalStates_endScreens() throws {
        func view(state: String, outcome: String?) throws -> FlowRunView {
            try FlowRunView.decode([
                "flowRun": [
                    "id": "fr_1", "state": state, "outcome": outcome as Any? ?? NSNull(),
                    "environment": "production", "pendingAction": NSNull(),
                ],
            ])
        }
        XCTAssertEqual(try view(state: "completed", outcome: "APPROVE").endScreen, .success)
        XCTAssertEqual(try view(state: "completed", outcome: "REJECT").endScreen, .notVerified)
        XCTAssertEqual(try view(state: "completed", outcome: "MANUAL_REVIEW").endScreen, .review)
        XCTAssertEqual(try view(state: "errored", outcome: nil).endScreen, .notVerified)
        XCTAssertTrue(try view(state: "completed", outcome: "APPROVE").isSettled)
        XCTAssertFalse(try view(state: "in_progress", outcome: nil).isSettled)
        XCTAssertFalse(try view(state: "stalled", outcome: nil).isSettled)
        XCTAssertEqual(try view(state: "completed", outcome: "APPROVE").settledResult.state, .completed)
    }

    // MARK: - Subject copy

    #if canImport(UIKit) && canImport(SafariServices)
    func test_unsupportedAction_hasItsOwnSubjectMessage_andIsRetryable() {
        let error = FlowError(code: .unsupportedAction, message: "Unsupported pendingAction.kind: capture_hologram")
        XCTAssertTrue(error.isRetryable)
        let message = FlowsRunnerViewController.subjectMessage(for: error)
        XCTAssertFalse(message.contains("capture_hologram"), "the raw kind is never shown to the person")
        XCTAssertEqual(message, "This step could not be shown here. Try again, or come back later.")
    }
    #endif

    func test_reviewerInstructions_neverReachTheResult() throws {
        let view = try decode(serverAwaitReviewPayload)
        XCTAssertFalse(String(describing: view.settledResult).contains("licence photo"))
    }
}
