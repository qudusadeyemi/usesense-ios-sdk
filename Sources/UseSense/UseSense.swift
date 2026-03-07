#if canImport(UIKit)
import Foundation

/// UseSense SDK public entry point.
public final class UseSense: @unchecked Sendable {
    public static let sdkVersion = "1.0.0"
    public static let shared = UseSense()

    private(set) var config: UseSenseConfig?
    private(set) var theme: UseSenseTheme = .default

    private init() {}

    /// Configure the UseSense SDK. Must be called before starting any verification.
    ///
    /// - Parameters:
    ///   - apiKey: Your UseSense API key (`sk_` for sandbox, `pk_` for production).
    ///   - environment: Optional environment override. Auto-detected from the API key prefix if not specified.
    ///   - baseURL: Optional API base URL override.
    ///   - theme: Optional theme customization.
    public static func configure(
        apiKey: String,
        environment: UseSenseEnvironment? = nil,
        baseURL: URL = URL(string: "https://api.usesense.ai")!,
        theme: UseSenseTheme? = nil
    ) {
        shared.config = UseSenseConfig(apiKey: apiKey, environment: environment, baseURL: baseURL)
        if let theme = theme {
            shared.theme = theme
        }
    }

    /// Returns whether the SDK has been configured.
    public static var isConfigured: Bool {
        shared.config != nil
    }
}
#endif
