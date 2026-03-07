import Foundation

/// Protocol defining the public interface for the UseSense SDK.
/// Enables mocking and testing.
public protocol UseSenseClientProtocol: AnyObject, Sendable {
    /// Create a new verification session.
    func createSession(
        type: SessionType,
        identityId: String?,
        externalUserId: String?,
        metadata: [String: AnyCodableValue]?
    ) -> UseSenseSession

    /// Register an event listener for all sessions.
    func addEventListener(_ callback: @escaping EventCallback) -> () -> Void

    /// Get the current SDK version.
    var sdkVersion: String { get }
}
