# Changelog

All notable changes to the UseSense iOS SDK will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [4.7.1] - 2026-08-13

### Fixed

- **The Flows runner did not pass its white-label down to the capture screens.**
  `FlowsRunnerViewController.presentCaptureViewController` built the capture
  engine's `UseSenseConfig` with only an endpoint, a placeholder api key and an
  environment -- no `branding` -- so `BrandingConfig.primaryColor` fell back to
  the built-in `#4F7CFF`. The runner's own surfaces read
  `FlowAppearanceResolver`, which is already seeded, but the capture screens
  colour from the flat `branding.primaryColor` (`EnrollmentIntroductionView`
  and friends). A subject saw the org's brand colour on the step primer and
  default blue on the consent, loading and capture screens either side of it.

  The resolved appearance, its primary colour and the merged copy are now
  handed through. Android carried the identical gap and is fixed in its 4.7.1.

  Note the preview-mirroring defect fixed in Android 4.7.1 does NOT apply here:
  iOS renders through `AVCaptureVideoPreviewLayer` with no explicit mirroring,
  so it takes `automaticallyAdjustsVideoMirroring`, which mirrors the front
  camera correctly. Checked rather than assumed.

## [Unreleased]

### Changed

- **Frames upload at 960px instead of the camera's native 1080p.** The capture
  session runs at `.high` and frames were JPEG-encoded at that full size with no
  downscale, so 30 frames measured **12.9 MB per production session** — roughly
  five times the web SDK. On a mobile uplink that cannot finish inside any sane
  timeout. Frames are now capped at 960 on the longest edge using a Lanczos
  resample, which cuts the payload ~5x.

  960 matches the web SDK's cap and the server's sharpness calibration table.
  It was chosen by measuring 198 real frames through the pipeline: Rekognition
  face matching is unaffected, and the binding constraint is the sharpness score
  the server's screen-replay detector reads, which stays clear of the "possible
  screen" ceiling at 960 but not below it.

- **`metadata.json` is gzipped.** Adds RFC 1952 framing over the Compression
  framework's DEFLATE, since the server detects compression from the gzip magic
  bytes. Falls back to plain JSON if compression fails or would not help.

  **Requires a server that accepts gzipped metadata** — deploy that first.

### Fixed

- **The signals upload could not complete on a slow connection.** It carried two
  stacked caps: a 30s `timeoutInterval` on the request and a 120s
  `timeoutIntervalForResource` on the URLSession. Clearing the first needed
  ~430 KB/s of uplink and the second ~107 KB/s; a measured production session
  managed **14.6 KB/s**. Both now allow 300s, so a slow uplink finishes instead
  of being cancelled mid-transfer.

- **`frames_manifest` reported a hardcoded 1280x720** regardless of what was
  captured or sent — while frames were actually 1080x1920. The server scales its
  screen-replay sharpness thresholds off these values, so it was scoring frames
  against the wrong ruler. It now reports the real encoded size.

- **`UseSenseEventType.uploadProgress` was never emitted.** The event case
  existed but nothing fired it, so a multi-megabyte upload was an indeterminate
  spinner the subject could not tell apart from a hang. It now reports
  `bytes_sent`, `bytes_total` and `percent` as the body goes out.

- **Mesh verification_package skipped on flow runs (mesh decoupled from
  dual-path).** The capture engine only built and uploaded the Geometric
  Coherence `verification_package` when `dual_path_enabled` was true, ignoring
  `on_device_3dmm_required`. Flow-run sessions request mesh via
  `on_device_3dmm_required` (dual-path off), so the package was never built and
  the server scored a "mesh absent" DeepSense penalty even though MediaPipe ran
  and captured frames. The gate now also honours `on_device_3dmm_required`, so
  mesh is produced whenever the server asks for it on either path.

## [4.6.3] - 2026-08-05

Patch release: the runner now tells the server how the document was supplied.

### Changed

