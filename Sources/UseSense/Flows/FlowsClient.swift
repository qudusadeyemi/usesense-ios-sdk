import Foundation

/// HTTP client for the SDK Runner endpoints (/v1/sdk/flow-runs/*). Bearer
/// auth (Authorization: Bearer <sdkToken>) so the token never lands in URLs
/// (which end up in server logs and browser history). The transport is
/// injectable for tests — pass a `URLSession` configured with a stub
/// `URLProtocol` to verify behaviour without hitting the network.
public final class FlowsClient: @unchecked Sendable {
    public typealias Fetcher = @Sendable (_ request: URLRequest) async throws -> (Data, URLResponse)

    private let flowRunId: String
    private let sdkToken: String
    private let baseURL: URL
    private let fetcher: Fetcher

    public init(flowRunId: String, sdkToken: String, apiBaseURL: URL, session: URLSession = .shared) {
        self.flowRunId = flowRunId
        self.sdkToken = sdkToken
        self.baseURL = apiBaseURL
        self.fetcher = { request in try await session.data(for: request) }
    }

    /// Direct fetcher constructor used by tests.
    public init(flowRunId: String, sdkToken: String, apiBaseURL: URL, fetcher: @escaping Fetcher) {
        self.flowRunId = flowRunId
        self.sdkToken = sdkToken
        self.baseURL = apiBaseURL
        self.fetcher = fetcher
    }

    private func url(_ suffix: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/sdk/flow-runs/\(flowRunId)\(suffix)"
        return components.url!
    }

    private func makeRequest(method: String, suffix: String, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url(suffix))
        request.httpMethod = method
        request.setValue("Bearer \(sdkToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Any {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetcher(request)
        } catch {
            throw FlowError(code: .networkUnavailable, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FlowError(code: .unknown, message: "Non-HTTP response")
        }
        if (200..<300).contains(http.statusCode) {
            return try JSONSerialization.jsonObject(with: data)
        }
        let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = envelope?["code"] as? String
        let message = (envelope?["error"] as? String) ?? "Request failed with status \(http.statusCode)"
        throw FlowsClient.translate(status: http.statusCode, code: code, message: message)
    }

    /// Map server HTTP/JSON error to the SDK's FlowError taxonomy. Kept as a
    /// static so tests can verify the translation independently of any I/O.
    static func translate(status: Int, code: String?, message: String) -> FlowError {
        switch (status, code) {
        case (401, _), (_, "token_expired"):
            return FlowError(code: .tokenExpired, message: message, serverCode: code)
        case (403, _), (_, "forbidden"):
            return FlowError(code: .tokenInvalid, message: message, serverCode: code)
        case (500..., _), (_, "provider_unavailable"), (_, "internal"):
            return FlowError(code: .providerUnavailable, message: message, serverCode: code)
        default:
            return FlowError(code: .unknown, message: message, serverCode: code)
        }
    }

    // MARK: - Public methods

    public func get() async throws -> FlowRunView {
        let request = try makeRequest(method: "GET", suffix: "")
        return try FlowRunView.decode(try await send(request))
    }

    public func advance(inputs: [String: Any]) async throws -> FlowRunView {
        let request = try makeRequest(method: "POST", suffix: "/advance", body: ["inputs": inputs])
        return try FlowRunView.decode(try await send(request))
    }

    public func cancel() async throws -> FlowRunView {
        let request = try makeRequest(method: "POST", suffix: "/cancel")
        return try FlowRunView.decode(try await send(request))
    }

    public struct InitSessionResponse {
        public let sessionId: String
        public let sessionToken: String
        public let nonce: String
        public let policy: [String: Any]
        public let upload: [String: Any]
        public let geometricCoherence: [String: Any]?
    }

    public func initSession(toolId: String?) async throws -> InitSessionResponse {
        let body: [String: Any] = toolId.map { ["toolId": $0] } ?? [:]
        let request = try makeRequest(method: "POST", suffix: "/init-session", body: body)
        guard let json = try await send(request) as? [String: Any],
              let sessionId = json["session_id"] as? String,
              let sessionToken = json["session_token"] as? String,
              let nonce = json["nonce"] as? String else {
            throw FlowError(code: .unknown, message: "Malformed init-session response")
        }
        return InitSessionResponse(
            sessionId: sessionId,
            sessionToken: sessionToken,
            nonce: nonce,
            policy: (json["policy"] as? [String: Any]) ?? [:],
            upload: (json["upload"] as? [String: Any]) ?? [:],
            geometricCoherence: json["geometric_coherence"] as? [String: Any]
        )
    }

    public struct UploadDocumentResponse {
        public let documentId: String
        public let status: String
        public let reason: String?
    }

    public func uploadDocument(data: String, mimeType: String, side: String, documentType: String?) async throws -> UploadDocumentResponse {
        var body: [String: Any] = ["data": data, "mimeType": mimeType, "side": side]
        if let documentType { body["documentType"] = documentType }
        let request = try makeRequest(method: "POST", suffix: "/documents", body: body)
        guard let json = try await send(request) as? [String: Any],
              let documentId = json["document_id"] as? String,
              let status = json["status"] as? String else {
            throw FlowError(code: .unknown, message: "Malformed documents response")
        }
        return UploadDocumentResponse(documentId: documentId, status: status, reason: json["reason"] as? String)
    }
}
