import Foundation

/// Main entry point for the UseSense SDK.
/// Matches Android's UseSense singleton pattern with `initialize()` and `startVerification()`.
public final class UseSense: @unchecked Sendable {
    public static let version = "1.17.57"

    private let config: UseSenseConfig
    private let globalEventEmitter = EventEmitter()

    public var sdkVersion: String { Self.version }

    /// Initialize the UseSense SDK with configuration.
    public init(config: UseSenseConfig) {
        self.config = config
    }

    /// Create a new verification session.
    /// - Parameters:
    ///   - type: The session type (enrollment or authentication).
    ///   - identityId: Optional identity ID for authentication sessions.
    ///   - externalUserId: Optional external user ID.
    ///   - metadata: Optional metadata to attach to the session.
    /// - Returns: A configured `UseSenseSession` ready to be presented.
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

    /// Start verification using a VerificationRequest (matches Android's startVerification pattern).
    /// - Parameter request: The verification request with session type and parameters.
    /// - Returns: A configured `UseSenseSession` ready to be presented.
    public func startVerification(request: VerificationRequest) -> UseSenseSession {
        return createSession(
            type: request.sessionType,
            identityId: request.identityId,
            externalUserId: request.externalUserId,
            metadata: request.metadata
        )
    }

    /// Register a global event listener (matches Android's onEvent pattern).
    /// - Parameter callback: Closure invoked for each SDK event.
    /// - Returns: A removal function. Call it to unsubscribe.
    @discardableResult
    public func onEvent(_ callback: @escaping EventCallback) -> () -> Void {
        globalEventEmitter.addListener(callback)
    }

    /// Register a global event listener.
    /// - Parameter callback: Closure invoked for each SDK event.
    /// - Returns: A removal function. Call it to unsubscribe.
    @discardableResult
    public func addEventListener(_ callback: @escaping EventCallback) -> () -> Void {
        globalEventEmitter.addListener(callback)
    }

    /// Clear all event listeners (matches Android's reset pattern).
    public func reset() {
        globalEventEmitter.clear()
    }
}
