import Foundation

/// Configuration for the UseSense SDK.
public struct UseSenseConfig {
    public let apiKey: String
    public let environment: UseSenseEnvironment
    public let baseURL: URL

    public init(
        apiKey: String,
        environment: UseSenseEnvironment? = nil,
        baseURL: URL = URL(string: "https://api.usesense.ai")!
    ) {
        self.apiKey = apiKey
        self.environment = environment ?? UseSenseEnvironment.detect(from: apiKey)
        self.baseURL = baseURL
    }
}

public enum UseSenseEnvironment: String, Sendable {
    case sandbox
    case production

    static func detect(from apiKey: String) -> UseSenseEnvironment {
        apiKey.hasPrefix("sk_") ? .sandbox : .production
    }
}
