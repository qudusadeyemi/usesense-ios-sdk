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
    /// The capture did not reach the upload within its budget (a challenge
    /// that never completed, a hung device call). Retryable.
    case captureTimeout = "CAPTURE_TIMEOUT"
    /// The signals upload or the complete call did not finish within its
    /// budget, or stopped making progress. Retryable.
    case uploadTimeout = "UPLOAD_TIMEOUT"
    /// The camera ran but no usable frame reached the buffer. A system or
    /// capture failure, never a verdict. Retryable. Same wire code as Android.
    case noFramesCaptured = "NO_FRAMES_CAPTURED"
    /// The server answered, but the response couldn't be read. Not retryable:
    /// asking again returns the same body.
    case responseInvalid = "RESPONSE_INVALID"
    case serverError = "SERVER_ERROR"
    case serviceUnavailable = "SERVICE_UNAVAILABLE"
    case tokenExpired = "TOKEN_EXPIRED"
    case tokenAlreadyUsed = "TOKEN_ALREADY_USED"
    case insufficientCredits = "INSUFFICIENT_CREDITS"
    case nonceMismatch = "NONCE_MISMATCH"
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
        case .captureTimeout: return "The capture took too long to finish. Please try again."
        case .uploadTimeout: return "We couldn't send your verification in time. Check your connection and try again."
        case .noFramesCaptured: return "The camera did not return any images. Please try again."
        case .responseInvalid: return "We couldn't read the verification result. Please try again later."
        case .serverError: return "Server error. Please try again or contact support."
        case .serviceUnavailable: return "Service unavailable. Try again later."
        case .tokenExpired: return "Verification token has expired. Please start over."
        case .tokenAlreadyUsed: return "This verification token has already been used."
        case .insufficientCredits: return "Service temporarily unavailable. Please try again later."
        case .nonceMismatch: return "Session verification failed. Please start a new session."
        case .unknownError: return "Something went wrong. Please try again."
        }
    }
}

/// What the person being verified sees for an error: a title and a body
/// chosen from the error's code, never the server's or the system's raw text
/// (that goes to the host callback and logs). Same buckets as Android.
struct SubjectErrorCopy: Equatable {
    let title: String
    let body: String

    static let connection = SubjectErrorCopy(
        title: "Connection problem",
        body: "We couldn't reach the server. Check your internet connection and try again.")
    static let capture = SubjectErrorCopy(
        title: "We couldn't see your face clearly",
        body: "Find a well-lit spot, hold your phone at eye level and keep your face inside the frame, then try again.")
    static let expired = SubjectErrorCopy(
        title: "This session has expired",
        body: "Please go back and start the verification again.")
    static let unavailable = SubjectErrorCopy(
        title: "Verification is unavailable",
        body: "Please try again later.")
    static let generic = SubjectErrorCopy(
        title: "Something went wrong",
        body: "We couldn't finish your check. Please try again.")

    static func forError(_ error: UseSenseError) -> SubjectErrorCopy {
        switch error.code {
        case .networkError, .networkTimeout, .uploadFailed, .uploadTimeout, .timeout:
            return .connection
        case .captureFailed, .captureTimeout, .noFramesCaptured, .encodingFailed, .faceNotDetected, .lowLight:
            return .capture
        case .sessionExpired, .tokenExpired, .invalidToken, .sessionNotFound, .nonceMismatch, .tokenAlreadyUsed:
            return .expired
        // An integration problem (bad key, config, credits, rate limit, outage):
        // nothing the subject can fix, so no capture advice.
        case .unauthorized, .invalidConfig, .insufficientCredits, .quotaExceeded, .serviceUnavailable:
            return .unavailable
        case .cameraUnavailable:
            return SubjectErrorCopy(title: "Camera unavailable", body: UseSenseErrorCode.cameraUnavailable.userMessage)
        case .cameraPermissionDenied:
            return SubjectErrorCopy(title: "Camera access needed", body: UseSenseErrorCode.cameraPermissionDenied.userMessage)
        case .micPermissionDenied:
            return SubjectErrorCopy(title: "Microphone access needed", body: UseSenseErrorCode.micPermissionDenied.userMessage)
        case .userCancelled:
            return SubjectErrorCopy(title: "Cancelled", body: UseSenseErrorCode.userCancelled.userMessage)
        default:
            return .generic
        }
    }

    /// The code shown as a caption: ours, plus the server's when it sent one.
    static func caption(for error: UseSenseError) -> String {
        if let server = error.details, !server.isEmpty, server.count <= 64,
           server.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           server.uppercased() != error.code.rawValue {
            return "Error code: \(error.code.rawValue) (\(server))"
        }
        return "Error code: \(error.code.rawValue)"
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
            case "nonce_mismatch": code = .nonceMismatch
            default: code = .unauthorized
            }
            retryable = false
        case 402:
            code = .insufficientCredits
            retryable = false
        case 403:
            code = .unauthorized
            retryable = false
        case 404:
            code = serverCode == "identity_not_found" ? .identityNotFound : .sessionNotFound
            retryable = false
        case 409:
            code = .tokenAlreadyUsed
            retryable = false
        case 410:
            code = serverCode == "token_expired" ? .tokenExpired : .sessionExpired
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
