import Foundation

final class UseSenseAPIClient: @unchecked Sendable {
    private let config: UseSenseConfig
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(config: UseSenseConfig) {
        self.config = config
        self.session = URLSession(configuration: .default)
    }

    // MARK: - URL Builder

    private func buildURL(path: String, nonce: String? = nil) -> URL {
        var components = URLComponents(string: "\(config.apiBaseUrl)\(path)")!
        var queryItems = [URLQueryItem(name: "env", value: (config.environment ?? .sandbox).rawValue)]
        if let nonce = nonce {
            queryItems.append(URLQueryItem(name: "nonce", value: nonce))
        }
        components.queryItems = queryItems
        return components.url!
    }

    private func applyGatewayHeaders(_ request: inout URLRequest) {
        if let gatewayKey = config.gatewayKey {
            request.setValue("Bearer \(gatewayKey)", forHTTPHeaderField: "Authorization")
            request.setValue(gatewayKey, forHTTPHeaderField: "apikey")
        }
    }

    // MARK: - Create Session

    func createSession(request body: CreateSessionRequest) async throws -> CreateSessionResponse {
        var request = URLRequest(url: buildURL(path: "/v1/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        applyGatewayHeaders(&request)
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = 15
        return try await perform(request)
    }

    // MARK: - Upload Signals

    func uploadSignals(
        sessionId: String, sessionToken: String, nonce: String,
        frames: [Data], metadata: Data, audio: Data?
    ) async throws -> UploadSignalsResponse {
        var multipart = MultipartFormData()
        for (i, frame) in frames.enumerated() {
            multipart.appendFile(name: "frames[]", filename: "frame_\(i).jpg", contentType: "image/jpeg", data: frame)
        }
        multipart.appendFile(name: "metadata", filename: "metadata.json", contentType: "application/json", data: metadata)
        if let audio = audio {
            multipart.appendFile(name: "audio", filename: "audio.m4a", contentType: "audio/mp4", data: audio)
        }
        let body = multipart.finalize()

        var request = URLRequest(url: buildURL(path: "/v1/sessions/\(sessionId)/signals", nonce: nonce))
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(sessionToken, forHTTPHeaderField: "X-Session-Token")
        request.setValue(nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue("\(sessionId)_\(Date().timeIntervalSince1970)_\(UUID().uuidString.prefix(9))", forHTTPHeaderField: "X-Idempotency-Key")
        applyGatewayHeaders(&request)
        request.httpBody = body
        request.timeoutInterval = 30
        return try await perform(request)
    }

    // MARK: - Complete Session

    func completeSession(sessionId: String, sessionToken: String, nonce: String) async throws -> FinalDecisionObject {
        var request = URLRequest(url: buildURL(path: "/v1/sessions/\(sessionId)/complete", nonce: nonce))
        request.httpMethod = "POST"
        request.setValue(sessionToken, forHTTPHeaderField: "X-Session-Token")
        request.setValue(nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Idempotency-Key")
        applyGatewayHeaders(&request)
        request.timeoutInterval = 60
        return try await perform(request)
    }

    // MARK: - Get Session Status

    func getSessionStatus(sessionId: String, sessionToken: String) async throws -> SessionStatusResponse {
        var request = URLRequest(url: buildURL(path: "/v1/sessions/\(sessionId)/status"))
        request.httpMethod = "GET"
        request.setValue(sessionToken, forHTTPHeaderField: "X-Session-Token")
        applyGatewayHeaders(&request)
        request.timeoutInterval = 15
        return try await perform(request)
    }

    // MARK: - App Attest endpoints

    func requestAttestationChallenge() async throws -> Data {
        var request = URLRequest(url: buildURL(path: "/v1/devices/attest/challenge"))
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        applyGatewayHeaders(&request)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UseSenseError(code: .serverError, message: "Failed to get attestation challenge")
        }
        return data
    }

    func registerAttestation(keyId: String, attestationObject: Data, challenge: Data) async throws {
        var request = URLRequest(url: buildURL(path: "/v1/devices/attest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        applyGatewayHeaders(&request)
        let body: [String: String] = [
            "key_id": keyId,
            "attestation": attestationObject.base64EncodedString(),
            "challenge": challenge.base64EncodedString()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UseSenseError(code: .serverError, message: "Failed to register attestation")
        }
    }

    // MARK: - Private

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
