import Foundation

/// Main entry point for the UseSense SDK.
/// UseSense is human presence infrastructure for the AI era.
public final class UseSense: @unchecked Sendable {
    public static let version = "4.5.0"

    private let config: UseSenseConfig
    private let globalEventEmitter = EventEmitter()

    public var sdkVersion: String { Self.version }

    /// Initialize the UseSense SDK with configuration.
    public init(config: UseSenseConfig) {
        self.config = config
    }

    /// Create a new verification session (Standard Init).
    /// Your backend calls POST /v1/sessions, then passes credentials to the client.
    public func createSession(
        type: SessionType,
        identityId: String? = nil,
        externalUserId: String? = nil,
        metadata: [String: AnyCodableValue]? = nil
    ) -> UseSenseSession {
        return UseSenseSession(
            config: config,
            sessionType: type,
            identityId: identityId,
            externalUserId: externalUserId,
            metadata: metadata,
            eventEmitter: globalEventEmitter
        )
    }

    /// Start verification using a VerificationRequest.
    public func startVerification(request: VerificationRequest) -> UseSenseSession {
        return createSession(
            type: request.sessionType,
            identityId: request.identityId,
            externalUserId: request.externalUserId,
            metadata: request.metadata
        )
    }

    /// Start a LiveSense v4 session. Phase 1 ticket I-2.
    ///
    /// v4 runs the perspective-distortion zoom-motion capture. Returns
    /// a LiveSenseV4Session the caller must `.start()` from the main
    /// thread. The delegate receives phase updates and the final
    /// opaque V4Verdict (or error) asynchronously.
    ///
    /// v3 `startVerification` and `createSessionWithToken` are unaffected.
    public func startV4Session(
        config v4Config: LiveSenseV4Config,
        delegate: LiveSenseV4Delegate? = nil
    ) -> LiveSenseV4Session {
        return LiveSenseV4Session(config: v4Config, delegate: delegate)
    }

    /// Create a session via Server-Side Init (token exchange).
    /// Your backend calls POST /v1/sessions/create-token, passes the client_token
    /// to the SDK, which exchanges it for full session credentials.
    ///
    /// Use this when you need:
    /// 1. Reference image matching (KYC, ID verification)
    /// 2. Zero credential exposure (sk_* never in client)
    public func createSessionWithToken(
        clientToken: String,
        sessionType: SessionType = .authentication
    ) -> UseSenseSession {
        return UseSenseSession(
            config: config,
            sessionType: sessionType,
            clientToken: clientToken,
            eventEmitter: globalEventEmitter
        )
    }

    /// Register a global event listener.
    @discardableResult
    public func onEvent(_ callback: @escaping EventCallback) -> () -> Void {
        globalEventEmitter.addListener(callback)
    }

    /// Register a global event listener.
    @discardableResult
    public func addEventListener(_ callback: @escaping EventCallback) -> () -> Void {
        globalEventEmitter.addListener(callback)
    }

    /// Clear all event listeners.
    public func reset() {
        globalEventEmitter.clear()
    }
}
