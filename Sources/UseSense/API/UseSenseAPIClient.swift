import Foundation

final class UseSenseAPIClient: @unchecked Sendable {
    static let defaultGatewayKey = UseSenseConfig.defaultGatewayKey

    static let sdkVersion = "1.17.57"
    private static let userAgent = "UseSense-iOS-SDK/\(sdkVersion)"

    // Retry delays in seconds: immediate, 1s, 3s
    private static let retryDelays: [TimeInterval] = [0, 1.0, 3.0]

    private let config: UseSenseConfig
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private let gatewayKey: String

    // Session-scoped state (set after createSession or injected by hosted page flow)
    var sessionToken: String?
    var nonce: String?

    init(config: UseSenseConfig) {
        self.config = config
        self.gatewayKey = config.gatewayKey

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: sessionConfig)
    }

    func clearSession() {
        sessionToken = nil
        nonce = nil
    }

    // MARK: - URL Builder

    private func buildURL(path: String, includeNonce: Bool = false) -> URL {
        let baseUrl = config.apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBase = baseUrl.isEmpty || URLComponents(string: baseUrl)?.scheme == nil
            ? UseSenseConfig.defaultEndpoint
            : baseUrl
        guard let parsed = URLComponents(string: "\(effectiveBase)\(path)"),
              parsed.scheme != nil, parsed.host != nil else {
            fatalError("UseSense: Invalid apiEndpoint '\(config.apiEndpoint)'. Must be a full URL including https:// scheme.")
        }
        var components = parsed
        let env = (config.environment ?? .auto).resolved(apiKey: config.apiKey)
        var queryItems = [URLQueryItem(name: "env", value: env)]

        // Nonce dual-delivery: query param + header for proxy/CDN robustness
        if includeNonce, let nonce = nonce {
            queryItems.append(URLQueryItem(name: "nonce", value: nonce))
        }

        components.queryItems = queryItems
        return components.url!
    }

    /// Apply Layer 1 (Supabase gateway) + Layer 2 (session-specific) headers.
    private func applyHeaders(_ request: inout URLRequest, includeSession: Bool = false) {
        // Layer 1: Supabase gateway auth (ALL requests)
        request.setValue("Bearer \(gatewayKey)", forHTTPHeaderField: "Authorization")
        request.setValue(gatewayKey, forHTTPHeaderField: "apikey")

        // User-Agent
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        // Layer 2: Session-specific headers
        if includeSession {
            if let token = sessionToken {
                request.setValue(token, forHTTPHeaderField: "X-Session-Token")
            }
            // Nonce dual-delivery: header (in addition to query param)
            if let nonce = nonce {
                request.setValue(nonce, forHTTPHeaderField: "X-Nonce")
            }
        }
    }

    // MARK: - Create Session

    func createSession(request body: CreateSessionRequest) async throws -> CreateSessionResponse {
        var request = URLRequest(url: buildURL(path: "/v1/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        applyHeaders(&request)
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = 15

        let response: CreateSessionResponse = try await perform(request)

        // Store session-scoped state
        sessionToken = response.sessionToken
        nonce = response.nonce

        return response
    }

    // MARK: - Upload Signals

    func uploadSignals(
        sessionId: String, sessionToken: String, nonce: String,
        frames: [Data], metadata: Data, audio: Data?
    ) async throws -> UploadSignalsResponse {
        self.sessionToken = sessionToken
        self.nonce = nonce

        var multipart = MultipartFormData()
        for (i, frame) in frames.enumerated() {
            multipart.appendFile(name: "frames[]", filename: "frame_\(i).jpg", contentType: "image/jpeg", data: frame)
        }
        multipart.appendFile(name: "metadata", filename: "metadata.json", contentType: "application/json", data: metadata)
        if let audio = audio {
            multipart.appendFile(name: "audio", filename: "audio.m4a", contentType: "audio/mp4", data: audio)
        }
        let body = multipart.finalize()

        var request = URLRequest(url: buildURL(path: "/v1/sessions/\(sessionId)/signals", includeNonce: true))
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        applyHeaders(&request, includeSession: true)
        request.setValue("\(sessionId)_\(Date().timeIntervalSince1970)_\(UUID().uuidString.prefix(9))", forHTTPHeaderField: "X-Idempotency-Key")
        request.httpBody = body
        request.timeoutInterval = 30

        return try await performWithRetry(request)
    }

    // MARK: - Complete Session

    func completeSession(sessionId: String, sessionToken: String, nonce: String) async throws -> FinalDecisionObject {
        self.sessionToken = sessionToken
        self.nonce = nonce

        var request = URLRequest(url: buildURL(path: "/v1/sessions/\(sessionId)/complete", includeNonce: true))
        request.httpMethod = "POST"
        applyHeaders(&request, includeSession: true)
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Idempotency-Key")
        request.timeoutInterval = 60

        return try await performWithRetry(request)
    }

    // MARK: - Hosted Page Endpoints

    /// GET /remote-enrollment/{id}/data
    func getRemoteEnrollmentData(enrollmentId: String) async throws -> RemoteEnrollmentData {
        var request = URLRequest(url: buildURL(path: "/remote-enrollment/\(enrollmentId)/data"))
        request.httpMethod = "GET"
        applyHeaders(&request)
        request.timeoutInterval = 15
        return try await perform(request)
    }

    /// POST /remote-enrollment/{id}/opened
    func markEnrollmentOpened(enrollmentId: String) async throws {
        var request = URLRequest(url: buildURL(path: "/remote-enrollment/\(enrollmentId)/opened"))
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.timeoutInterval = 10
        let _: EmptyResponse = try await perform(request)
    }

    /// POST /remote-enrollment/{id}/init-session
    func initEnrollmentSession(enrollmentId: String) async throws -> HostedInitSessionResponse {
        var request = URLRequest(url: buildURL(path: "/remote-enrollment/\(enrollmentId)/init-session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&request)
        request.timeoutInterval = 15
        let response: HostedInitSessionResponse = try await perform(request)
        sessionToken = response.sessionToken
        nonce = response.nonce
        return response
    }

    /// POST /remote-enrollment/{id}/complete
    func completeRemoteEnrollment(enrollmentId: String) async throws -> RemoteCompleteResponse {
        var request = URLRequest(url: buildURL(path: "/remote-enrollment/\(enrollmentId)/complete"))
        request.httpMethod = "POST"
        applyHeaders(&request, includeSession: true)
        request.timeoutInterval = 30
        return try await performWithRetry(request)
    }

    /// GET /remote-session/{id}/data
    func getRemoteSessionData(sessionId: String) async throws -> RemoteSessionData {
        var request = URLRequest(url: buildURL(path: "/remote-session/\(sessionId)/data"))
        request.httpMethod = "GET"
        applyHeaders(&request)
        request.timeoutInterval = 15
        return try await perform(request)
    }

    /// POST /remote-session/{id}/opened
    func markSessionOpened(sessionId: String) async throws {
        var request = URLRequest(url: buildURL(path: "/remote-session/\(sessionId)/opened"))
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.timeoutInterval = 10
        let _: EmptyResponse = try await perform(request)
    }

    /// POST /remote-session/{id}/init-session
    func initRemoteSession(sessionId: String) async throws -> HostedInitSessionResponse {
        var request = URLRequest(url: buildURL(path: "/remote-session/\(sessionId)/init-session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&request)
        request.timeoutInterval = 15
        let response: HostedInitSessionResponse = try await perform(request)
        sessionToken = response.sessionToken
        nonce = response.nonce
        return response
    }

    /// POST /remote-session/{id}/complete
    func completeRemoteSession(sessionId: String) async throws -> RemoteCompleteResponse {
        var request = URLRequest(url: buildURL(path: "/remote-session/\(sessionId)/complete"))
        request.httpMethod = "POST"
        applyHeaders(&request, includeSession: true)
        request.timeoutInterval = 30
        return try await performWithRetry(request)
    }

    /// POST /remote-session/{id}/dispute
    func disputeRemoteSession(sessionId: String) async throws -> DisputeResponse {
        var request = URLRequest(url: buildURL(path: "/remote-session/\(sessionId)/dispute"))
        request.httpMethod = "POST"
        applyHeaders(&request)
        request.timeoutInterval = 15
        return try await perform(request)
    }

    // MARK: - Get Session Status

    func getSessionStatus(sessionId: String, sessionToken: String) async throws -> SessionStatusResponse {
        self.sessionToken = sessionToken

        var request = URLRequest(url: buildURL(path: "/v1/sessions/\(sessionId)/status"))
        request.httpMethod = "GET"
        applyHeaders(&request, includeSession: true)
        request.timeoutInterval = 15

        return try await perform(request)
    }

    // MARK: - Retry Logic

    /// Perform request with retry on 500 errors (0s, 1s, 3s delays).
    private func performWithRetry<T: Decodable>(_ request: URLRequest) async throws -> T {
        var lastError: Error?

        for (attempt, delay) in Self.retryDelays.enumerated() {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw UseSenseError(code: .networkError, message: "Invalid response type.")
                }

                // Only retry on 500 errors
                if http.statusCode == 500 && attempt < Self.retryDelays.count - 1 {
                    lastError = UseSenseError.fromHTTP(statusCode: 500, serverCode: nil, serverMessage: "Server error")
                    continue
                }

                guard (200...299).contains(http.statusCode) else {
                    if let errorResp = try? decoder.decode(ErrorResponse.self, from: data) {
                        throw UseSenseError.fromHTTP(statusCode: http.statusCode, serverCode: errorResp.error.code, serverMessage: errorResp.error.message)
                    }
                    throw UseSenseError.fromHTTP(statusCode: http.statusCode, serverCode: nil, serverMessage: "Server returned status \(http.statusCode).")
                }

                return try decoder.decode(T.self, from: data)
            } catch let error as UseSenseError where error.code == .serverError && attempt < Self.retryDelays.count - 1 {
                lastError = error
                continue
            } catch {
                throw error
            }
        }

        throw lastError ?? UseSenseError(code: .serverError, message: "Request failed after retries")
    }

    // MARK: - Single Request (no retry)

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw UseSenseError(code: .timeout)
        } catch {
            throw UseSenseError(code: .networkError, message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UseSenseError(code: .networkError, message: "Invalid response type.")
        }

        guard (200...299).contains(http.statusCode) else {
            if let errorResp = try? decoder.decode(ErrorResponse.self, from: data) {
                throw UseSenseError.fromHTTP(statusCode: http.statusCode, serverCode: errorResp.error.code, serverMessage: errorResp.error.message)
            }
            throw UseSenseError.fromHTTP(statusCode: http.statusCode, serverCode: nil, serverMessage: "Server returned status \(http.statusCode).")
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw UseSenseError(code: .unknownError, message: "Failed to decode response.", details: error.localizedDescription)
        }
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

/// Used for endpoints that return minimal/empty JSON bodies (e.g. /opened).
struct EmptyResponse: Decodable {}
