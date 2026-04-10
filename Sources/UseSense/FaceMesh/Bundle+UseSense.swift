import Foundation

/// Cross-toolchain accessor for the UseSense SDK resource bundle.
///
/// Under SwiftPM (`SWIFT_PACKAGE` is defined by the Swift compiler when
/// building a SwiftPM target), returns `Bundle.module`, which Swift auto-
/// generates for targets that declare `.process("Resources")` in their
/// `Package.swift` manifest.
///
/// Under CocoaPods, `Bundle.module` does not exist. The podspec declares
/// `s.resource_bundles = { 'UseSenseSDK' => [...] }`, which causes CocoaPods
/// to create a nested `UseSenseSDK.bundle` inside the parent pod
/// framework/library bundle. We locate that nested bundle by anchoring on a
/// private `BundleToken` class that lives in the same compilation unit, then
/// fall back to the framework bundle itself if the nested bundle cannot be
/// found (which can happen with some CocoaPods configurations that drop
/// resources directly into the framework bundle).
extension Bundle {
    static var useSenseResources: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        let frameworkBundle = Bundle(for: BundleToken.self)
        if let nestedBundleURL = frameworkBundle.url(
            forResource: "UseSenseSDK",
            withExtension: "bundle"
        ), let nestedBundle = Bundle(url: nestedBundleURL) {
            return nestedBundle
        }
        return frameworkBundle
        #endif
    }
}

private final class BundleToken {}
