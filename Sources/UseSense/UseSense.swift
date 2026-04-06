import Foundation

/// Main entry point for the UseSense SDK.
/// UseSense is human presence infrastructure for the AI era.
public final class UseSense: @unchecked Sendable {
    public static let version = "4.1.0"

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
