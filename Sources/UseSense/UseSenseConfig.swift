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
    /// The built-in legacy brand color. Kept as the non-nil default of
    /// `primaryColor` so the legacy session UI (which reads `primaryColor` as a
    /// plain `String`) always has a concrete color, but treated as "not set" by
    /// the Flow appearance resolver so it never beats the operator's dashboard
    /// color (see `resolvedAppearance`).
    public static let defaultPrimaryColor = "#4F7CFF"
    /// The built-in legacy button radius (kept as the concrete value of
    /// `buttonRadius` for legacy screens; "not set" for the resolver).
    public static let defaultButtonRadius: CGFloat = 10

    public var logoUrl: String?
    public var primaryColor: String
    public var buttonRadius: CGFloat
    public var fontFamily: String?
    /// Whether the developer explicitly supplied `primaryColor` at init. When
    /// false (the field still holds `defaultPrimaryColor`), the Flow appearance
    /// resolver does NOT fold the legacy color into the merge, so the server's
    /// dashboard color wins. Existing non-Flows surfaces that read `primaryColor`
    /// directly are unaffected — they still see the concrete default.
    private let primaryColorWasSet: Bool
    /// Same rule for `buttonRadius`: the legacy default (10) must not occupy the
    /// code layer and beat a dashboard radius.
    private let buttonRadiusWasSet: Bool
    /// Full white-label customization passed by the developer at SDK init.
    /// Precedence per field (BRAND-v1 section 2, "code wins"):
    ///   per-launch code > this `appearance` > the legacy primaryColor /
    ///   buttonRadius / fontFamily / logoUrl above > dashboard Flow > dashboard
    ///   org > built-in default.
    /// The legacy fields are code, so they beat every dashboard layer.
    public var appearance: FlowAppearance?
    /// Full white-label copy/messaging override passed by the developer at SDK
    /// init. Precedence per field: code copy > dashboard Flow > dashboard org >
    /// built-in default (capture strings: `copy.capture`, BRAND-v1 section 5).
    /// When nil, the built-in hosted-page copy applies.
    public var copy: FlowCopy?

    public init(
        logoUrl: String? = nil,
        primaryColor: String? = nil,
        buttonRadius: CGFloat? = nil,
        fontFamily: String? = nil,
        appearance: FlowAppearance? = nil,
        copy: FlowCopy? = nil
    ) {
        self.logoUrl = logoUrl
        self.primaryColor = primaryColor ?? Self.defaultPrimaryColor
        self.primaryColorWasSet = primaryColor != nil
        self.buttonRadius = buttonRadius ?? Self.defaultButtonRadius
        self.buttonRadiusWasSet = buttonRadius != nil
        self.fontFamily = fontFamily
        self.appearance = appearance
        self.copy = copy
    }

    /// The developer-supplied appearance, with the legacy scalar fields folded in
    /// as a lower-priority fallback layer (so existing integrations that only set
    /// `primaryColor` / `buttonRadius` keep working under the new resolver).
    ///
    /// The legacy `primaryColor` is folded ONLY when the developer explicitly set
    /// it. When it still holds the built-in default, it is passed as `nil` so it
    /// does not occupy the SDK-init color layer and beat the operator's
    /// server-side dashboard color. This mirrors web/Android, where the SDK-init
    /// `colors.primary` is simply absent unless the developer supplies it.
    public var resolvedAppearance: FlowAppearance? {
        let legacy = FlowAppearance.fromLegacy(
            primaryColor: primaryColorWasSet ? primaryColor : nil,
            buttonRadius: buttonRadiusWasSet ? buttonRadius : nil,
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

    /// The guided capture screen (LiveSense capture redesign, Phase 1): a
    /// blocking quality gate on the face mesh with one hint at a time, auto
    /// start when every check passes, a scan that pauses instead of
    /// restarting, a screen fill light in the dark, a contour scan visual and
    /// a shutter fallback. Experience only: the upload and scoring are
    /// unchanged. Defaults to true; false restores the "I'm Ready" screen.
    public var guidedCaptureEnabled: Bool

    /// Show the SDK's result screen ("You're verified", "We couldn't verify
    /// you", ...) before reporting the decision. False reports the decision
    /// as soon as it arrives, so the app can show its own screen. Defaults to
    /// true. Error screens are always shown.
    public var showsResultScreen: Bool

    /// How many times the person may try again from the "We couldn't verify
    /// you" screen (guided capture). 0, the default, shows no "Try again":
    /// the screen points back to the app. Ignored for sessions handed in by a
    /// Flow or a hosted page, which follow their own retry policy.
    public var retriesAfterReject: Int

    public init(
        audioEnabled: AudioMode = .riskBased, stepUpPolicy: StepUpPolicy = .riskBased,
        captureDurationMs: Int = 8000, targetFps: Int = 3, maxFrames: Int = 30, maxUploadSizeMb: Int = 10,
        antispoofOnDeviceEnabled: Bool = false,
        liveSenseV4Enabled: Bool = false,
        guidedCaptureEnabled: Bool = true,
        showsResultScreen: Bool = true,
        retriesAfterReject: Int = 0
    ) {
        self.audioEnabled = audioEnabled
        self.stepUpPolicy = stepUpPolicy
        self.captureDurationMs = captureDurationMs
        self.targetFps = targetFps
        self.maxFrames = maxFrames
        self.maxUploadSizeMb = maxUploadSizeMb
        self.antispoofOnDeviceEnabled = antispoofOnDeviceEnabled
        self.liveSenseV4Enabled = liveSenseV4Enabled
        self.guidedCaptureEnabled = guidedCaptureEnabled
        self.showsResultScreen = showsResultScreen
        self.retriesAfterReject = max(0, retriesAfterReject)
    }
}

public enum AudioMode: String, Codable, Sendable { case never, riskBased = "risk_based", always }
public enum StepUpPolicy: String, Codable, Sendable { case riskBased = "risk_based", always, never }
