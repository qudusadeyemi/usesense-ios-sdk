# Changelog

All notable changes to the UseSense iOS SDK will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [4.1.0] - 2026-04-06

### Breaking Changes
- **Auth**: Removed Supabase gateway headers (`apikey`, `Authorization: Bearer`). SDK now communicates through Cloudflare Worker proxy at `api.usesense.ai/v1`. Only `x-api-key`, `x-session-token`, `x-nonce`, and `x-environment` headers are sent.
- **Config**: Removed `gatewayKey` parameter from `UseSenseConfig`. The Cloudflare Worker injects gateway auth server-side.
- **Capture**: `max_frames` reduced from 40 to 30, `target_fps` from 15 to 3, `capture_duration_ms` default increased to 8000ms.
- **Camera**: Resolution upgraded from VGA (640x480) to native (`.high` preset). Server handles analysis at full resolution.
- **API key prefixes**: Now expects `sk_prod_*`/`sk_sandbox_*` format with explicit environment segment.
- **Brand**: Primary color changed from `#4F63F5` to `#4F7CFF` (DeepSense Blue). Button radius changed from 12 to 10.

### Added
- **Geometric Coherence**: On-device 3DMM fitting via MediaPipe FaceMesh, HMAC-SHA256 cryptographic binding proofs per frame, cross-frame consistency scoring, verification package upload.
- **Suspicion Engine**: Client-side presentation attack detection with 4 weighted signals (micro-tremor 0.35, temporal smoothness 0.25, brightness stability 0.20, sharpness pattern 0.20).
- **Inline Step-Up**: Flash Reflection challenge (3 color flashes, facial reflection detection) and RMAS challenge (3 randomized micro-actions) with 15-second timeout protection.
- **Server-Side Init**: `createSessionWithToken(clientToken:)` for token exchange flow. Supports reference image matching (KYC) and zero-credential-exposure deployments.
- **Screen Detection Signals**: Luminance histogram spread, edge energy ratio, frame luminance CV, color channel uniformity in `channel_integrity.screen_detection`.
- **Frame Hashing**: SHA-256 per JPEG frame via CryptoKit. Hashes sent in `frame_hashes` metadata array.
- **Nonce dual-delivery**: Nonce sent in both `X-Nonce` header and `?nonce=` query param on all authenticated requests.
- **Per-frame luminance**: Computed during capture for Suspicion Engine input.
- **New error codes**: `TOKEN_EXPIRED`, `TOKEN_ALREADY_USED`, `INSUFFICIENT_CREDITS`, `NONCE_MISMATCH`.
- **New events**: `step_up_triggered`, `step_up_completed`.

### Changed
- Base URL changed from `api.usesense.ai/functions/v1/make-server-fc4cf30d` to `api.usesense.ai/v1`.
- Brand colors updated per Brand Manual v3.0: DeepSense Blue `#4F7CFF`, LiveSense Purple `#7C5CFC`, MatchSense Green `#00D4AA`, warm neutral palette.
- Verdict copy: "Verification Unsuccessful" replaces "Verification Denied".
- Retry strategy updated: network errors 3 retries (1s, 2s, 4s), 5xx 2 retries (2s), 429 respects `Retry-After` header.
- Environment detection updated for `sk_prod_*`/`pk_prod_*`/`sk_sandbox_*`/`pk_sandbox_*` prefixes.
- `sdk_version` in metadata now `"4.1.0"`.

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

[4.1.0]: https://github.com/usesense/usesense-ios-sdk/releases/tag/v4.1.0
[1.0.0]: https://github.com/usesense/usesense-ios-sdk/releases/tag/v1.0.0
