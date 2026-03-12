import Foundation

// MARK: - Server Branding (from /data endpoint)

public struct ServerBranding: Codable, Sendable {
    public let displayName: String?
    public let logoUrl: String?
    public let primaryColor: String?
    public let redirectUrl: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case logoUrl = "logo_url"
        case primaryColor = "primary_color"
        case redirectUrl = "redirect_url"
    }
}

// MARK: - Effective Branding (merged: SDK > org > defaults)

public struct EffectiveBranding: Sendable {
    public let displayName: String
    public let logoUrl: String?
    public let primaryColor: String
    public let redirectUrl: String?

    public init(
        displayName: String = "UseSense",
        logoUrl: String? = nil,
        primaryColor: String = "#4f46e5",
        redirectUrl: String? = nil
    ) {
        self.displayName = displayName
        self.logoUrl = logoUrl
        self.primaryColor = primaryColor
        self.redirectUrl = redirectUrl
    }

    /// Merge SDK-level branding > server branding > defaults
    public static func merge(sdk: UseSenseBranding?, server: ServerBranding?) -> EffectiveBranding {
        EffectiveBranding(
            displayName: sdk?.displayName ?? server?.displayName ?? "UseSense",
            logoUrl: sdk?.logoUrl ?? server?.logoUrl,
            primaryColor: sdk?.primaryColor ?? server?.primaryColor ?? "#4f46e5",
            redirectUrl: sdk?.redirectUrl ?? server?.redirectUrl
        )
    }
}

// MARK: - SDK-level Branding (from integrator)

public struct UseSenseBranding: Sendable {
    public var displayName: String?
    public var logoUrl: String?
    public var primaryColor: String?
    public var redirectUrl: String?

    public init(
        displayName: String? = nil,
        logoUrl: String? = nil,
        primaryColor: String? = nil,
        redirectUrl: String? = nil
    ) {
        self.displayName = displayName
        self.logoUrl = logoUrl
        self.primaryColor = primaryColor
        self.redirectUrl = redirectUrl
    }
}

// MARK: - Action Context (verification flow)

public struct ActionContext: Codable, Sendable {
    public let actionText: String?
    public let riskTier: String?
    public let actionType: String?

    enum CodingKeys: String, CodingKey {
        case actionText = "action_text"
        case riskTier = "risk_tier"
        case actionType = "action_type"
    }
}

// MARK: - Remote Enrollment Data Response

public struct RemoteEnrollmentData: Codable, Sendable {
    public let id: String
    public let status: String
    public let organizationId: String?
    public let branding: ServerBranding?
    public let successMessage: String?
    public let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, status, branding
        case organizationId = "organization_id"
        case successMessage = "success_message"
        case errorMessage = "error_message"
    }
}

// MARK: - Remote Session Data Response

public struct RemoteSessionData: Codable, Sendable {
    public let id: String
    public let status: String
    public let organizationId: String?
    public let branding: ServerBranding?
    public let actionContext: ActionContext?
    public let successMessage: String?
    public let errorMessage: String?
    public let reviewMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, status, branding
        case organizationId = "organization_id"
        case actionContext = "action_context"
        case successMessage = "success_message"
        case errorMessage = "error_message"
        case reviewMessage = "review_message"
    }
}

// MARK: - Init Session Response (shared by enrollment + verification)

public struct HostedInitSessionResponse: Codable, Sendable {
    public let success: Bool
    public let sessionId: String
    public let sessionToken: String
    public let nonce: String
    public let policy: SessionPolicy
    public let upload: UploadConfig

    enum CodingKeys: String, CodingKey {
        case success
        case sessionId = "session_id"
        case sessionToken = "session_token"
        case nonce, policy, upload
    }

    /// Convert to the standard CreateSessionResponse format used by the capture engine.
    func toCreateSessionResponse() -> CreateSessionResponse {
        CreateSessionResponse(
            sessionId: sessionId,
            sessionToken: sessionToken,
            // Hosted init doesn't return expires_at; default 15 min from now
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(900)),
            nonce: nonce,
            policy: policy,
            upload: upload
        )
    }
}

// MARK: - Remote Complete Response

public struct RemoteCompleteResponse: Codable, Sendable {
    public let success: Bool
    public let status: String?
    public let decision: String?
    public let message: String?
}

// MARK: - Dispute Response

public struct DisputeResponse: Codable, Sendable {
    public let success: Bool
    public let message: String?
}
