//
//  V4UploadClient.swift
//  UseSense
//
//  POSTs the captured MP4 + chain metadata to the v4 signals endpoint,
//  then fetches the opaque verdict from /v1/sessions/:id/result.
//  Phase 1 ticket I-2.
//

import Foundation

enum V4UploadError: Error {
    case uploadFailed(status: Int, body: String)
    case resultFailed(status: Int, body: String)
    case malformedResponse
}

enum V4UploadClient {
    static func upload(
        config: LiveSenseV4Config,
        mp4: Data,
        frameHashes: [String],
        terminalHashHex: String,
        signatureB64: String,
        publicKeySpkiB64: String,
        assuranceLevel: String,
        stats: ZoomMotionStats
    ) async throws -> V4Verdict {
        let boundary = "UseSenseV4Boundary\(UUID().uuidString)"
        let metadata: [String: Any] = [
            "session_id": config.sessionId.uuidString.lowercased(),
            "sdk_version": "ios-v4.0.0",
            "platform": "ios",
            "source": "sdk-v4",
            "assurance_level": assuranceLevel,
            "frame_hashes": frameHashes,
            "terminal_hash_hex": terminalHashHex,
            "chain_signature_b64": signatureB64,
            "public_key_spki_b64": publicKeySpkiB64,
            "zoom_motion_stats": [
                "scale_ratio": stats.scaleRatio,
                "duration_ms": stats.durationMs,
                "max_head_yaw_abs_deg": stats.maxHeadYawAbsDeg,
                "max_head_pitch_abs_deg": stats.maxHeadPitchAbsDeg,
                "observation_count": stats.observationCount
            ]
        ]
        let metadataJson = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"capture\"; filename=\"capture.mp4\"\r\n")
        append("Content-Type: video/mp4\r\n\r\n")
        body.append(mp4)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(metadataJson)
        append("\r\n--\(boundary)--\r\n")

        // POST /v1/sessions/:id/signals
        let base = config.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let signalsUrl = URL(string:
            "\(base)/sessions/\(config.sessionId.uuidString.lowercased())/signals?env=\(config.environment)&nonce=\(config.nonce)"
        )!
        var req = URLRequest(url: signalsUrl)
        req.httpMethod = "POST"
        req.setValue("v4", forHTTPHeaderField: "x-usesense-sdk-version")
        req.setValue(config.sessionToken, forHTTPHeaderField: "x-session-token")
        req.setValue(config.nonce, forHTTPHeaderField: "x-nonce")
        req.setValue(config.environment, forHTTPHeaderField: "x-environment")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "x-idempotency-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (uploadResp, uploadRespObj) = try await URLSession.shared.data(for: req)
        guard let http = uploadRespObj as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: uploadResp, encoding: .utf8) ?? ""
            let status = (uploadRespObj as? HTTPURLResponse)?.statusCode ?? -1
            throw V4UploadError.uploadFailed(status: status, body: bodyText)
        }

        // POST /v1/sessions/:id/result
        let resultUrl = URL(string:
            "\(base)/sessions/\(config.sessionId.uuidString.lowercased())/result?env=\(config.environment)&nonce=\(config.nonce)"
        )!
        var r2 = URLRequest(url: resultUrl)
        r2.httpMethod = "POST"
        r2.setValue("v4", forHTTPHeaderField: "x-usesense-sdk-version")
        r2.setValue(config.sessionToken, forHTTPHeaderField: "x-session-token")
        r2.setValue(config.nonce, forHTTPHeaderField: "x-nonce")
        r2.setValue(config.environment, forHTTPHeaderField: "x-environment")

        let (resultData, resultResp) = try await URLSession.shared.data(for: r2)
        guard let http = resultResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: resultData, encoding: .utf8) ?? ""
            let status = (resultResp as? HTTPURLResponse)?.statusCode ?? -1
            throw V4UploadError.resultFailed(status: status, body: bodyText)
        }
        do {
            return try JSONDecoder().decode(V4Verdict.self, from: resultData)
        } catch {
            throw V4UploadError.malformedResponse
        }
    }
}
