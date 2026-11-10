import Foundation

enum PermissionType: Sendable { case camera, microphone }

/// Capture phase enum matching the spec state machine exactly.
public enum CapturePhase: String, CaseIterable, Sendable {
    case initializing    = "initializing"
    case cameraRequest   = "camera-request"
    case cameraError     = "camera-error"
    case instructions    = "instructions"
    case faceGuide       = "face-guide"
    case baseline        = "baseline"
    case zoom            = "zoom"
    case countdown       = "countdown"
    case challenge       = "challenge"
    case inlineStepUp    = "inline-step-up"
    case uploading       = "uploading"
    case completing      = "completing"
    case done            = "done"
}

enum SessionState: Sendable {
    case idle
    case created(session: SessionData)
    case permissionsRequired(permissions: [PermissionType])
    case cameraError(message: String)
    case instructions(challenge: ChallengeSpecWrapper)
    case faceGuide
    case baseline(remaining: TimeInterval)
    case zoom(progressFraction: Double)
    case countdown(number: Int)
    case challenge(spec: ChallengeSpecWrapper)
    /// Guided capture: the server asked for an extra check after the scan
    /// ("One more quick check" sheet, waiting for Continue).
    case extraCheckIntro(spec: ChallengeSpecWrapper)
    /// Guided capture: the extra check finished (short green tick).
    case extraCheckDone
    /// Guided capture, Speak Digits: the microphone was refused or has no
    /// input. Offers Settings or a head movement instead.
    case micUnavailable
    case inlineStepUp(phase: String)
    case uploading(progress: Double)
    case completing
    case done(decision: RedactedDecisionObject)
    case error(UseSenseError)
}

extension SessionState {
    /// The attempt is over: a decision, an error, or a camera failure.
    var isTerminal: Bool {
        switch self {
        case .done, .error, .cameraError: return true
        default: return false
        }
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    /// Frames are being captured or a challenge is on screen.
    var isCaptureInProgress: Bool {
        switch self {
        case .baseline, .zoom, .countdown, .challenge, .inlineStepUp, .extraCheckDone: return true
        default: return false
        }
    }

    /// Stable, PII-free name for diagnostics.
    var debugName: String {
        switch self {
        case .idle: return "idle"
        case .created: return "created"
        case .permissionsRequired: return "permissions_required"
        case .cameraError: return "camera_error"
        case .instructions: return "instructions"
        case .faceGuide: return "face_guide"
        case .baseline: return "baseline"
        case .zoom: return "zoom"
        case .countdown: return "countdown"
        case .challenge: return "challenge"
        case .extraCheckIntro: return "extra_check_intro"
        case .extraCheckDone: return "extra_check_done"
        case .micUnavailable: return "mic_unavailable"
        case .inlineStepUp: return "inline_step_up"
        case .uploading: return "uploading"
        case .completing: return "completing"
        case .done: return "done"
        case .error: return "error"
        }
    }
}

struct SessionData: Sendable {
    let sessionId: String
    let sessionToken: String
    let nonce: String
    let expiresAt: Date
    /// Replaced once if the server swaps Speak Digits for Follow Dot.
    var policy: SessionPolicy
    let upload: UploadConfig
    let geometricCoherence: GeometricCoherenceConfig?
    /// Dashboard branding delivered with the session (nil on older servers).
    var branding: ServerBranding? = nil
    /// EVIDENCE-v1 instructions (nil: collect and upload as before Phase 2).
    var evidence: EvidenceConfig? = nil

    var isExpired: Bool { Date() >= expiresAt }
}

extension SessionData {
    init(from response: CreateSessionResponse) {
        self.sessionId = response.sessionId
        self.sessionToken = response.sessionToken
        self.nonce = response.nonce

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.expiresAt = formatter.date(from: response.expiresAt) ?? Date().addingTimeInterval(900)

        self.policy = response.policy
        self.upload = response.upload
        self.geometricCoherence = response.geometricCoherence
        self.branding = response.branding
        self.evidence = response.evidence
    }
}