- **Report the document capture route.** The server tailors failure guidance to
  it: "hold the document still and wait for the camera to focus" is the right
  instruction for a live scan and meaningless to someone who chose a file, since
  the photo already exists and there is nothing left to hold. VisionKit's
  document scanner is reported as `camera`, the photo-library picker as
  `upload`. The runner already distinguished them for its own UI; it just never
  told the server.
- `captureMethod` is optional on the wire, so an older server ignores it and a
  runner that omits it makes the server fall back to the step's configured
  capture methods. No coordinated release required.

## [4.6.2] - 2026-08-04

Patch release: an upload that arrives incomplete is no longer reported as an outage.

### Fixed

- **"Verification is temporarily unavailable" for a document that was fine.**
  The upload branch had two outcomes: `provider` -> "temporarily unavailable",
  everything else -> "please retake it". A file that arrived cut short took the
  first path, so a subject holding a perfectly good licence was told to wait out
  an outage that was not happening, and the retry re-sent identical bytes. The
  server now reports `reason: "incomplete"` and carries the instruction in
  `message`; neither old branch fits it, since nothing upstream is wrong and a
  retake changes nothing. Adds the third branch and a `documentIncomplete` copy
  key. `too_large` now also prefers the server's message, which is the only
  place the exceeded limit is known.

  Note: the corruption that produced this in production was server-side and is
  already fixed. This release only changes what the subject is told.

## [4.4.1] - 2026-06-23

Patch release: the Flows client now identifies its platform to the server.

### Fixed

- **Flow capture scored on the web surface.** `FlowsClient` (the
  `/v1/sdk/flow-runs/*` client, including `init-session`) sent no `User-Agent`,
  so the server couldn't tell iOS from web at session creation and ran
  DeepSense channel-trust scoring on the web surface — penalising native
  captures for absent browser signals (WebGL/canvas/cookies). It now sends
  `UseSense-iOS-SDK/<version>`, which the server reads to score flow captures on
  the iOS surface from creation.

## [4.4.0] - 2026-06-22

Minor release making **on-device face mesh work out of the box**. Face capture
records frames only when face mesh detects a face, so without MediaPipe linked
the liveness step failed with "No frames captured." Previously each app had to
add `MediaPipeTasksVision` plus a `pre_install` Info.plist patch hook themselves.

### Added

- **`UseSenseMediaPipe` companion pod** — vendors the MediaPipe
  `Tasks{Vision,Common}` frameworks with Google's broken xcframework `Info.plist`
  pre-patched (`LibraryPath: <NAME>.a` -> `.framework`) and the force-loaded
  static graph archives bundled. Built by `scripts/vendor-mediapipe.sh` and
  attached to the GitHub Release.
- `UseSenseSDK` now depends on `UseSenseMediaPipe`, so face mesh is transitive —
  no per-app MediaPipe pod or `pre_install` hook.

### Changed

- **Requires `use_frameworks! :linkage => :static`** in the app's Podfile
  (MediaPipe ships static binaries). Plain `use_frameworks!` fails `pod install`
  with "transitive dependencies that include statically linked binaries".
- Release pipeline builds + hosts the patched MediaPipe bundle and publishes
  `UseSenseMediaPipe` before `UseSenseSDK`.

## [4.3.0] - 2026-06-15

Minor release adding the **Flows runner** (run operator-authored
verification Flows in-app) and **LiveSense v4** zoom capture. Existing
v3 `startVerification` / Sessions integrations are unaffected; Sessions
and Flows coexist.

### Added

- **`UseSenseFlows.run(flowRunId:sdkToken:apiBaseURL:from:completion:)`**:
  presents a full-screen runner that drives an operator-authored Flow
  (face, document, form, consent, and info steps) to a terminal outcome,
  delivered as `Result<FlowRunResult, FlowError>`. Flows are token-based
  and do not require an API key or `UseSense.init` on the device: your
  backend creates the run via `POST /v1/flow-runs` (with
  `mint_sdk_token: true`) and ships `flowRunId` + `sdkToken` to the app.
