import XCTest
@testable import UseSenseSDK

/// Tests the SDK-Runner HTTP client. Two things are load-bearing:
///
///   1. Auth: Bearer header on every request; sdkToken never lands in the URL.
///   2. Error translation: server HTTP/JSON envelope maps to the FlowError
///      taxonomy host apps catch on per code.
final class FlowsClientTests: XCTestCase {
    private let baseURL = URL(string: "https://api.usesense.ai")!

    private func makeFetcher(status: Int, body: [String: Any]) -> FlowsClient.Fetcher {
        return { request in
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response)
        }
    }

    private func sample(state: String) -> [String: Any] {
        return [
            "flowRun": [
                "id": "fr_1",
                "state": state,
                "outcome": NSNull(),
                "cursorStepId": NSNull(),
                "environment": "production",
                "pendingAction": NSNull(),
            ],
            "definitionSteps": [],
            "stepRuns": [],
            "branding": NSNull(),
        ]
    }

    func test_get_sendsBearerHeader_andTokenNeverInURL() async throws {
        let captured = LockedBox<URLRequest>()
        let client = FlowsClient(flowRunId: "fr_1", sdkToken: "tok_abc", apiBaseURL: baseURL) { request in
            captured.set(request)
            let body = self.sample(state: "pending")
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        _ = try await client.get()
        let req = captured.value!
        XCTAssertEqual(req.url?.path, "/v1/sdk/flow-runs/fr_1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        XCTAssertFalse(req.url?.absoluteString.contains("tok_abc") ?? false, "token must not appear in the URL")
    }

    func test_advance_postsInputsAsJSONBody() async throws {
        let captured = LockedBox<URLRequest>()
        let client = FlowsClient(flowRunId: "fr_1", sdkToken: "t", apiBaseURL: baseURL) { request in
            captured.set(request)
            let body = self.sample(state: "in_progress")
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        _ = try await client.advance(inputs: ["document_id": "doc_1"])
        let req = captured.value!
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/v1/sdk/flow-runs/fr_1/advance")
        let parsed = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any]
        let inputs = parsed?["inputs"] as? [String: Any]
        XCTAssertEqual(inputs?["document_id"] as? String, "doc_1")
    }

    func test_401_translatesTo_tokenExpired() async {
        let client = FlowsClient(flowRunId: "fr_1", sdkToken: "t", apiBaseURL: baseURL,
                                 fetcher: makeFetcher(status: 401, body: ["error": "SDK token has expired", "code": "token_expired"]))
        do {
            _ = try await client.get()
            XCTFail("expected throw")
        } catch let e as FlowError {
            XCTAssertEqual(e.code, .tokenExpired)
        } catch {
            XCTFail("wrong error type")
        }
    }

    func test_403_translatesTo_tokenInvalid() async {
        let client = FlowsClient(flowRunId: "fr_1", sdkToken: "t", apiBaseURL: baseURL,
                                 fetcher: makeFetcher(status: 403, body: ["error": "Invalid token", "code": "forbidden"]))
        do { _ = try await client.get(); XCTFail() } catch let e as FlowError {
            XCTAssertEqual(e.code, .tokenInvalid)
        } catch { XCTFail() }
    }

    func test_5xx_translatesTo_providerUnavailable() async {
        let client = FlowsClient(flowRunId: "fr_1", sdkToken: "t", apiBaseURL: baseURL,
                                 fetcher: makeFetcher(status: 503, body: ["error": "unavailable"]))
        do { _ = try await client.advance(inputs: [:]); XCTFail() } catch let e as FlowError {
            XCTAssertEqual(e.code, .providerUnavailable)
        } catch { XCTFail() }
    }

    func test_transportError_translatesTo_networkUnavailable() async {
        let client = FlowsClient(flowRunId: "fr_1", sdkToken: "t", apiBaseURL: baseURL) { _ in
            throw URLError(.notConnectedToInternet)
        }
        do { _ = try await client.cancel(); XCTFail() } catch let e as FlowError {
            XCTAssertEqual(e.code, .networkUnavailable)
        } catch { XCTFail() }
    }
}

/// Tiny Sendable container so a fetcher closure can record the URLRequest it
/// saw without violating the Sendable boundary of the @Sendable Fetcher type.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}
