import Foundation

public struct UseSenseConfig: Sendable {
    public let apiBaseUrl: String
    public let apiKey: String
    public var gatewayKey: String?
    public var environment: Environment?
    public var branding: BrandingConfig?
    public var options: SDKOptions?

    public init(
        apiBaseUrl: String = "https://api.usesense.ai/functions/v1/make-server-fc4cf30d",
        apiKey: String,
        gatewayKey: String? = nil,
        environment: Environment? = nil,
        branding: BrandingConfig? = nil,
        options: SDKOptions? = nil
    ) {
        self.apiBaseUrl = apiBaseUrl
        self.apiKey = apiKey
        self.gatewayKey = gatewayKey
        self.environment = environment ?? Environment.detect(from: apiKey)
        self.branding = branding
        self.options = options
    }
}

public enum Environment: String, Codable, Sendable {
    case sandbox
    case production

    static func detect(from apiKey: String) -> Environment {
        apiKey.hasPrefix("pk_") ? .production : .sandbox
    }
}

public struct BrandingConfig: Sendable {
    public var logoUrl: String?
    public var primaryColor: String
    public var buttonRadius: CGFloat
    public var fontFamily: String?

    public init(logoUrl: String? = nil, primaryColor: String = "#4F63F5", buttonRadius: CGFloat = 12, fontFamily: String? = nil) {
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
        captureDurationMs: Int = 2500, targetFps: Int = 15, maxFrames: Int = 40, maxUploadSizeMb: Int = 10
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
