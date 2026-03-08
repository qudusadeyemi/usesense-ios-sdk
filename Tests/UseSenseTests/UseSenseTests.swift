import XCTest
@testable import UseSenseSDK

final class UseSenseConfigTests: XCTestCase {
    func testDefaultConfig() {
        let config = UseSenseConfig(apiKey: "sk_test_123")
        XCTAssertEqual(config.apiBaseUrl, "https://api.usesense.ai/functions/v1/make-server-fc4cf30d")
        XCTAssertEqual(config.apiKey, "sk_test_123")
        XCTAssertNil(config.gatewayKey)
        XCTAssertEqual(config.environment, .sandbox)
    }

    func testProductionDetection() {
        let config = UseSenseConfig(apiKey: "pk_live_abc")
        XCTAssertEqual(config.environment, .production)
    }

    func testDkPrefixSandbox() {
        let config = UseSenseConfig(apiKey: "dk_test_key")
        XCTAssertEqual(config.environment, .sandbox)
    }

    func testAutoEnvironmentResolution() {
        let auto = Environment.auto
        XCTAssertEqual(auto.resolved(apiKey: "pk_live"), "production")
        XCTAssertEqual(auto.resolved(apiKey: "sk_test"), "sandbox")
        XCTAssertEqual(auto.resolved(apiKey: "dk_dev"), "sandbox")
    }

    func testCustomConfig() {
        let config = UseSenseConfig(
            apiBaseUrl: "https://custom.api.com",
            apiKey: "key",
            gatewayKey: "gw_key",
            environment: .production,
            options: SDKOptions(audioEnabled: .always, targetFps: 10, maxFrames: 20)
        )
        XCTAssertEqual(config.apiBaseUrl, "https://custom.api.com")
        XCTAssertEqual(config.gatewayKey, "gw_key")
        XCTAssertEqual(config.environment, .production)
        XCTAssertEqual(config.options?.targetFps, 10)
        XCTAssertEqual(config.options?.maxFrames, 20)
    }
}

final class UseSenseErrorTests: XCTestCase {
    func testErrorCodes() {
        let error = UseSenseError(code: .cameraPermissionDenied)
        XCTAssertEqual(error.code, .cameraPermissionDenied)
        XCTAssertEqual(error.code.rawValue, "CAMERA_PERMISSION_DENIED")
        XCTAssertFalse(error.message.isEmpty)
    }

    func testCustomMessage() {
        let error = UseSenseError(code: .networkError, message: "Custom message")
        XCTAssertEqual(error.message, "Custom message")
    }

    func testHTTPMapping() {
        let e400 = UseSenseError.fromHTTP(statusCode: 400, serverCode: nil, serverMessage: "Bad")
        XCTAssertEqual(e400.code, .invalidRequest)

        let e401 = UseSenseError.fromHTTP(statusCode: 401, serverCode: "session_expired", serverMessage: nil)
        XCTAssertEqual(e401.code, .sessionExpired)

        let e401Token = UseSenseError.fromHTTP(statusCode: 401, serverCode: "invalid_token", serverMessage: nil)
        XCTAssertEqual(e401Token.code, .invalidToken)

        let e401Default = UseSenseError.fromHTTP(statusCode: 401, serverCode: nil, serverMessage: nil)
        XCTAssertEqual(e401Default.code, .unauthorized)

        let e404 = UseSenseError.fromHTTP(statusCode: 404, serverCode: "identity_not_found", serverMessage: nil)
        XCTAssertEqual(e404.code, .identityNotFound)

        let e429 = UseSenseError.fromHTTP(statusCode: 429, serverCode: nil, serverMessage: nil)
        XCTAssertEqual(e429.code, .quotaExceeded)

        let e500 = UseSenseError.fromHTTP(statusCode: 500, serverCode: nil, serverMessage: nil)
        XCTAssertEqual(e500.code, .serverError)

        let e503 = UseSenseError.fromHTTP(statusCode: 503, serverCode: nil, serverMessage: nil)
        XCTAssertEqual(e503.code, .serviceUnavailable)
    }

    func testIsRetryable() {
        let e500 = UseSenseError.fromHTTP(statusCode: 500, serverCode: nil, serverMessage: nil)
        XCTAssertTrue(e500.isRetryable)

        let e400 = UseSenseError.fromHTTP(statusCode: 400, serverCode: nil, serverMessage: nil)
        XCTAssertFalse(e400.isRetryable)

        let networkError = UseSenseError.networkError()
        XCTAssertTrue(networkError.isRetryable)

        let uploadFailed = UseSenseError.uploadFailed()
        XCTAssertTrue(uploadFailed.isRetryable)
    }

