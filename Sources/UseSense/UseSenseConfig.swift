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
    /// Full white-label customization passed by the developer at SDK init. This
    /// is the highest-priority layer in the Flow appearance merge:
    ///   appearance > server(branding.appearance) > legacy primaryColor/buttonRadius/logoUrl/fontFamily > built-in default.
    /// When nil, the legacy `primaryColor` / `buttonRadius` / `logoUrl` /
    /// `fontFamily` fields above still apply (projected into the lowest layer).
    public var appearance: FlowAppearance?

    public init(
        logoUrl: String? = nil,
        primaryColor: String = "#4F7CFF",
        buttonRadius: CGFloat = 10,
        fontFamily: String? = nil,
        appearance: FlowAppearance? = nil
    ) {
        self.logoUrl = logoUrl
        self.primaryColor = primaryColor
        self.buttonRadius = buttonRadius
        self.fontFamily = fontFamily
        self.appearance = appearance
    }

    /// The developer-supplied appearance, with the legacy scalar fields folded in
    /// as a lower-priority fallback layer (so existing integrations that only set
    /// `primaryColor` / `buttonRadius` keep working under the new resolver).
    public var resolvedAppearance: FlowAppearance? {
        let legacy = FlowAppearance.fromLegacy(
            primaryColor: primaryColor,
            buttonRadius: buttonRadius,
            logoUrl: logoUrl,
            fontFamily: fontFamily
        )
        return FlowAppearance.merge(high: appearance, low: legacy)
    }
}

public struct SDKOptions: Sendable {
    public var audioEnabled: AudioMode
    public var stepUpPolicy: StepUpPolicy
    public var captureDurationMs: Int
    public var targetFps: Int
    public var maxFrames: Int
    public var maxUploadSizeMb: Int
    /// Opt in to the on-device antispoof classifier. When enabled the SDK loads
    /// the bundled CoreML model, runs inference against each captured frame,
    /// and attaches per-frame spoof probabilities to the uploaded metadata under
    /// `signals.deep_classifier_on_device`. When disabled the watchtower backend
    /// runs the classifier server-side. Defaults to false in v4.2 -- see
    /// `docs/sdk-specs/antispoof-classifier-sdk-spec.md` for the rollout plan.
    public var antispoofOnDeviceEnabled: Bool

    /// Opt the session into the LiveSense v4 capture flow. When true the SDK:
    ///   - sends `x-usesense-sdk-version: v4` on session creation
    ///   - inserts a constitutive zoom-motion phase between framing and the
    ///     active challenge (additive, not a replacement -- existing
    ///     head_turn / follow_dot / speak_phrase challenges still run)
    ///   - tags every captured frame with its capture phase so the server's
    ///     SfM perspective validator can filter to the zoom subset
    /// Defaults to false. The org must also have `livesense_v4_enabled` in its
    /// features map; the server returns 400 v4_not_enabled otherwise.
    public var liveSenseV4Enabled: Bool

    public init(
        audioEnabled: AudioMode = .riskBased, stepUpPolicy: StepUpPolicy = .riskBased,
        captureDurationMs: Int = 8000, targetFps: Int = 3, maxFrames: Int = 30, maxUploadSizeMb: Int = 10,
        antispoofOnDeviceEnabled: Bool = false,
        liveSenseV4Enabled: Bool = false
    ) {
        self.audioEnabled = audioEnabled
        self.stepUpPolicy = stepUpPolicy
        self.captureDurationMs = captureDurationMs
        self.targetFps = targetFps
        self.maxFrames = maxFrames
        self.maxUploadSizeMb = maxUploadSizeMb
        self.antispoofOnDeviceEnabled = antispoofOnDeviceEnabled
        self.liveSenseV4Enabled = liveSenseV4Enabled
    }
}

public enum AudioMode: String, Codable, Sendable { case never, riskBased = "risk_based", always }
public enum StepUpPolicy: String, Codable, Sendable { case riskBased = "risk_based", always, never }
