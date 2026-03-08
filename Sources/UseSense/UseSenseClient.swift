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

    /// Start verification with a request object (matches Android's startVerification).
    func startVerification(request: VerificationRequest) -> UseSenseSession

    /// Register an event listener for all sessions.
    @discardableResult
    func onEvent(_ callback: @escaping EventCallback) -> () -> Void

    /// Register an event listener for all sessions.
    @discardableResult
    func addEventListener(_ callback: @escaping EventCallback) -> () -> Void

    /// Clear all event listeners and reset state.
    func reset()

    /// Get the current SDK version.
    var sdkVersion: String { get }
}
