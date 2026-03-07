import Foundation

/// Main entry point for the UseSense SDK.
public final class UseSense: UseSenseClientProtocol, @unchecked Sendable {
    public static let version = "1.0.0"

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

    /// Register a global event listener.
    /// - Parameter callback: Closure invoked for each SDK event.
    /// - Returns: A removal function. Call it to unsubscribe.
    public func addEventListener(_ callback: @escaping EventCallback) -> () -> Void {
        globalEventEmitter.addListener(callback)
    }
}
