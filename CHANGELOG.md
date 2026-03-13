# Changelog

All notable changes to the UseSense iOS SDK will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-03-12

### Added
- Initial public release
- `UseSense` entry point with `createSession()` and `startVerification()` APIs
- `UseSenseSession` for managing verification lifecycle
- `UseSenseView` (SwiftUI) and `UseSenseViewController` (UIKit) for presenting verification UI
- Enrollment sessions with 1:N duplicate detection
- Authentication sessions with 1:1 face verification
- Three-pillar verification: DeepSense (channel integrity), LiveSense (proof-of-life), MatchSense (identity collision)
- Challenge types: follow dot, head turn, speak phrase
- Real-time event streaming via `addEventListener()` and `onEvent()`
- Full error code set with user-facing messages and recovery guidance
- `RedactedDecisionObject` for secure client-side result handling
- App Attest integration for device integrity verification
- CoreMotion sensor data collection for DeepSense correlation
- Audio capture support for voice deepfake detection
- Image quality analysis with real-time feedback
- Frame budget enforcement with server-side configuration
- Hosted verification flow support
- Automatic environment detection from API key prefix
- CocoaPods and Swift Package Manager distribution
- Privacy manifest (PrivacyInfo.xcprivacy) for App Store compliance
- Sandbox and production environment support

[1.0.0]: https://github.com/usesense/usesense-ios-sdk/releases/tag/v1.0.0