- **Document capture via VisionKit** for a Flow's document step, with a
  photo-library fallback, honoring the server-declared capture contract.
- **LiveSense v4 zoom capture**: `startV4Session(config:delegate:)`, a
  hardware-key chain signer, MP4 encoder, and the v4 session
  orchestrator. v3 verification behaviour is unchanged.

### Changed

- **Reported SDK version** (`UseSense.version`, sent to the backend as
  `sdk_version`) corrected from `4.1.0` to `4.3.0`. This was stale and
  understated the client version, which matters for Flow
  `min_sdk_version` gating and the `POST /v1/flow-runs` version check
  (`409 sdk_too_old`). The podspec version is aligned to `4.3.0` to match
  the Android SDK.

## [4.2.2] - 2026-04-11

Patch release fixing visual centring of terminal-state titles on
narrow screens and in localised builds.

### Fixed

- **`ResultView` terminal screens** (APPROVE, REJECT, MANUAL_REVIEW):
  The title text (e.g. "Verification Successful", "Verification
  Unsuccessful", "Under Review") lacked an explicit
  `.multilineTextAlignment(.center)` and an explicit
  `.frame(maxWidth: .infinity)`. When the title wrapped to multiple
  lines — which happens on iPhone SE widths and with longer
  localisations — the wrapped lines left-aligned inside the `Text`
  widget's intrinsic bounds, so the two-line title drifted off-
  centre relative to the icon above and subtitle below. Added both
  modifiers so wrapped titles centre row-by-row. Subtitles gained
  the `.frame(maxWidth: .infinity)` treatment for the same reason.
- **`FailureView` error titles** (`Something Went Wrong`,
  `Connection Error`, `Camera Unavailable`, `Session Expired`,
  `Rate Limited`): same fix, same reasoning — titles on the error
  path now centre correctly when they wrap.

### Unchanged

- No SDK public API, ABI, or runtime behaviour changes. Only the
  UI layout of terminal screens inside the SDK's own camera
  activity is affected. Integrators don't need to update any code;
  the patch is purely visual.

## [4.2.1] - 2026-04-11

Documentation-only patch release. No runtime code, public API, or
ABI changes. Re-published to the CocoaPods trunk so the pod page at
cocoapods.org renders the corrected developer-facing URLs in its
README panel, which is frozen per version at publish time.

### Fixed

- README, INTEGRATION_GUIDE, Example/README, and the Example app's
  ContentView now link to `https://watchtower.usesense.ai` (the
  canonical app host) instead of the retired `app.usesense.ai`
  marketing URL.
- Developer documentation links now point at
  `https://watchtower.usesense.ai/developer-docs` instead of the
  placeholder `docs.usesense.com` host, which never existed.
- All support contact references have been collapsed to the single
  public address `support@usesense.ai`, replacing the stale
  `support@usesense.com` alias.

## [4.2.0] - 2026-04-11

### Added

#### On-device Face Mesh (MediaPipe)
- **MediaPipe FaceLandmarker integration** via the `MediaPipeTasksVision` CocoaPod. The `face_landmarker.task` model is bundled inside the `UseSenseSDK` resource bundle and loaded at session start. Falls back gracefully to a no-face-mesh code path when the module is not linked (SwiftPM build) or the bundled asset is absent (pre-first-sync-run of the mediapipe-sdk-sync workflow). Model bytes are pinned to `64184e22` and kept in lockstep with the web SDK by the shared MediaPipe sync workflow.
- **`OnDevice3DMMFitter.projectionBasis`** — deterministic 12 × 117 orthonormal projection generated once at static init via xorshift64* + Gram-Schmidt. Replaces a degenerate weighted-sum stub that produced near-zero cross-frame variance in shape parameters and tripped the backend's mesh-integrity validator on every stable-face session. Variance now lands around ~1e-4 in practice, four orders of magnitude above the backend's variance floor. Documented as a Johnson-Lindenstrauss random projection — not trained PCA — so inter-face distinguishability is preserved without a dataset. A real trained basis is a planned follow-up and drops in without changing the wire format.

#### Device Telemetry
- **`DeviceSignalCollector`** now populates the watchtower dashboard's Device / Hardware / Display & Power / Connection / WebGL Renderer / User Agent / Language cards for iOS sessions (which were previously blank because they had been designed around the web SDK's browser-API values):
  - `webgl_vendor` / `webgl_renderer` from `MTLCreateSystemDefaultDevice().name` (guarded by `#if canImport(Metal)`)
  - `battery.{level,charging}` nested dict from `UIDevice.current.batteryLevel` / `.batteryState`
  - `connection.effective_type` from the existing Network framework resolver
  - `language` + `languages` from `Locale.current.identifier` and `Locale.preferredLanguages`
  - `hardware_concurrency` from `ProcessInfo.processInfo.activeProcessorCount`
  - `device_memory` from `ProcessInfo.processInfo.physicalMemory` (rounded to nearest 0.1 GB)
  - `user_agent` synthesized as `"UseSense-iOS-SDK/<version> (<model>; <os>; <locale>)"` matching the web SDK's convention
  - `viewport_size` (pt-based) alongside the existing `screen_width`/`screen_height` (px-based)
  - `screen_resolution` as a single string, `device_pixel_ratio`, `color_depth` (24), `max_touch_points` (5)
  - All legacy flat keys (`device_model`, `battery_level`, `network_type`, `locale`, …) are preserved alongside the new nested shapes, so any code reading the 4.1.0 schema keeps working.