    func testFactoryMethods() {
        XCTAssertEqual(UseSenseError.cameraUnavailable().code, .cameraUnavailable)
        XCTAssertEqual(UseSenseError.networkTimeout().code, .networkTimeout)
        XCTAssertTrue(UseSenseError.networkTimeout().isRetryable)
        XCTAssertEqual(UseSenseError.sessionExpired().code, .sessionExpired)
        XCTAssertEqual(UseSenseError.encodingFailed().code, .encodingFailed)
        XCTAssertEqual(UseSenseError.invalidConfig("test").code, .invalidConfig)
        XCTAssertEqual(UseSenseError.quotaExceeded().code, .quotaExceeded)
    }
}

final class UseSenseResultTests: XCTestCase {
    func testRedactedDecision() {
        let redacted = RedactedDecisionObject(
            sessionId: "sess_123",
            sessionType: "enrollment",
            identityId: "id_456",
            decision: "APPROVE",
            timestamp: "2024-01-01T00:00:00Z"
        )
        XCTAssertEqual(redacted.sessionId, "sess_123")
        XCTAssertEqual(redacted.decision, "APPROVE")
    }

    func testDecisionHelpers() {
        let approved = RedactedDecisionObject(
            sessionId: "s1", sessionType: nil, identityId: nil,
            decision: "APPROVE", timestamp: "t"
        )
        XCTAssertTrue(approved.isApproved)
        XCTAssertFalse(approved.isRejected)
        XCTAssertFalse(approved.isPendingReview)

        let rejected = RedactedDecisionObject(
            sessionId: "s2", sessionType: nil, identityId: nil,
            decision: "REJECT", timestamp: "t"
        )
        XCTAssertTrue(rejected.isRejected)

        let review = RedactedDecisionObject(
            sessionId: "s3", sessionType: nil, identityId: nil,
            decision: "MANUAL_REVIEW", timestamp: "t"
        )
        XCTAssertTrue(review.isPendingReview)
    }

    func testDecisionEnum() {
        XCTAssertEqual(Decision.approve.rawValue, "APPROVE")
        XCTAssertEqual(Decision.reject.rawValue, "REJECT")
        XCTAssertEqual(Decision.manualReview.rawValue, "MANUAL_REVIEW")
    }

    func testSessionType() {
        XCTAssertEqual(SessionType.enrollment.rawValue, "enrollment")
        XCTAssertEqual(SessionType.authentication.rawValue, "authentication")
    }
}

final class ChallengeSpecTests: XCTestCase {
    func testChallengeTypes() {
        XCTAssertEqual(ChallengeType.followDot.rawValue, "follow_dot")
        XCTAssertEqual(ChallengeType.headTurn.rawValue, "head_turn")
        XCTAssertEqual(ChallengeType.speakPhrase.rawValue, "speak_phrase")
    }

    func testHeadTurnDecoding() throws {
        let json = """
        {
            "type": "head_turn",
            "seed": "abc123",
            "sequence": [
                {"direction": "left", "duration_ms": 1000, "index": 0},
                {"direction": "right", "duration_ms": 1000, "index": 1}
            ],
            "total_duration_ms": 2000
        }
        """
        let wrapper = try JSONDecoder().decode(ChallengeSpecWrapper.self, from: Data(json.utf8))
        XCTAssertEqual(wrapper.challengeType, .headTurn)
        XCTAssertEqual(wrapper.seed, "abc123")
        XCTAssertEqual(wrapper.totalDurationMs, 2000)

        if case .headTurn(let challenge) = wrapper {
            XCTAssertEqual(challenge.sequence.count, 2)
            XCTAssertEqual(challenge.sequence[0].direction, .left)
        } else {
            XCTFail("Expected headTurn")
        }
    }

    func testFollowDotDecoding() throws {
        let json = """
        {
            "type": "follow_dot",
            "seed": "xyz789",
            "waypoints": [
                {"x": 0.5, "y": 0.3, "duration_ms": 800, "index": 0}
            ],
            "dot_size_px": 20,
            "total_duration_ms": 3000
        }
        """
        let wrapper = try JSONDecoder().decode(ChallengeSpecWrapper.self, from: Data(json.utf8))
        XCTAssertEqual(wrapper.challengeType, .followDot)

        if case .followDot(let challenge) = wrapper {
            XCTAssertEqual(challenge.waypoints.count, 1)
            XCTAssertEqual(challenge.dotSizePx, 20)
        } else {
            XCTFail("Expected followDot")
        }
    }

