import XCTest
@testable import UseSenseSDK

final class UseSenseConfigTests: XCTestCase {
    func testSandboxEnvironmentDetection() {
        let config = UseSenseConfig(apiKey: "sk_test_abc123")
        XCTAssertEqual(config.environment, .sandbox)
    }

    func testProductionEnvironmentDetection() {
        let config = UseSenseConfig(apiKey: "pk_live_abc123")
        XCTAssertEqual(config.environment, .production)
    }

    func testExplicitEnvironmentOverride() {
        let config = UseSenseConfig(apiKey: "sk_test_abc123", environment: .production)
        XCTAssertEqual(config.environment, .production)
    }

    func testDefaultBaseURL() {
        let config = UseSenseConfig(apiKey: "sk_test_abc123")
        XCTAssertEqual(config.baseURL.absoluteString, "https://api.usesense.ai")
    }

    func testCustomBaseURL() {
        let url = URL(string: "https://custom.api.example.com")!
        let config = UseSenseConfig(apiKey: "sk_test_abc123", baseURL: url)
        XCTAssertEqual(config.baseURL, url)
    }
}

final class UseSenseErrorTests: XCTestCase {
    func testErrorCodes() {
        let error = UseSenseError.cameraUnavailable()
        XCTAssertEqual(error.code, .cameraUnavailable)
        XCTAssertFalse(error.isRetryable)
    }

    func testNetworkErrorIsRetryable() {
        let error = UseSenseError.networkError(NSError(domain: "", code: -1))
        XCTAssertTrue(error.isRetryable)
    }

    func testSessionExpiredNotRetryable() {
        let error = UseSenseError.sessionExpired()
        XCTAssertFalse(error.isRetryable)
        XCTAssertEqual(error.serverCode, "session_expired")
    }
}

final class AnyCodableValueTests: XCTestCase {
    func testStringEncoding() throws {
        let value: AnyCodableValue = "hello"
        let data = try JSONEncoder().encode(value)
        let string = String(data: data, encoding: .utf8)
        XCTAssertEqual(string, "\"hello\"")
    }

    func testIntEncoding() throws {
        let value: AnyCodableValue = 42
        let data = try JSONEncoder().encode(value)
        let string = String(data: data, encoding: .utf8)
        XCTAssertEqual(string, "42")
    }

    func testBoolEncoding() throws {
        let value: AnyCodableValue = true
        let data = try JSONEncoder().encode(value)
        let string = String(data: data, encoding: .utf8)
        XCTAssertEqual(string, "true")
    }
}

final class FrameBufferTests: XCTestCase {
    func testAppendAndRetrieve() {
        let buffer = FrameBuffer(maxCapacity: 5)
        buffer.append(frame: Data([0x01]), timestampMs: 0)
        buffer.append(frame: Data([0x02]), timestampMs: 500)

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.allFrames().count, 2)
        XCTAssertEqual(buffer.allTimestamps(), [0, 500])
    }

    func testCapacityLimit() {
        let buffer = FrameBuffer(maxCapacity: 3)
        for i in 0..<10 {
            buffer.append(frame: Data([UInt8(i)]), timestampMs: i * 500)
        }

        XCTAssertEqual(buffer.count, 3)
    }

    func testReset() {
        let buffer = FrameBuffer(maxCapacity: 10)
        buffer.append(frame: Data([0x01]), timestampMs: 0)
        buffer.reset()

        XCTAssertEqual(buffer.count, 0)
    }
}