#### Cryptographic Binding
- **`BindingProofGenerator.formatCanonicalDouble`** — new internal helper that mirrors JavaScript's `JSON.stringify` / `Number.prototype.toString()` byte-for-byte, so the canonical mesh JSON the SDK hashes matches what the backend's `computeMeshDigest` produces. Handles the three known Swift ↔ JS divergence cliffs:
  - Small magnitudes `[1e-6, 1e-4)` where Swift emits `"1e-05"` but JS wants `"0.00001"` (expands scientific to fixed).
  - Scientific exponent format where Swift emits `"1e-07"` but JS wants `"1e-7"` (strips leading zero from the exponent).
  - Large magnitudes `[1e17, 1e21)` where Swift emits `"1e+20"` but JS wants `"100000000000000000000"` (expands scientific to long integer).
- **`Tests/UseSenseTests/BindingProofGeneratorTests.swift`** — 14-case test suite covering zero / NaN / infinity, integer trailing `.0` stripping, all three cliff regions, real production shape-param values, and a hardcoded `meshDigest` reference vector verified against Node 20's `crypto.createHash('sha256')` so future numeric-serialisation drift is caught immediately.

#### Example app
- **`Example/Signing.debug.xcconfig`** and **`Example/Signing.release.xcconfig`** — committed xcconfig files that `#include` the CocoaPods-generated xcconfigs so pod settings flow through unchanged, then `#include?` an optional `Signing.local.xcconfig` (gitignored) where each developer sets their own `DEVELOPMENT_TEAM`. The Example target's `baseConfigurationReference` now points at these files for both Debug and Release. Eliminates the "dirty `project.pbxproj` on every clone" problem where Xcode was auto-adding the first developer's team ID to the committed project file.

### Changed

#### Canonical mesh JSON format
The `meshDigest` canonical JSON format changed to match the backend's `computeMeshDigest` exactly. This is a **coordinated wire-format update** with the `usesense-watchtower` edge function — SDK clients on 4.2.0 pair with edge function v49 or later. The old 4.1.0 format was byte-incompatible with the current backend and will fail binding verification at tier `binding`.

- Field order is now `s, p, d, l` (matches backend `JSON.stringify` key order).
- `p` is now an **array** `[yaw, pitch, roll]`, not an object `{y, p, r}`.
- `l` is now the literal string `"none"` because the iOS SDK does not upload raw landmarks in `verification_package.frames`. The backend's `computeMeshDigest` also emits `"none"` when the same condition holds.
- Floating-point formatting now flows through `formatCanonicalDouble` (see Added) for JS parity.

