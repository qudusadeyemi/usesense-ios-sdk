import Foundation

public struct UseSenseConfig: Sendable {
    /// Production base URL (Cloudflare Worker proxy). SDKs MUST NOT use Supabase URLs directly.
    public static let defaultEndpoint = "https://api.usesense.ai/v1"
    /// Staging base URL for development/testing.
    public static let stagingEndpoint = "https://staging.api.usesense.ai/v1"

    public let apiEndpoint: String
    public let apiKey: String
    public var environment: Environment?
    public var branding: BrandingConfig?
    public var options: SDKOptions?

    public init(
        apiEndpoint: String = UseSenseConfig.defaultEndpoint,
        apiKey: String,
        environment: Environment? = nil,
        branding: BrandingConfig? = nil,
        options: SDKOptions? = nil
    ) {
        let trimmedUrl = apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiEndpoint = trimmedUrl.isEmpty || URLComponents(string: trimmedUrl)?.scheme == nil
            ? Self.defaultEndpoint
            : trimmedUrl
        self.apiKey = apiKey
        self.environment = environment ?? Environment.detect(from: apiKey)
        self.branding = branding
        self.options = options
    }
}

public enum Environment: String, Codable, Sendable {
    case sandbox
    case production
    case auto

    public static func detect(from apiKey: String) -> Environment {
        if apiKey.hasPrefix("sk_prod_") || apiKey.hasPrefix("pk_prod_") || apiKey.hasPrefix("dk_prod_") {
            return .production
        } else if apiKey.hasPrefix("sk_sandbox_") || apiKey.hasPrefix("pk_sandbox_") || apiKey.hasPrefix("dk_sandbox_") {
            return .sandbox
        }
        return .production
    }

    /// Resolve AUTO to a concrete environment based on the API key.
    public func resolved(apiKey: String) -> String {
        switch self {
        case .auto: return Environment.detect(from: apiKey).rawValue
        case .sandbox: return "sandbox"
        case .production: return "production"
        }
    }
}

public struct VerificationRequest: Sendable {
    public let sessionType: SessionType
    public let externalUserId: String?
    public let identityId: String?
    public let metadata: [String: AnyCodableValue]?

    public init(
        sessionType: SessionType,
        externalUserId: String? = nil,
        identityId: String? = nil,
        metadata: [String: AnyCodableValue]? = nil
    ) {
        self.sessionType = sessionType
        self.externalUserId = externalUserId
        self.identityId = identityId
        self.metadata = metadata
    }
}

public struct BrandingConfig: Sendable {
    public var logoUrl: String?
    public var primaryColor: String
    public var buttonRadius: CGFloat
    public var fontFamily: String?

    public init(logoUrl: String? = nil, primaryColor: String = "#4F7CFF", buttonRadius: CGFloat = 10, fontFamily: String? = nil) {
        self.logoUrl = logoUrl
        self.primaryColor = primaryColor
        self.buttonRadius = buttonRadius
        self.fontFamily = fontFamily
    }
}

public struct SDKOptions: Sendable {
    public var audioEnabled: AudioMode
    public var stepUpPolicy: StepUpPolicy
    public var captureDurationMs: Int
    public var targetFps: Int
    public var maxFrames: Int
    public var maxUploadSizeMb: Int

    public init(
        audioEnabled: AudioMode = .riskBased, stepUpPolicy: StepUpPolicy = .riskBased,
        captureDurationMs: Int = 8000, targetFps: Int = 3, maxFrames: Int = 30, maxUploadSizeMb: Int = 10
    ) {
        self.audioEnabled = audioEnabled
        self.stepUpPolicy = stepUpPolicy
        self.captureDurationMs = captureDurationMs
        self.targetFps = targetFps
        self.maxFrames = maxFrames
        self.maxUploadSizeMb = maxUploadSizeMb
    }
}

public enum AudioMode: String, Codable, Sendable { case never, riskBased = "risk_based", always }
public enum StepUpPolicy: String, Codable, Sendable { case riskBased = "risk_based", always, never }
