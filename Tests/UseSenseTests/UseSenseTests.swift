import XCTest
@testable import UseSenseSDK

final class UseSenseConfigTests: XCTestCase {
    func testDefaultConfig() {
        let config = UseSenseConfig(apiKey: "sk_sandbox_123")
        XCTAssertEqual(config.apiEndpoint, UseSenseConfig.defaultEndpoint)
        XCTAssertEqual(config.apiEndpoint, "https://api.usesense.ai/v1")
        XCTAssertEqual(config.apiKey, "sk_sandbox_123")
        XCTAssertEqual(config.environment, .sandbox)
    }

    func testProductionDetection() {
        let config = UseSenseConfig(apiKey: "pk_prod_abc")
        XCTAssertEqual(config.environment, .production)
    }

    func testSecretKeyProductionDetection() {
        let config = UseSenseConfig(apiKey: "sk_prod_abc")
        XCTAssertEqual(config.environment, .production)
    }

    func testSandboxDetection() {
        let config = UseSenseConfig(apiKey: "sk_sandbox_key")
        XCTAssertEqual(config.environment, .sandbox)
    }

    func testPublishableSandboxDetection() {
        let config = UseSenseConfig(apiKey: "pk_sandbox_key")
        XCTAssertEqual(config.environment, .sandbox)
    }

    func testDkPrefixProductionDetection() {
        let config = UseSenseConfig(apiKey: "dk_prod_key")
        XCTAssertEqual(config.environment, .production)
    }

    func testDkPrefixSandboxDetection() {
        let config = UseSenseConfig(apiKey: "dk_sandbox_key")
        XCTAssertEqual(config.environment, .sandbox)
    }

    func testUnknownKeyDefaultsToProduction() {
        let config = UseSenseConfig(apiKey: "unknown_key")
        XCTAssertEqual(config.environment, .production)
    }

    func testAutoEnvironmentResolution() {
        let auto = Environment.auto
        XCTAssertEqual(auto.resolved(apiKey: "pk_prod_live"), "production")
        XCTAssertEqual(auto.resolved(apiKey: "sk_sandbox_test"), "sandbox")
        XCTAssertEqual(auto.resolved(apiKey: "dk_prod_dev"), "production")
    }

    func testCustomConfig() {
        let config = UseSenseConfig(
            apiEndpoint: "https://custom.api.com",
            apiKey: "sk_prod_key",
            environment: .production,
            options: SDKOptions(audioEnabled: .always, targetFps: 5, maxFrames: 25)
        )
        XCTAssertEqual(config.apiEndpoint, "https://custom.api.com")
        XCTAssertEqual(config.environment, .production)
        XCTAssertEqual(config.options?.targetFps, 5)
        XCTAssertEqual(config.options?.maxFrames, 25)
    }

    func testDefaultSDKOptions() {
        let options = SDKOptions()
        XCTAssertEqual(options.captureDurationMs, 8000)
        XCTAssertEqual(options.targetFps, 3)
        XCTAssertEqual(options.maxFrames, 30)
        XCTAssertEqual(options.maxUploadSizeMb, 10)
        XCTAssertEqual(options.audioEnabled, .riskBased)
    }

    func testDefaultBrandingConfig() {
        let branding = BrandingConfig()
        XCTAssertEqual(branding.primaryColor, "#4F7CFF")
        XCTAssertEqual(branding.buttonRadius, 10)
    }

