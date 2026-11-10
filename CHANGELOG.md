# Changelog

All notable changes to the UseSense iOS SDK will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **LiveSense evidence contract (EVIDENCE-v1, capture redesign Phase 2).**
  The server scores depth and binding itself; the SDK collects and uploads
  the raw evidence. Everything is additive: a session whose server sends no
  `evidence` block (or another contract version) uploads exactly as before.
  - The optional `evidence` block is decoded on every init path (session
    create, token exchange, Flows, hosted). Every key is optional, unknown keys
    are ignored, and a malformed key reads as absent.
  - Per frame in `verification_package.frames`: raw MediaPipe `landmarks`
    (478 points, uploaded-JPEG space, unmirrored, 5 decimals, bound into
    `meshDigest`), `transformMatrix` and the matrix pose under
    `poseNormalizationMethod: "matrix_zyx_v3"`, `blendshapes.eyeBlinkLeft/Right`,
    and `timestamp` on the capture clock (ms since the camera's first frame).
  - `frameIndex` is the upload position. A frame whose 3D fit failed has no
    entry instead of shifting every later frame, and two uploads with the same
    bytes get one entry.
  - Colour sequence: during the scan the screen is tinted with the server's
    three colours (35%, 0.6 s each, full brightness, white balance locked)
    with no new copy. What was shown, as measured from the display link, goes
    in `metadata.evidence.colour`. A gate pause stops the tint and drops the
    partly shown colour; the sequence resumes at that colour when the scan
    does, so the segments stay in the issued order the server checks. A
    dropped scan window clears the segments and starts again at the first
    colour.
  - Closer step: when the ring completes, the oval grows by the server's
    `target_scale` and the existing "Move a little closer" guidance shows
    until the face reaches `min_scale`. Three near frames bank, recorded with
    the last three scan frames in `metadata.evidence.closer`. After 4 s it
    gives up (`skipped_reason: "timeout"`) and the capture carries on.
  - Binding v2: an App Attest assertion over the evidence digest
    (`metadata.evidence.binding`), alongside the v1 `bindingProof`.
  - `metadata.evidence.capability` says what this build can do: no MediaPipe
    means no landmarks, and no App Attest means no binding v2.

## [4.11.0] - Unreleased

Built against the agreed end-user storyboard (flows 4 to 6). Screens checked
on an iPhone 16 simulator with a synthetic face; not yet run on a device
against staging.

### Added

- **Extra check on the scan screen.** When the server asks for an extra check
  after the scan (step-up round 2, `step_up_v1`), a "One more quick check"
  sheet says what is next in one sentence, then Head Turn or Follow Dot runs
  on the scan screen itself: full-bleed camera, the oval ring in purple,
  a side arrow ("Turn your head to the left", "Now to the right") or an amber
  dot with a dashed trail ("Follow the dot with your head"). A short green
  tick, then the upload sheet and the result. Replaces the countdown and the
  old challenge overlays on guided screens.
- **Extra check before the scan.** A session whose policy already has a
  challenge opens with "Two quick steps", and the movement follows straight
  on from the scan on the same screen, with no countdown or sheet. The scan
  before it is gated like the passive scan.
- **Speak Digits on the scan screen**: the digits in a pill at the top, a live
  microphone meter under the oval, "We can't hear you / Speak a little louder"
  after 2 s of silence. The digits' response is sent as
  `audio_challenge_response`.
- **Microphone fallback.** A refused microphone (or no input) shows
  "Microphone needed" with "Open Settings" and "Do a head movement instead".
  The second calls `POST /v1/sessions/:id/challenge-fallback`
  (`{"reason":"microphone_unavailable"}`), and the capture carries on with
  the Follow Dot the server returns.
- **The scan's checks hold during challenges too** (before the scan and
  round 2): face found, one person, covered face (segmenter), distance (with
  the scan's hold margin), in the oval, sharpness, eyes open, and stillness
  for Speak Digits (chin left out). Only pose relaxes, toward the movement
  the current step asks for (sideways turns: yaw to 50 degrees; up/down:
  pitch to 40; centre and Follow Dot: 30 to 40). A failing check pauses the
  challenge, frames aren't banked while paused, and the guidance names the
  check ("Keep your face uncovered / Then keep turning"). The scan's change
  watch is off during movement (a turning head changes every face region).
- **Never fails on the device.** A paused challenge resumes when the check
  passes again. A Head Turn step that was
  clearly too short gets one retry with a hint ("Let's try that again / Turn
  a little further to the left"); after that the server decides.
- **"Leave verification?"** on back during an extra check (the challenge
  holds while it is open). Leaving ends the verification.
- **New result and error pages** on guided screens: verified, checking,
  couldn't verify (with or without "Try again" and tips), camera access
  needed (Open Settings / Try again), the camera stopped, offline, timed out,
  something went wrong, and a "Couldn't send your scan" sheet that resends
  the kept scan.
- `SDKOptions.showsResultScreen` (default true): false reports the decision
  without the SDK's result screen.
- `SDKOptions.retriesAfterReject` (default 0): how many times the person may
  try again from "We couldn't verify you". Standalone sessions only.

### Changed

- **Round 2's upload carries round 1's signals** for its own frames, in the
  same keys: `channel_integrity` (with screen detection), `device_telemetry`,
  `face_mesh_signals`, `verification_package` (when the session asks for the
  mesh), `suspicion`, `deep_classifier_on_device`, `frame_hashes`, frames
  manifest and timestamps, plus `step_up_round: 2`. Round 2's mesh, suspicion
  score and sensors start fresh; App Attest fields are reused from round 1.

- Guided screens ask for camera and microphone permission with the system
  prompt directly, without the "Camera Access Required" card.
- **Inline step-up on the scan screen.** When the policy's `inline_step_up`
  is enabled (dashboard: "Unusual movement during the scan") and the
  suspicion engine fires, guided screens show each RMAS micro-action as plain
  guidance under the oval with an amber ring ("Blink twice", "Turn your head
  to the left", ...) and fill the screen with each Flash Reflection colour,
  instead of the "Additional Verification" overlay. It runs before the
  upload, so a server extra check (round 2) still follows it.

### Fixed

- RMAS judged its micro-actions on the last banked frame, which stops
  updating when the scan ends; it now reads the newest face. Flash
  Reflection sampled no frame and showed no colour, so every flash read as no
  reflection (and the average change fell under the hard-reject floor); it
  now shows each colour and samples the camera. Applies to the previous
  screens too.

## [4.10.0] - 2026-11-10

Tested on an iPhone 17 Pro against the sandbox API, and on an iPhone 16
simulator against the LiveSense capture test kit's reference screens.

### Added

- **Guided face capture (LiveSense capture redesign, Phase 1).** The capture
  screen waits for a good face before it starts: found, one person, uncovered,
  the right distance, in the oval, facing the screen, sharp, eyes open and
  still. These checks run on the face mesh and on the face area, and they hold
  the scan instead of warning. Light is advice only: a dark face turns the
  screen into a warm fill light and gets a hint, but never blocks. One hint
  shows at a time (it must fail for 400 ms and stays at least 1.2 s), with a
  VoiceOver announcement. The scan (~3 s) starts by itself when every check
  passes, so the "I'm Ready" button is gone; a failing check pauses the
  progress ring instead of restarting it, and a pause over 1.5 s returns to
  the align screen. A shutter button appears after 20 s or 3 dropped scans.
  Focus and exposure follow the face. Challenge sessions keep their
  challenge; the gate only decides when it starts.
- **Contour scan.** Lines across the screen bulge around the head and bend
  over the nose, brow and lips (relief v3.1), in the ring colour; the camera
  blurs 1.5 s into the scan. Display only.
- **Covered-face check.** A hand, phone or paper over the face holds the scan
  with "Keep your face uncovered". It uses MediaPipe's multiclass selfie
  segmentation (bundled, see below) on its own queue, plus a change watch on
  six face regions during the scan (a steady baseline, two consecutive
  frames, fill light frozen during the scan). A finished scan waits up to
  2.5 s for one last check. Without the model the check is off and capture
  works as before.
- **Upload sheet.** The face is blurred behind a bottom sheet with a progress
  bar that keeps moving while the server checks ("Usually under 10 seconds").
- `FlowAppearance.capture` (`ring`, `contourStart`, `contourEnd`, `warning`)
  sets the capture colours. A colour under 3:1 contrast on the camera scrim
  falls back to the default. (`contourStart`/`contourEnd` are accepted but no
  longer drawn: the contour uses the ring colour.)
- `SDKOptions.guidedCaptureEnabled` (default `true`). Set it to `false` to keep
  the previous screen.
- DEBUG-only capture rig: a fake camera fed by a video or image, plus
  `FREEZE_AT`, `FORCE_STATE`, `FORCE_PROGRESS` and `FORCE_HINT`, to render the
  screens against the test kit without a camera. Compiled out of Release.

### Changed

- **Signals metadata gains `covered_check`** (guided capture only): the
  covered-face scores, numbers only (no images or landmarks), for tuning the
  limits. The server stores metadata whole; frames and scoring are unchanged.
- **One person:** a second face overlapping the subject by IoU 0.3 or more is
  the same face found twice, not another person.
- **Upload retries now run.** Each signals upload attempt gives up after 20 s
  with no bytes moving (was 60 s, the same as the session watchdog's stall
  window, which cancelled the retries unused), and each retry counts as
  progress for the watchdog. With `USESENSE_DEBUG=1` the trace logs upload
  progress.

### Size

- The pod grows by **16.4 MB**: the covered-face model
  (`selfie_multiclass_256x256.tflite`, float32 v1, sha256 `c6748b12…`) is in
  the `UseSenseSDK` resource bundle.

## [4.9.0] - 2026-11-07

Tested on an iPhone 17 Pro in session mode and in a Flow, against the sandbox
API.

### Changed

- **Capture screens match Android.** The result shows the org's logo header
  (the logo alone; the name only without a logo), and the capture screens carry
  a "Powered by Sense" footer.
- **No "Try Again" on the result inside a Flow.** The server settles the run
  when the capture completes, so a retry there captured a session that counted
  for nothing; the Flow's own policy decides retries. Standalone sessions keep
  "Try Again" on a reject.

- **One branding precedence everywhere: code wins, field by field.** For each
  field (colour, font, radius, logo, name, copy...), a value set in code beats
  the dashboard, the dashboard beats the built-in defaults, and nothing counts
  unless it was explicitly set. Setting only a colour in code no longer hides
  the dashboard logo.
- **Session mode shows the dashboard branding.** The org's branding delivered
  with the session (`branding` on the session-create / token-exchange /
  init-session response) now themes the capture screens underneath any
  code-set branding. Previously only code-set branding applied outside Flows.
- **Unset is unset.** `BrandingConfig.buttonRadius` no longer counts as a code
  choice unless passed (its legacy default of 10 used to beat a dashboard
  radius), and the Flow run view no longer fills a missing `display_name` /
  `primary_color` with "Sense" / `#4F7CFF`.
- With `USESENSE_DEBUG=1` the trace logs the source of each resolved branding
  field once per session/run, e.g. `primary=#FF6A00 (dashboard)`.

**API:** `FlowRunView.Branding.displayName` and `.primaryColor` are now
optional. `BrandingConfig(buttonRadius:)` takes `CGFloat?` (source-compatible).
`CreateSessionResponse.branding` and `ServerBranding.appearance` / `.copy` are new.

### Fixed

- **"Verifying your presence" could spin forever.** The watchdog's own timeout
  error was discarded as belonging to a stale attempt, so a stalled upload or
  completion never reached the error screen. It now always surfaces.
- **A dead connection fails in 60 s, not 300 s.** The upload idle timeout was
  five minutes.
- **Captures and Flows never hang silently.** Capture, upload, completion and
  the Flows runner are time-limited (the runner waits 90 s, as on Android) and
  end in `capture_timeout`, `upload_timeout` or `run_timeout`.
- **Retry finishes the same capture.** After an upload or completion failure,
  "Retry" keeps the session and the frames: it calls `/complete` again if the
  signals were accepted, otherwise re-uploads the same capture. It used to
  start a new session and recapture, which could reject the person against
  their own just-enrolled face. "Start over" still recaptures.
- **Verdicts always decode.** Scores may be fractional, detail blocks that
  drift become nil instead of failing the decision, `dedupe_analysis` is read
  in the server's camelCase, and the v4 envelope (`verdict`) is accepted. An
  unreadable response is `RESPONSE_INVALID`, not a server error with Swift's
  "data couldn't be read" text.
- **One capture per tap.** "Got it - Start" and "I'm Ready" can't start a
  second capture, and a capture round completes exactly once.
- **The capture clock starts on the camera's first frame**, not on the tap.
- **Plain-language errors.** The error screen shows copy chosen from the error
  code (connection, capture, expired, unavailable, generic) and never the
  server's raw message; the code is a caption. HTTP 403 maps to
  `UNAUTHORIZED`.

### Added

- Opt-in on-device trace: launch with `USESENSE_DEBUG=1` to log each step and
  network call; it is also written to `Library/Caches/usesense-trace.log`.
- Error codes `NO_FRAMES_CAPTURED` (retryable, same wire code as Android) and
  `RESPONSE_INVALID`.

## [4.8.2] - 2026-10-09

### Added

- **Face init-session sends a device binding.** When a flow's face step
  starts, the runner sends the stable signals the server hashes into the device
  fingerprint, plus this device's existing App Attest key id
  (`device_binding`). The server then reuses a Device Trust check from earlier
  in the run only if it came from this device, instead of matching on platform
  and device model alone. Collection makes no App Attest network call, is
  capped at 1.5 s and never blocks the face step.

## [4.8.1] - 2026-10-08

### Fixed

- **The face-capture screens take the org's brand colour.** Inside a branded
  Flow, the challenge instructions, "Almost done", challenge, step-up and result
  screens stayed UseSense blue while the runner's own screens took the org
  colour. `Color.UseSense.primary` (and `primaryBg`, `primaryLight`,
  `primaryDark`, `qualityInfo`, `focusRing`, `instructionIconBg`) now follow the
  resolved appearance and fall back to DeepSense Blue. Text on brand-filled
  buttons uses `primaryForeground`. The instructions screen uses the theme's
  neutrals in place of hardcoded greys and white. A standalone
  `UseSenseViewController` themes from its own `BrandingConfig` when no Flow
  runner has set one. The dark backdrops over the camera stay dark.
- **A Device Trust step without a nonce no longer spins forever.** The runner
  re-reads the run once to pick up the nonce (the server mints it for a client
  that declares `device_signals_v1`). If it is still missing, the run now ends
  with `FlowError(.unknown, "Device Trust step is missing its nonce")` instead
  of leaving the spinner up. Same rule as the Android SDK.

## [4.8.0] - 2026-10-08

### Added

- **Camera-free Device Trust.** The Flows runner declares `device_signals_v1`
  (`?caps=` on load, `client.capabilities` on advance). A Device Trust step
  then arrives as `PendingAction.captureDevice(toolId:nonce:)`: the runner
  shows "Checking your device", collects the same channel integrity as a face
  capture minus the camera and microphone fields (no camera, no prompt), signs
  an App Attest assertion over the step's nonce (bounded at 5 s), and posts it
  to `/v1/sdk/flow-runs/:id/device-signals`. A stale nonce or an already-settled
  step re-reads the run. `PendingAction` gains a case, so an exhaustive
  `switch` over it in host code needs a new branch.
- **Server step-up (round 2).** When a server Step-up rule matches the uploaded
  capture, the `/signals` response now carries a `step_up` instruction. The
  session restarts the camera behind a 3-2-1 countdown, presents the requested
  Head Turn or Follow Dot on a fresh frame buffer (capped at the server's
  `max_frames`), uploads it with `?round=2`, then completes. An instruction
  this SDK can't render is ignored and the session completes as before (the
  server then sends it to review).
- The SDK declares `capabilities: ["step_up_v1"]` on create, exchange and
  Flow `init-session`, and `client_capabilities` in the upload metadata (the
  only place a backend-created or remote session can declare it).

### Fixed

- **`UploadSignalsResponse` decoding is tolerant.** `audio_received` and
  `metadata_received` were required, so any response that omitted them (a
  round-2 upload does) failed to decode and the upload was reported as an
  error. A `step_up` with a challenge type this SDK doesn't know no longer
  fails the whole response either.

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

## [4.7.0] - 2026-08-07

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
