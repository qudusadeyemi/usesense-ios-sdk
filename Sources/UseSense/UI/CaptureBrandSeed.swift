#if canImport(UIKit) && canImport(SwiftUI)
import Foundation

/// Seeds the brand resolvers for a capture that runs outside a Flow (a
/// standalone session, a hosted verification or enrollment page). Inside a
/// Flow the runner owns the resolvers and nothing here touches them.
/// BRAND-v1 section 6: resolve once per session, use it on every screen.
@MainActor
final class CaptureBrandSeed {
    private(set) var owns = false

    /// A Flow runner is presenting: it owns the resolvers for the whole run.
    nonisolated(unsafe) static var flowRunActive = false

    private static var ownedElsewhere: Bool {
        flowRunActive || FlowAppearanceResolver.current != nil || FlowCopyResolver.current != nil
    }

    /// Seeds when no Flow runner owns the resolvers. Later calls refresh the
    /// seed (e.g. when the dashboard branding arrives).
    @discardableResult
    func seed(appearance: FlowAppearance?, copy: FlowCopy?, displayName: String?) -> Bool {
        if !owns {
            guard !Self.ownedElsewhere else { return false }
            owns = true
        }
        FlowAppearanceResolver.set(appearance)
        FlowCopyResolver.set(copy)
        FlowCopyResolver.setDisplayName(displayName)
        return true
    }

    /// Hosted pages: the capture brand from the integrator's code (config
    /// branding, then the hosted `UseSenseBranding`) over the dashboard.
    static func hostedLayers(config: UseSenseConfig, sdk: UseSenseBranding?, server: ServerBranding?)
        -> (appearance: FlowAppearance?, copy: FlowCopy?, displayName: String?) {
        let sdkLayer: FlowAppearance? = (sdk?.primaryColor == nil && sdk?.logoUrl == nil) ? nil
            : FlowAppearance.fromLegacy(primaryColor: sdk?.primaryColor, buttonRadius: nil, logoUrl: sdk?.logoUrl, fontFamily: nil)
        let code = FlowAppearance.merge(high: config.branding?.resolvedAppearance, low: sdkLayer)
        USTrace.log(BrandingResolver.describeSources(code: code, dashboard: server?.resolvedAppearance))
        return (BrandingResolver.resolve(code: code, dashboard: server?.resolvedAppearance),
                FlowCopy.merge(high: config.branding?.copy, low: server?.copy),
                sdk?.displayName ?? server?.displayName)
    }

    /// Clears only what this seed set.
    func clear() {
        guard owns else { return }
        owns = false
        FlowAppearanceResolver.reset()
        FlowCopyResolver.reset()
    }
}
#endif