#### Verification package `frameIndex`
- `VerificationPackageBuilder.build` now emits the **upload-position loop index** (`i`) in `frame.frameIndex` instead of `FaceMeshManager.frameIndex` (which was a camera-sequence counter). This aligns with what the backend's `validateBinding` secondary cross-check expects and silences the "SDK frameIndex is not aligned with upload order" warning the edge function was emitting per frame on every 4.1.0 session.

#### Face mesh ↔ JPEG pairing
- **`FaceMeshManager.processFrame`** no longer auto-appends to the internal results array. It still runs on every camera frame and returns a `FaceMeshResult` so the suspicion engine can consume per-frame telemetry during the face guide stage.
- **New `FaceMeshManager.recordResult(_:)`** method called explicitly by the capture delegate only when the frame is also being buffered to the JPEG upload buffer. This guarantees `meshResults[i]` and `frameHashes[i]` correspond to the **same camera frame**, which was previously a coincidental property — `processFrame` ran at camera rate while JPEG capture ran at the throttled `targetFps` rate, so the array zip in `VerificationPackageBuilder.build` was an arbitrary pairing. The binding proof HMAC was always internally valid, but the mesh-to-JPEG semantic pairing is now actually what the code implies.
- `recordResult` reassigns the result's `frameIndex` to its upload-aligned position (`results.count` at record time), making `results[i].frameIndex == i` an invariant.
- If `processFrame` returns `nil` for a capture-eligible camera frame (face not detected this frame), the delegate **skips the `frameBuffer.shouldCapture()` check entirely** to avoid mutating `lastCaptureTime` and wasting a capture slot on a frame that cannot be paired.

#### Example app environment handling
- **`UseSenseConfig` environment now explicit** in the Example app. `UseSenseConfig.init(apiKey:)` without an explicit environment falls through to `Environment.detect(from:)`, which defaults to `.production` for any API key that does not literally start with `sk_sandbox_` / `pk_sandbox_` / `dk_sandbox_`. Real-world sandbox keys without a literal prefix were being silently routed to the production account and failing with 402 insufficient_credits. Example app now passes `environment: useProduction ? .production : .sandbox` explicitly from a toggle.
- **`.fullScreenCover(isPresented:)` split-state coordination bug** in the Example app fixed by switching to `.fullScreenCover(item:)` bound to a single `SessionWrapper: Identifiable` wrapper. The old two-state approach (`showVerification` + `activeSession`) had a SwiftUI evaluation-order bug where the cover's content closure could see `activeSession` as `nil` and render an empty cover.

### Fixed

- **Mesh integrity "possible replay" false positive.** Pre-4.2.0 sessions on a stable face tripped the backend's `MIN_SHAPE_VARIANCE` floor because the on-device 3DMM fitter was a degenerate weighted-sum stub. The new orthonormal projection (see Added) pushes variance to ~1e-4 in practice, consistently well above the floor.
- **Mesh integrity "binding tier" failure** on every iOS session. The canonical JSON format change (see Changed) makes the SDK's `meshDigest` byte-match the backend's `computeMeshDigest`, so the per-frame `bindingProof` HMAC now verifies end-to-end.
- **Per-frame "SDK frameIndex is not aligned with upload order" warning** the backend emits on every 4.1.0 session. Fixed at the wire level by the `VerificationPackageBuilder` change above and at the semantic level by the `FaceMeshManager` refactor.
- **Dirty `project.pbxproj` on every developer's clone** after opening the Example target in Xcode for signing. Team ID now lives in a gitignored `Signing.local.xcconfig` outside the project file.

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

[4.2.0]: https://github.com/qudusadeyemi/usesense-ios-sdk/releases/tag/v4.2.0
[4.1.0]: https://github.com/qudusadeyemi/usesense-ios-sdk/releases/tag/v4.1.0
[1.0.0]: https://github.com/qudusadeyemi/usesense-ios-sdk/releases/tag/v1.0.0
