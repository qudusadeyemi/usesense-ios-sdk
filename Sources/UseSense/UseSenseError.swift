import Foundation

public enum UseSenseErrorCode: Int, Sendable {
    // Camera
    case cameraUnavailable = 1001
    case cameraPermissionDenied = 1002
    case microphonePermissionDenied = 1003

    // Network
    case networkError = 2001
    case networkTimeout = 2002

    // Session
    case sessionExpired = 3001
    case uploadFailed = 3002
    case sessionCreationFailed = 3003

    // Capture
    case captureFailed = 4001
    case encodingFailed = 4002
    case noFramesCaptured = 4003

    // Configuration
    case invalidConfig = 5001
    case missingApiKey = 5002
}

public struct UseSenseError: Error, LocalizedError, Sendable {
    public let code: UseSenseErrorCode
    public let serverCode: String?
    public let message: String
    public let isRetryable: Bool
    public let underlyingError: (any Error)?

    public var errorDescription: String? { message }

    public init(
        code: UseSenseErrorCode,
        serverCode: String? = nil,
        message: String,
        isRetryable: Bool = false,
        underlyingError: (any Error)? = nil
    ) {
        self.code = code
        self.serverCode = serverCode
        self.message = message
        self.isRetryable = isRetryable
        self.underlyingError = underlyingError
    }

    static func cameraUnavailable() -> UseSenseError {
        UseSenseError(code: .cameraUnavailable, message: "Front camera is not available on this device.")
    }

    static func cameraPermissionDenied() -> UseSenseError {
        UseSenseError(code: .cameraPermissionDenied, message: "Camera permission was denied. Please enable camera access in Settings.")
    }

    static func microphonePermissionDenied() -> UseSenseError {
        UseSenseError(code: .microphonePermissionDenied, message: "Microphone permission was denied. Please enable microphone access in Settings.")
    }

    static func sessionExpired() -> UseSenseError {
        UseSenseError(code: .sessionExpired, serverCode: "session_expired", message: "The verification session has expired. Please try again.")
    }

    static func networkError(_ error: Error) -> UseSenseError {
        UseSenseError(code: .networkError, message: "A network error occurred.", isRetryable: true, underlyingError: error)
    }

    static func networkTimeout() -> UseSenseError {
        UseSenseError(code: .networkTimeout, message: "The request timed out.", isRetryable: true)
    }

    static func serverError(code: String, message: String, isRetryable: Bool = false) -> UseSenseError {
        UseSenseError(code: .sessionCreationFailed, serverCode: code, message: message, isRetryable: isRetryable)
    }
}