final class ChallengeResponseBuilderTests: XCTestCase {
    func testFollowDotResponse() {
        let spec = ChallengeSpec(
            type: .followDot,
            seed: "test_seed_123",
            generatedAt: nil,
            waypoints: [
                Waypoint(x: 0.5, y: 0.5, durationMs: 1500, index: 0),
                Waypoint(x: 0.8, y: 0.2, durationMs: 1500, index: 1)
            ],
            dotSizePx: 20,
            sequence: nil,
            phrase: nil,
            phraseLanguage: nil,
            totalDurationMs: 3000,
            framesPerStep: 2,
            captureFpsHint: 10
        )

        let builder = ChallengeResponseBuilder(spec: spec)
        builder.markStarted()
        builder.setCurrentStep(0)
        builder.recordFrame(index: 0)
        builder.recordFrame(index: 1)
        builder.setCurrentStep(1)
        builder.recordFrame(index: 2)
        builder.recordFrame(index: 3)
        builder.markCompleted()

        let payload = builder.build(frameTimestamps: [0, 500, 1000, 1500])

        XCTAssertEqual(payload.type, "follow_dot")
        XCTAssertEqual(payload.seed, "test_seed_123")
        XCTAssertTrue(payload.completed)
        XCTAssertEqual(payload.waypointFrames?["0"], [0, 1])
        XCTAssertEqual(payload.waypointFrames?["1"], [2, 3])
        XCTAssertNil(payload.stepFrames)
    }

    func testHeadTurnResponse() {
        let spec = ChallengeSpec(
            type: .headTurn,
            seed: "head_seed_456",
            generatedAt: nil,
            waypoints: nil,
            dotSizePx: nil,
            sequence: [
                HeadTurnStep(direction: .left, durationMs: 2000, index: 0),
                HeadTurnStep(direction: .center, durationMs: 1500, index: 1)
            ],
            phrase: nil,
            phraseLanguage: nil,
            totalDurationMs: 3500,
            framesPerStep: 2,
            captureFpsHint: 10
        )

        let builder = ChallengeResponseBuilder(spec: spec)
        builder.markStarted()
        builder.setCurrentStep(0)
        builder.recordFrame(index: 0)
        builder.setCurrentStep(1)
        builder.recordFrame(index: 1)
        builder.markCompleted()

        let payload = builder.build(frameTimestamps: [0, 500])

        XCTAssertEqual(payload.type, "head_turn")
        XCTAssertNil(payload.waypointFrames)
        XCTAssertEqual(payload.stepFrames?["0"], [0])
        XCTAssertEqual(payload.stepFrames?["1"], [1])
    }
}

final class MultipartFormDataTests: XCTestCase {
    func testBuildMultipart() {
        var multipart = MultipartFormData(boundary: "test-boundary")
        multipart.appendFile(name: "frames[]", filename: "frame_0.jpg", contentType: "image/jpeg", data: Data([0xFF, 0xD8]))
        multipart.appendFile(name: "metadata", filename: "metadata.json", contentType: "application/json", data: Data("{}".utf8))
        let body = multipart.finalize()

        let bodyString = String(data: body, encoding: .utf8)!
        XCTAssertTrue(bodyString.contains("--test-boundary\r\n"))
        XCTAssertTrue(bodyString.contains("name=\"frames[]\""))
        XCTAssertTrue(bodyString.contains("name=\"metadata\""))
        XCTAssertTrue(bodyString.contains("--test-boundary--\r\n"))
    }

    func testContentType() {
        let multipart = MultipartFormData(boundary: "abc-123")
        XCTAssertEqual(multipart.contentType, "multipart/form-data; boundary=abc-123")
    }
}

final class CreateSessionRequestTests: XCTestCase {
    func testEnrollmentEncoding() throws {
        let request = CreateSessionRequest(
            sessionType: "enrollment",
            identityId: nil,
            externalUserId: "user_123",
            metadata: ["source": "onboarding"]
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["session_type"] as? String, "enrollment")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["external_user_id"] as? String, "user_123")
        XCTAssertNil(json["identity_id"])
    }

    func testAuthenticationEncoding() throws {
        let request = CreateSessionRequest(
            sessionType: "authentication",
            identityId: "ident_abc",
            externalUserId: nil,
            metadata: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["session_type"] as? String, "authentication")
        XCTAssertEqual(json["identity_id"] as? String, "ident_abc")
    }
}

