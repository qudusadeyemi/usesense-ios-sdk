import Foundation

final class UseSenseAPIClient: @unchecked Sendable {
    private let config: UseSenseConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(config: UseSenseConfig) {
        self.config = config
        self.session = URLSession(configuration: .default)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Create Session

    func createSession(request: CreateSessionRequest) async throws -> CreateSessionResponse {
        let url = config.baseURL.appendingPathComponent("v1/sessions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(config.environment.rawValue, forHTTPHeaderField: "X-Environment")
        urlRequest.httpBody = try encoder.encode(request)
        urlRequest.timeoutInterval = 15

        return try await perform(urlRequest)
    }

    // MARK: - Upload Signals

    func uploadSignals(
        sessionId: String,
        sessionData: SessionData,
        frames: [Data],
        metadata: Data,
        audio: Data?
    ) async throws -> UploadSignalsResponse {
        var multipart = MultipartFormData()

        for (index, frame) in frames.enumerated() {
            multipart.appendFile(
                name: "frames[]",
                filename: "frame_\(index).jpg",
                contentType: "image/jpeg",
                data: frame
            )
        }

        multipart.appendFile(
            name: "metadata",
            filename: "metadata.json",
            contentType: "application/json",
            data: metadata
        )

        if let audio = audio {
            multipart.appendFile(
                name: "audio",
                filename: "audio.m4a",
                contentType: "audio/mp4",
                data: audio
            )
        }

        let body = multipart.finalize()
        let nonceParam = sessionData.nonce.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionData.nonce
        let url = config.baseURL.appendingPathComponent("v1/sessions/\(sessionId)/signals")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "nonce", value: nonceParam)]

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(sessionData.sessionToken, forHTTPHeaderField: "X-Session-Token")
        urlRequest.setValue(sessionData.nonce, forHTTPHeaderField: "X-Nonce")
        urlRequest.setValue(UUID().uuidString, forHTTPHeaderField: "X-Idempotency-Key")
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = 30

        return try await perform(urlRequest)
    }

    // MARK: - Complete Session

    func completeSession(sessionId: String, sessionData: SessionData) async throws -> VerdictResponse {
        let nonceParam = sessionData.nonce.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionData.nonce
        let url = config.baseURL.appendingPathComponent("v1/sessions/\(sessionId)/complete")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "nonce", value: nonceParam)]

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(sessionData.sessionToken, forHTTPHeaderField: "X-Session-Token")
        urlRequest.setValue(sessionData.nonce, forHTTPHeaderField: "X-Nonce")
        urlRequest.setValue(UUID().uuidString, forHTTPHeaderField: "X-Idempotency-Key")
        urlRequest.timeoutInterval = 60

        return try await perform(urlRequest)
    }

    // MARK: - Get Session Status

    func getSessionStatus(sessionId: String, sessionToken: String) async throws -> SessionStatusResponse {
        let url = config.baseURL.appendingPathComponent("v1/sessions/\(sessionId)/status")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(sessionToken, forHTTPHeaderField: "X-Session-Token")
        urlRequest.timeoutInterval = 15

        return try await perform(urlRequest)
    }

    // MARK: - Private

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw UseSenseError.networkTimeout()
        } catch {
            throw UseSenseError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UseSenseError(code: .networkError, message: "Invalid response type.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                throw mapServerError(errorResponse.error, statusCode: httpResponse.statusCode)
            }
            throw UseSenseError(
                code: .networkError,
                message: "Server returned status \(httpResponse.statusCode).",
                isRetryable: httpResponse.statusCode >= 500
            )
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw UseSenseError(code: .networkError, message: "Failed to decode server response.", underlyingError: error)
        }
    }

    private func mapServerError(_ detail: ErrorDetail, statusCode: Int) -> UseSenseError {
        let code: UseSenseErrorCode
        let isRetryable: Bool

        switch detail.code {
        case "session_expired":
            code = .sessionExpired; isRetryable = false
        case "invalid_token", "unauthorized", "nonce_mismatch":
            code = .sessionCreationFailed; isRetryable = false
        case "invalid_upload":
            code = .uploadFailed; isRetryable = false
        case "internal_error":
            code = .networkError; isRetryable = true
        default:
            code = statusCode >= 500 ? .networkError : .sessionCreationFailed
            isRetryable = statusCode >= 500
        }

        return UseSenseError(
            code: code,
            serverCode: detail.code,
            message: detail.message,
            isRetryable: isRetryable
        )
    }
}

struct SessionStatusResponse: Decodable {
    let sessionId: String
    let status: String
    let createdAt: String?
    let expiresAt: String?
    let decision: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case status
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case decision
    }
}