    func testStagingEndpoint() {
        XCTAssertEqual(UseSenseConfig.stagingEndpoint, "https://staging.api.usesense.ai/v1")
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

        let e401Nonce = UseSenseError.fromHTTP(statusCode: 401, serverCode: "nonce_mismatch", serverMessage: nil)
        XCTAssertEqual(e401Nonce.code, .nonceMismatch)

        let e401Default = UseSenseError.fromHTTP(statusCode: 401, serverCode: nil, serverMessage: nil)
        XCTAssertEqual(e401Default.code, .unauthorized)

        let e402 = UseSenseError.fromHTTP(statusCode: 402, serverCode: nil, serverMessage: nil)
        XCTAssertEqual(e402.code, .insufficientCredits)

        let e404 = UseSenseError.fromHTTP(statusCode: 404, serverCode: "identity_not_found", serverMessage: nil)
        XCTAssertEqual(e404.code, .identityNotFound)

        let e409 = UseSenseError.fromHTTP(statusCode: 409, serverCode: nil, serverMessage: nil)
        XCTAssertEqual(e409.code, .tokenAlreadyUsed)

        let e410 = UseSenseError.fromHTTP(statusCode: 410, serverCode: "token_expired", serverMessage: nil)
        XCTAssertEqual(e410.code, .tokenExpired)

        let e410Session = UseSenseError.fromHTTP(statusCode: 410, serverCode: "session_expired", serverMessage: nil)
        XCTAssertEqual(e410Session.code, .sessionExpired)

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

    func testNewErrorCodeMessages() {
        let tokenExpired = UseSenseError(code: .tokenExpired)
        XCTAssertFalse(tokenExpired.message.isEmpty)

        let tokenUsed = UseSenseError(code: .tokenAlreadyUsed)
        XCTAssertFalse(tokenUsed.message.isEmpty)

        let credits = UseSenseError(code: .insufficientCredits)
        XCTAssertFalse(credits.message.isEmpty)

        let nonce = UseSenseError(code: .nonceMismatch)
        XCTAssertFalse(nonce.message.isEmpty)
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
            timestamp: "2026-04-06T00:00:00Z"
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

    func testNewEventTypes() {
        // Verify new v4.1 event types exist
        XCTAssertEqual(UseSenseEventType.stepUpTriggered.rawValue, "step_up_triggered")
        XCTAssertEqual(UseSenseEventType.stepUpCompleted.rawValue, "step_up_completed")
    }
}

final class SessionStateMachineTests: XCTestCase {
    func testCapturePhases() {
        // v4.1 added inlineStepUp; v4 added the zoom-motion phase
        XCTAssertEqual(CapturePhase.allCases.count, 13)
        XCTAssertEqual(CapturePhase.instructions.rawValue, "instructions")
        XCTAssertEqual(CapturePhase.zoom.rawValue, "zoom")
        XCTAssertEqual(CapturePhase.inlineStepUp.rawValue, "inline-step-up")
        XCTAssertEqual(CapturePhase.done.rawValue, "done")
    }
}

final class CreateSessionResponseTests: XCTestCase {
    func testDecoding() throws {
        let json = """
        {
            "session_id": "sess_123",
            "session_token": "token_abc",
            "expires_at": "2026-12-31T23:59:59.000Z",
            "nonce": "nonce_xyz",
            "policy": {
                "requires_audio": false,
                "requires_stepup": false,
                "challenge_type": "head_turn"
            },
            "upload": {
                "max_frames": 30,
                "target_fps": 3,
                "capture_duration_ms": 8000
            }
        }
        """
        let response = try JSONDecoder().decode(CreateSessionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.sessionId, "sess_123")
        XCTAssertEqual(response.sessionToken, "token_abc")
        XCTAssertEqual(response.nonce, "nonce_xyz")
        XCTAssertFalse(response.policy.requiresAudio)
        XCTAssertEqual(response.upload.maxFrames, 30)
        XCTAssertEqual(response.upload.targetFps, 3)
        XCTAssertEqual(response.upload.captureDurationMs, 8000)
        XCTAssertNil(response.geometricCoherence)
    }

    func testDecodingWithGeometricCoherence() throws {
        let json = """
        {
            "session_id": "sess_456",
            "session_token": "token_def",
            "expires_at": "2026-12-31T23:59:59.000Z",
            "nonce": "nonce_abc",
            "policy": {
                "requires_audio": false,
                "requires_stepup": true,
                "challenge_type": "follow_dot",
                "inline_step_up": {
                    "enabled": true,
                    "suspicion_threshold": 55,
                    "preferred_challenge": "auto"
                }
            },
            "upload": {
                "max_frames": 30,
                "target_fps": 3,
                "capture_duration_ms": 8000
            },
            "geometric_coherence": {
                "dual_path_enabled": true,
                "screen_illumination_enabled": true,
                "on_device_3dmm_required": false,
                "mesh_binding_challenge": "a1b2c3d4e5f6"
            }
        }
        """
        let response = try JSONDecoder().decode(CreateSessionResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(response.geometricCoherence)
        XCTAssertTrue(response.geometricCoherence!.dualPathEnabled)
        XCTAssertTrue(response.geometricCoherence!.screenIlluminationEnabled)
        XCTAssertFalse(response.geometricCoherence!.onDevice3dmmRequired)
        XCTAssertEqual(response.geometricCoherence!.meshBindingChallenge, "a1b2c3d4e5f6")

        XCTAssertNotNil(response.policy.inlineStepUp)
        XCTAssertTrue(response.policy.inlineStepUp!.enabled)
        XCTAssertEqual(response.policy.inlineStepUp!.suspicionThreshold, 55)
        XCTAssertEqual(response.policy.inlineStepUp!.preferredChallenge, "auto")
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

final class UseSenseEntryPointTests: XCTestCase {
    func testSDKVersion() {
        XCTAssertFalse(UseSense.version.isEmpty)
    }

    func testSDKVersionIs4_4() {
        XCTAssertEqual(UseSense.version, "4.4.0")
    }

    func testAPIClientVersion() {
        XCTAssertEqual(UseSenseAPIClient.sdkVersion, "4.4.0")
    }

    func testCreateSDK() {
        let config = UseSenseConfig(apiKey: "pk_prod_test")
        let sdk = UseSense(config: config)
        XCTAssertEqual(sdk.sdkVersion, UseSense.version)
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
            "sdk_version": "4.4.0",
            "device_model": "iPhone15,2"
        ]
        let deviceTelemetry: [String: Any] = [
            "cpu_abi": "arm64",
            "processor_count": 6
        ]
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(8.0)

        let data = try builder.build(
            captureStartTime: startTime,
            captureEndTime: endTime,
            framesCaptured: 24,
            framesDropped: 0,
            avgFrameIntervalMs: 333,
            challengeResponse: nil,
            channelIntegrity: channelIntegrity,
            deviceTelemetry: deviceTelemetry
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["sdk_version"] as? String, "4.4.0")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertNotNil(json["channel_integrity"])
        XCTAssertNotNil(json["device_telemetry"])
        XCTAssertNotNil(json["timestamps"])

        let ci = json["channel_integrity"] as! [String: Any]
        XCTAssertEqual(ci["platform"] as? String, "ios")
        XCTAssertEqual(ci["frames_captured"] as? Int, 24)
        XCTAssertEqual(ci["frames_dropped"] as? Int, 0)
        XCTAssertNotNil(ci["capture_start_time"])
        XCTAssertNotNil(ci["capture_end_time"])
    }

    func testBuildMetadataWithV41Fields() throws {
        let builder = MetadataBuilder()
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(8.0)

        let suspicion: [String: Any] = [
            "final_score": 42.0,
            "triggered": false
        ]

        let screenDetection: [String: Any] = [
            "luminance_histogram_spread": 0.42,
            "edge_energy_ratio": 0.55,
            "frame_luminance_cv": 0.038,
            "color_channel_uniformity": 0.72
        ]

        let data = try builder.build(
            sessionId: "sess_test",
            captureStartTime: startTime,
            captureEndTime: endTime,
            frameHashes: ["abc123", "def456"],
            framesCaptured: 2,
            framesDropped: 0,
            avgFrameIntervalMs: 333,
            challengeResponse: nil,
            channelIntegrity: ["channel_type": "ios"],
            deviceTelemetry: [:],
            screenDetection: screenDetection,
            suspicion: suspicion
        )

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["session_id"] as? String, "sess_test")
        XCTAssertNotNil(json["suspicion"])
        XCTAssertNotNil(json["frame_hashes"])

        let hashes = json["frame_hashes"] as? [String]
        XCTAssertEqual(hashes?.count, 2)

        let ci = json["channel_integrity"] as! [String: Any]
        XCTAssertNotNil(ci["screen_detection"])

        let sd = ci["screen_detection"] as! [String: Any]
        XCTAssertEqual(sd["luminance_histogram_spread"] as? Double, 0.42)
    }
}
