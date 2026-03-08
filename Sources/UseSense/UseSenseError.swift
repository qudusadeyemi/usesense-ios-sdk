import Foundation

public enum UseSenseErrorCode: String, CaseIterable, Sendable {
    case cameraUnavailable = "CAMERA_UNAVAILABLE"
    case cameraPermissionDenied = "CAMERA_PERMISSION_DENIED"
    case micPermissionDenied = "MIC_PERMISSION_DENIED"
    case networkError = "NETWORK_ERROR"
    case networkTimeout = "NETWORK_TIMEOUT"
    case sessionExpired = "SESSION_EXPIRED"
    case unauthorized = "UNAUTHORIZED"
    case invalidToken = "INVALID_TOKEN"
    case sessionNotFound = "SESSION_NOT_FOUND"
    case identityNotFound = "IDENTITY_NOT_FOUND"
    case invalidRequest = "INVALID_REQUEST"
    case invalidConfig = "INVALID_CONFIG"
    case quotaExceeded = "QUOTA_EXCEEDED"
    case userCancelled = "USER_CANCELLED"
    case captureFailed = "CAPTURE_FAILED"
    case encodingFailed = "ENCODING_FAILED"
    case uploadFailed = "UPLOAD_FAILED"
    case faceNotDetected = "FACE_NOT_DETECTED"
    case lowLight = "LOW_LIGHT"
    case timeout = "TIMEOUT"
    case serverError = "SERVER_ERROR"
    case serviceUnavailable = "SERVICE_UNAVAILABLE"
    case unknownError = "UNKNOWN_ERROR"

    public var userMessage: String {
        switch self {
        case .cameraUnavailable: return "Front camera is not available on this device."
        case .cameraPermissionDenied: return "We need camera access to verify your identity. Please allow camera access in Settings."
        case .micPermissionDenied: return "We need microphone access to complete verification. Please allow microphone access in Settings."
        case .networkError: return "Connection issue. Please check your internet and try again."
        case .networkTimeout: return "Request timed out. Please try again."
        case .sessionExpired: return "Your session has expired. Please start over."
        case .unauthorized: return "Authentication failed. Please check your API key."
        case .invalidToken: return "Session token is invalid. Please start a new session."
        case .sessionNotFound: return "Session not found. Please start a new session."
        case .identityNotFound: return "Identity not found. Please ensure the identity ID is correct."
        case .invalidRequest: return "Invalid request. Please check the parameters."
        case .invalidConfig: return "Invalid configuration."
        case .quotaExceeded: return "Rate limit reached. Please try again later."
        case .userCancelled: return "Verification was cancelled."
        case .captureFailed: return "Frame capture failed."
        case .encodingFailed: return "JPEG frame encoding failed."
        case .uploadFailed: return "Signal upload failed after retries."
        case .faceNotDetected: return "Please position your face in the frame and try again."
        case .lowLight: return "Lighting is too low. Please move to a brighter area."
        case .timeout: return "Verification took too long. Please try again."
        case .serverError: return "Server error. Please try again or contact support."
        case .serviceUnavailable: return "Service unavailable. Try again later."
        case .unknownError: return "Something went wrong. Please try again."
        }
    }
}

public struct UseSenseError: Error, LocalizedError, Sendable {
    public let code: UseSenseErrorCode
    public let message: String
    public let details: String?
    public let isRetryable: Bool

    public var errorDescription: String? { message }

    public init(code: UseSenseErrorCode, message: String? = nil, details: String? = nil, isRetryable: Bool = false) {
        self.code = code
        self.message = message ?? code.userMessage
        self.details = details
        self.isRetryable = isRetryable
    }

    // MARK: - Factory Methods

    public static func cameraUnavailable() -> UseSenseError {
        UseSenseError(code: .cameraUnavailable)
    }

    public static func cameraPermissionDenied() -> UseSenseError {
        UseSenseError(code: .cameraPermissionDenied)
    }

    public static func microphonePermissionDenied() -> UseSenseError {
        UseSenseError(code: .micPermissionDenied)
    }

    public static func networkError(_ cause: String? = nil) -> UseSenseError {
        UseSenseError(code: .networkError, message: cause, isRetryable: true)
    }

    public static func networkTimeout() -> UseSenseError {
        UseSenseError(code: .networkTimeout, isRetryable: true)
    }

    public static func sessionExpired() -> UseSenseError {
        UseSenseError(code: .sessionExpired)
    }

    public static func uploadFailed() -> UseSenseError {
        UseSenseError(code: .uploadFailed, isRetryable: true)
    }

    public static func captureFailed(_ cause: String? = nil) -> UseSenseError {
        UseSenseError(code: .captureFailed, message: cause)
    }

    public static func encodingFailed() -> UseSenseError {
        UseSenseError(code: .encodingFailed)
    }

    public static func invalidConfig(_ detail: String) -> UseSenseError {
        UseSenseError(code: .invalidConfig, message: "Invalid configuration: \(detail)")
    }

    public static func quotaExceeded() -> UseSenseError {
        UseSenseError(code: .quotaExceeded, details: "QUOTA_EXCEEDED")
    }

    // MARK: - HTTP Mapping

    public static func fromHTTP(statusCode: Int, serverCode: String?, serverMessage: String?) -> UseSenseError {
        let code: UseSenseErrorCode
        let retryable: Bool
        switch statusCode {
        case 400:
            code = .invalidRequest
            retryable = false
        case 401:
            switch serverCode {
            case "session_expired": code = .sessionExpired
            case "invalid_token": code = .invalidToken
            default: code = .unauthorized
            }
            retryable = false
        case 404:
            code = serverCode == "identity_not_found" ? .identityNotFound : .sessionNotFound
            retryable = false
        case 429:
            code = .quotaExceeded
            retryable = false
        case 500, 503:
            code = statusCode == 503 ? .serviceUnavailable : .serverError
            retryable = true
        default:
            code = statusCode >= 500 ? .serverError : .unknownError
            retryable = statusCode >= 500
        }

        let userMessage = serverMessage ?? code.userMessage
        return UseSenseError(code: code, message: userMessage, details: serverCode, isRetryable: retryable)
    }
}