    func testSpeakPhraseDecoding() throws {
        let json = """
        {
            "type": "speak_phrase",
            "seed": "def456",
            "phrase": "Hello world",
            "total_duration_ms": 5000
        }
        """
        let wrapper = try JSONDecoder().decode(ChallengeSpecWrapper.self, from: Data(json.utf8))
        XCTAssertEqual(wrapper.challengeType, .speakPhrase)

        if case .speakPhrase(let challenge) = wrapper {
            XCTAssertEqual(challenge.phrase, "Hello world")
        } else {
            XCTFail("Expected speakPhrase")
        }
    }

    func testUnknownChallengeType() {
        let json = """
        {"type": "unknown_type", "seed": "test"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ChallengeSpecWrapper.self, from: Data(json.utf8)))
    }
}

final class EventSystemTests: XCTestCase {
    func testEventEmission() {
        let emitter = EventEmitter()
        var received: [UseSenseEventType] = []

        _ = emitter.addListener { event in
            received.append(event.type)
        }

        emitter.emit(.sessionCreated)
        emitter.emit(.captureStarted, data: ["key": "value"])

        XCTAssertEqual(received, [.sessionCreated, .captureStarted])
    }

    func testListenerRemoval() {
        let emitter = EventEmitter()
        var count = 0

        let remove = emitter.addListener { _ in count += 1 }
        emitter.emit(.sessionCreated)
        XCTAssertEqual(count, 1)

        remove()
        emitter.emit(.captureStarted)
        XCTAssertEqual(count, 1)
    }

    func testEventData() {
        let event = UseSenseEvent(type: .uploadProgress, data: ["progress": "0.5"])
        XCTAssertEqual(event.type, .uploadProgress)
        XCTAssertEqual(event.data?["progress"], "0.5")
        XCTAssertNotNil(event.timestamp)
    }
}

final class SessionStateMachineTests: XCTestCase {
    func testCapturePhases() {
        XCTAssertEqual(CapturePhase.allCases.count, 6)
        XCTAssertEqual(CapturePhase.instructions.rawValue, "instructions")
        XCTAssertEqual(CapturePhase.done.rawValue, "done")
    }
}

final class MultipartFormDataTests: XCTestCase {
    func testMultipartConstruction() {
        var multipart = MultipartFormData()
        multipart.appendFile(
            name: "test",
            filename: "test.txt",
            contentType: "text/plain",
            data: Data("Hello".utf8)
        )
        let data = multipart.finalize()
        XCTAssertFalse(data.isEmpty)
        XCTAssertTrue(multipart.contentType.contains("multipart/form-data"))
        XCTAssertTrue(multipart.contentType.contains("boundary"))
    }
}

final class AnyCodableValueTests: XCTestCase {
    func testStringEncoding() throws {
        let value = AnyCodableValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        if case .string(let str) = decoded {
            XCTAssertEqual(str, "hello")
        } else {
            XCTFail("Expected string")
        }
    }

    func testIntEncoding() throws {
        let value = AnyCodableValue.int(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        if case .int(let num) = decoded {
            XCTAssertEqual(num, 42)
        } else {
            XCTFail("Expected int")
        }
    }

    func testBoolEncoding() throws {
        let value = AnyCodableValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        if case .bool(let b) = decoded {
            XCTAssertTrue(b)
        } else {
            XCTFail("Expected bool")
        }
    }
}

final class ChallengeResponseBuilderTests: XCTestCase {
    func testBuildResponse() {
        let builder = ChallengeResponseBuilder()
        builder.markStarted()
        builder.setCurrentStep(0)
        builder.recordFrame(frameIndex: 0, timestampMs: 100)
        builder.recordFrame(frameIndex: 1, timestampMs: 200)
        builder.setCurrentStep(1)
        builder.recordFrame(frameIndex: 2, timestampMs: 300)
        builder.markCompleted()

        let challenge = HeadTurnChallenge(
            type: "head_turn",
            seed: "test_seed",
            sequence: [],
            totalDurationMs: 2000,
            framesPerStep: nil,
            captureFpsHint: nil
        )
        let response = builder.build(challenge: .headTurn(challenge))

        XCTAssertEqual(response["type"] as? String, "head_turn")
        XCTAssertEqual(response["seed"] as? String, "test_seed")
        XCTAssertEqual(response["completed"] as? Bool, true)
        XCTAssertNotNil(response["step_frames"])
        XCTAssertNotNil(response["started_at"])
        XCTAssertNotNil(response["completed_at"])
    }

    func testReset() {
        let builder = ChallengeResponseBuilder()
        builder.markStarted()
        builder.setCurrentStep(0)
        builder.recordFrame(frameIndex: 0, timestampMs: 100)
        builder.reset()

        let challenge = FollowDotChallenge(
            type: "follow_dot",
            seed: "seed",
            waypoints: [],
            dotSizePx: 20,
            totalDurationMs: 1000,
            framesPerStep: nil,
            captureFpsHint: nil
        )
        let response = builder.build(challenge: .followDot(challenge))
        XCTAssertEqual(response["completed"] as? Bool, false)
        let timestamps = response["frame_timestamps"] as? [Int64]
        XCTAssertTrue(timestamps?.isEmpty ?? true)
    }
}

final class CreateSessionRequestTests: XCTestCase {
    func testEncoding() throws {
        let request = CreateSessionRequest(
            sessionType: "enrollment",
            identityId: nil,
            externalUserId: "user_123",
            metadata: ["key": .string("value")]
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["session_type"] as? String, "enrollment")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["external_user_id"] as? String, "user_123")
        XCTAssertNil(json["identity_id"])
    }
}

final class CreateSessionResponseTests: XCTestCase {
    func testDecoding() throws {
        let json = """
        {
            "session_id": "sess_123",
            "session_token": "token_abc",
            "expires_at": "2024-12-31T23:59:59.000Z",
            "nonce": "nonce_xyz",
            "policy": {
                "requires_audio": false,
                "requires_stepup": false,
                "challenge_type": "head_turn"
            },
            "upload": {
                "max_frames": 40,
                "target_fps": 15,
                "capture_duration_ms": 2500
            }
        }
        """
        let response = try JSONDecoder().decode(CreateSessionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.sessionId, "sess_123")
        XCTAssertEqual(response.sessionToken, "token_abc")
        XCTAssertEqual(response.nonce, "nonce_xyz")
        XCTAssertFalse(response.policy.requiresAudio)
        XCTAssertEqual(response.upload.maxFrames, 40)
        XCTAssertEqual(response.upload.targetFps, 15)
    }
}

final class UseSenseEntryPointTests: XCTestCase {
    func testSDKVersion() {
        XCTAssertFalse(UseSense.version.isEmpty)
    }

    func testCreateSDK() {
        let config = UseSenseConfig(apiKey: "test_key")
        let sdk = UseSense(config: config)
        XCTAssertEqual(sdk.sdkVersion, UseSense.version)
    }

    func testSDKVersionMatchesAndroid() {
        XCTAssertEqual(UseSense.version, "1.17.7")
    }

    func testVerificationRequest() {
        let request = VerificationRequest(
            sessionType: .enrollment,
            externalUserId: "user_123",
            identityId: nil,
            metadata: ["key": .string("value")]
        )
        XCTAssertEqual(request.sessionType, .enrollment)
        XCTAssertEqual(request.externalUserId, "user_123")
        XCTAssertNil(request.identityId)
    }

    func testDefaultGatewayKey() {
        XCTAssertFalse(UseSenseAPIClient.defaultGatewayKey.isEmpty)
    }

    func testEventEmitterClear() {
        let emitter = EventEmitter()
        var count = 0
        _ = emitter.addListener { _ in count += 1 }
        emitter.emit(.sessionCreated)
        XCTAssertEqual(count, 1)

        emitter.clear()
        emitter.emit(.captureStarted)
        XCTAssertEqual(count, 1)
    }
}

final class MetadataBuilderTests: XCTestCase {
    func testBuildMetadata() throws {
        let builder = MetadataBuilder()
        let channelIntegrity: [String: Any] = [
            "platform": "ios",
            "sdk_version": "1.17.7",
            "device_model": "iPhone15,2"
        ]
        let deviceTelemetry: [String: Any] = [
            "cpu_abi": "arm64",
            "processor_count": 6
        ]
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(2.5)

        let data = try builder.build(
            challengeResponse: nil,
            channelIntegrity: channelIntegrity,
            deviceTelemetry: deviceTelemetry,
            captureStartTime: startTime,
            captureEndTime: endTime,
            framesCaptured: 37,
            framesDropped: 3,
            avgFrameIntervalMs: 67
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["channel_integrity"])
        XCTAssertNotNil(json["device_telemetry"])

        let ci = json["channel_integrity"] as! [String: Any]
        XCTAssertEqual(ci["platform"] as? String, "ios")
        XCTAssertEqual(ci["frames_captured"] as? Int, 37)
        XCTAssertEqual(ci["frames_dropped"] as? Int, 3)
        XCTAssertNotNil(ci["capture_start_time"])
        XCTAssertNotNil(ci["capture_end_time"])
    }
}
