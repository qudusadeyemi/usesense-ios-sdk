# Contributing

The UseSense iOS SDK is proprietary software. External code contributions are not accepted at this time.

## Bug Reports

If you encounter a bug, please report it via one of the following channels:

- **GitHub Issues**: Open an issue on this repository with steps to reproduce, expected behavior, and actual behavior.
- **Email**: [support@usesense.ai](mailto:support@usesense.ai)

Please include:
- SDK version (`UseSense.version`)
- iOS version and device model
- Xcode version
- Steps to reproduce the issue
- Any relevant logs or error codes

## Security Vulnerabilities

Do **not** report security vulnerabilities via GitHub Issues. See [SECURITY.md](SECURITY.md) for responsible disclosure instructions.

## Feature Requests

Feature requests are welcome via GitHub Issues or email. Tag your issue with `enhancement`.

---

## Maintainer notes: build system & distribution channels

This section is for internal maintainers. External contributors can ignore it.

The iOS SDK ships through **three parallel distribution channels**, each with its own build spec. All three compile the same Swift sources under `Sources/UseSense/**`, so there is one source of truth for the code itself — but the build manifests must be kept aligned by hand when anything about the source layout, resources, or public API changes.

### The three build specs

| Channel      | Manifest                           | Consumers                                                 |
| ------------ | ---------------------------------- | --------------------------------------------------------- |
| SwiftPM      | `Package.swift`                    | Xcode users who add the repo URL in Swift Package Manager |
| CocoaPods    | `UseSenseSDK.podspec`              | Pods consumers (`pod 'UseSenseSDK'`)                      |
| XCFramework  | `XCFrameworkBuild/project.yml`     | Manual-install users who drag the `.xcframework` into their project from the GitHub Release |

All three point at `Sources/UseSense/**` via globs. There is no source duplication. But a change in any of the following requires updating all three manifests:

1. **Adding a new `Resources/` file.** Add it to the podspec's `s.resource_bundles`, and add an explicit entry in `XCFrameworkBuild/project.yml` under the target's `sources:` block with `buildPhase: resources`. SwiftPM picks it up automatically via `.process("Resources")`.
2. **Adding a new top-level source directory** outside `Sources/UseSense/`. Update `path:` in `Package.swift`, `s.source_files` in the podspec, and the `sources:` glob in `XCFrameworkBuild/project.yml`.
3. **Bumping the minimum iOS deployment target.** Update `platforms:` in `Package.swift`, `s.ios.deployment_target` in the podspec, and `deploymentTarget.iOS` in `XCFrameworkBuild/project.yml`.
4. **Bumping the SDK version.** Update `s.version` in the podspec and `MARKETING_VERSION` in `XCFrameworkBuild/project.yml`. Add a new `[x.y.z]` entry to `CHANGELOG.md`. Then tag `vX.Y.Z` — the `release-ios.yml` workflow takes over from there.
5. **Adding a framework / weak framework dependency.** Update `s.frameworks` / `s.weak_frameworks` in the podspec. SwiftPM usually picks up system frameworks automatically via Swift imports, but the XCFramework build may need them in `settings.base.FRAMEWORK_SEARCH_PATHS` or as explicit `dependencies:` entries in `project.yml`.

### Why the XCFramework needs its own Xcode project

`xcodebuild archive` cannot produce a distributable `.framework` bundle from a SwiftPM package product. A static library product archives to an object bundle with no enclosing framework, and a dynamic library product (`type: .dynamic`) archives to a bare framework shell missing `Modules/`, `Info.plist`, and the `.swiftinterface` files. Consumers who drag that framework into a host app get link errors on `import UseSenseSDK`.

`XCFrameworkBuild/project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec that defines a parallel Xcode framework target compiling the same sources into a proper iOS framework bundle (`Modules/UseSenseSDK.swiftmodule/`, `Headers/UseSenseSDK-Swift.h`, `Info.plist`, flat resources). The generated `.xcodeproj` is git-ignored; `project.yml` is the source of truth. The release workflow runs `brew install xcodegen && xcodegen generate` before `xcodebuild archive`.

### Bundle resource access

`Sources/UseSense/FaceMesh/Bundle+UseSense.swift` defines `Bundle.useSenseResources`, a cross-toolchain accessor that picks the right bundle layout based on how the SDK was built:

- Under SwiftPM (`SWIFT_PACKAGE` defined) it returns `Bundle.module`.
- Under CocoaPods it finds the nested `UseSenseSDK.bundle` inside the parent framework.
- Under the XCFramework wrapper project (no `SWIFT_PACKAGE`, resources flat in framework root) it falls through to `Bundle(for: BundleToken.self)`, which resolves to the framework bundle itself.

All three paths must stay correct. If you add a new resource access site, go through `Bundle.useSenseResources` and not `Bundle.module` directly — the latter only compiles under SwiftPM and will break the CocoaPods and XCFramework builds.

### Testing a build-system change locally

To smoke-test the XCFramework build without pushing a tag:

```bash
brew install xcodegen                  # once per machine
cd XCFrameworkBuild && xcodegen generate
cd ..
xcodebuild archive \
  -project XCFrameworkBuild/UseSenseSDK.xcodeproj \
  -scheme UseSenseSDK \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -archivePath /tmp/sim.xcarchive \
  SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO
```

If `ARCHIVE SUCCEEDED`, inspect `/tmp/sim.xcarchive/Products/Library/Frameworks/UseSenseSDK.framework/` and confirm it contains `Info.plist`, `Modules/UseSenseSDK.swiftmodule/`, and your new resource file (if applicable).

For CocoaPods, run `pod lib lint UseSenseSDK.podspec --allow-warnings` from the repo root.

For SwiftPM, run `swift build` (will skip resources but catches Swift compile errors) or open `Package.swift` in Xcode and build the `UseSenseSDK` scheme.
