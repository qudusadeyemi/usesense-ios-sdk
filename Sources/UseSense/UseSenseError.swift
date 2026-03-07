import Foundation

public enum UseSenseErrorCode: String, CaseIterable, Sendable {
    case cameraPermissionDenied = "CAMERA_PERMISSION_DENIED"
    case micPermissionDenied = "MIC_PERMISSION_DENIED"
    case networkError = "NETWORK_ERROR"
    case sessionExpired = "SESSION_EXPIRED"
    case unauthorized = "UNAUTHORIZED"
    case invalidToken = "INVALID_TOKEN"
    case sessionNotFound = "SESSION_NOT_FOUND"
    case identityNotFound = "IDENTITY_NOT_FOUND"
    case invalidRequest = "INVALID_REQUEST"
    case quotaExceeded = "QUOTA_EXCEEDED"
    case userCancelled = "USER_CANCELLED"
    case faceNotDetected = "FACE_NOT_DETECTED"
    case lowLight = "LOW_LIGHT"
    case timeout = "TIMEOUT"
    case serverError = "SERVER_ERROR"
    case serviceUnavailable = "SERVICE_UNAVAILABLE"
    case unknownError = "UNKNOWN_ERROR"

    public var userMessage: String {
        switch self {
        case .cameraPermissionDenied: return "We need camera access to verify your identity. Please allow camera access in Settings."
        case .micPermissionDenied: return "We need microphone access to complete verification. Please allow microphone access in Settings."
        case .networkError: return "Connection issue. Please check your internet and try again."
        case .sessionExpired: return "Your session has expired. Please start over."
        case .unauthorized: return "Authentication failed. Please check your API key."
        case .invalidToken: return "Session token is invalid. Please start a new session."
        case .sessionNotFound: return "Session not found. Please start a new session."
        case .identityNotFound: return "Identity not found. Please ensure the identity ID is correct."
        case .invalidRequest: return "Invalid request. Please check the parameters."
        case .quotaExceeded: return "Rate limit reached. Please try again later."
        case .userCancelled: return "Verification was cancelled."
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

    public var errorDescription: String? { message }

    public init(code: UseSenseErrorCode, message: String? = nil, details: String? = nil) {
        self.code = code
        self.message = message ?? code.userMessage
        self.details = details
    }

    static func fromHTTP(statusCode: Int, serverCode: String?, serverMessage: String?) -> UseSenseError {
        let code: UseSenseErrorCode
        switch statusCode {
        case 400: code = .invalidRequest
        case 401:
            switch serverCode {
            case "session_expired": code = .sessionExpired
            case "invalid_token": code = .invalidToken
            default: code = .unauthorized
            }
        case 404: code = serverCode == "identity_not_found" ? .identityNotFound : .sessionNotFound
        case 429: code = .quotaExceeded
        case 503: code = .serviceUnavailable
        default: code = statusCode >= 500 ? .serverError : .unknownError
        }
        return UseSenseError(code: code, message: serverMessage, details: serverCode)
    }
}