final class ChallengeSpecDecodingTests: XCTestCase {
    func testFollowDotDecoding() throws {
        let json = """
        {
            "type": "follow_dot",
            "seed": "abc123",
            "waypoints": [
                {"x": 0.5, "y": 0.5, "duration_ms": 1500, "index": 0},
                {"x": 0.8, "y": 0.2, "duration_ms": 1500, "index": 1}
            ],
            "dot_size_px": 20,
            "total_duration_ms": 3000,
            "frames_per_step": 2,
            "capture_fps_hint": 10
        }
        """.data(using: .utf8)!

        let spec = try JSONDecoder().decode(ChallengeSpec.self, from: json)

        XCTAssertEqual(spec.type, .followDot)
        XCTAssertEqual(spec.seed, "abc123")
        XCTAssertEqual(spec.waypoints?.count, 2)
        XCTAssertEqual(spec.dotSizePx, 20)
        XCTAssertEqual(spec.totalDurationMs, 3000)
        XCTAssertEqual(spec.framesPerStep, 2)
    }

    func testHeadTurnDecoding() throws {
        let json = """
        {
            "type": "head_turn",
            "seed": "xyz789",
            "sequence": [
                {"direction": "left", "duration_ms": 2000, "index": 0},
                {"direction": "center", "duration_ms": 1500, "index": 1}
            ],
            "total_duration_ms": 3500,
            "frames_per_step": 2
        }
        """.data(using: .utf8)!

        let spec = try JSONDecoder().decode(ChallengeSpec.self, from: json)

        XCTAssertEqual(spec.type, .headTurn)
        XCTAssertEqual(spec.sequence?.count, 2)
        XCTAssertEqual(spec.sequence?.first?.direction, .left)
    }
}

final class VerdictResponseDecodingTests: XCTestCase {
    func testFullVerdictDecoding() throws {
        let json = """
        {
            "session_id": "sess_abc123",
            "organization_id": "org_xyz",
            "session_type": "enrollment",
            "identity_id": "ident_123",
            "decision": "APPROVE",
            "matrix_decision": "APPROVE",
            "channel_trust_score": 89,
            "liveness_score": 87,
            "dedupe_risk_score": 5,
            "pillar_verdicts": {
                "deepsense": {"score": 89, "verdict": "APPROVE"},
                "livesense": {"score": 87, "verdict": "APPROVE"},
                "dedupe": {"score": 5, "verdict": "APPROVE"}
            },
            "verdict_metadata": {"source": "verdict_matrix", "logic": "weakest_link"},
            "reasons": ["All three pillars passed"],
            "timestamp": "2026-03-07T12:01:30.000Z",
            "signature": "hmac_sha256_hex"
        }
        """.data(using: .utf8)!

        let verdict = try JSONDecoder().decode(VerdictResponse.self, from: json)

        XCTAssertEqual(verdict.sessionId, "sess_abc123")
        XCTAssertEqual(verdict.decision, "APPROVE")
        XCTAssertEqual(verdict.channelTrustScore, 89)
        XCTAssertEqual(verdict.livenessScore, 87)
        XCTAssertEqual(verdict.dedupeRiskScore, 5)
        XCTAssertEqual(verdict.pillarVerdicts.deepsense.score, 89)
        XCTAssertEqual(verdict.pillarVerdicts.livesense.verdict, "APPROVE")
        XCTAssertEqual(verdict.verdictMetadata?.logic, "weakest_link")
        XCTAssertEqual(verdict.signature, "hmac_sha256_hex")
    }
}

final class UploadConfigDecodingTests: XCTestCase {
    func testUploadConfigDecoding() throws {
        let json = """
        {
            "max_frames": 30,
            "target_fps": 2,
            "capture_duration_ms": 8000
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(UploadConfig.self, from: json)

        XCTAssertEqual(config.maxFrames, 30)
        XCTAssertEqual(config.targetFps, 2)
        XCTAssertEqual(config.captureDurationMs, 8000)
    }
}
