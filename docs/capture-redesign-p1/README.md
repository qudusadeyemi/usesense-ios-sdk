# Capture screen: test rig (DEBUG builds only)

The guided capture screen follows the LiveSense capture test kit spec v1.1 (`capture-test-kit/SPEC.md`, reference `capture-test-kit/reference/index.html`). The kit lives outside this repo. To compare against its goldens with no camera, run the Example app on an iPhone 16 simulator (393×852 pt):

```
xcrun simctl launch booted ai.usesense.example \
  -USESENSE_CAPTURE_PREVIEW 1 \
  -USESENSE_FAKE_CAMERA /path/to/capture-test-kit/fixtures/face-portrait.mp4 \
  -FREEZE_AT 4.0 -FORCE_STATE scan -FORCE_PROGRESS 0.5
```

| Option | Effect |
|---|---|
| `USESENSE_FAKE_CAMERA` | A video (AVAssetReader, looped at 30 fps) or a still image replaces the camera. Frames go through the real pipeline: MediaPipe mesh, quality gate, contour and preview. |
| `FREEZE_AT` | Seek the video to this time and hold that frame. |
| `FORCE_STATE` | `align`, `scan` or `upload`: hold the screen in that state (no auto start). |
| `FORCE_PROGRESS` | Scan ring progress when forced (0–1). |
| `FORCE_HINT` | Pin one instruction, using the reference's `?hint=` keys (`centre`, `dark`, `closer`, ...). |
| `USESENSE_DEBUG_GATE` | `1` shows the gate debug chips (off by default; never in release). |
| `USESENSE_CAPTURE_PREVIEW` | Example app only: opens the capture screen on a stand-in session (no API key, no network). |

Every option is read from launch arguments or the environment, and all of it is compiled out of release builds (`#if DEBUG`).

Compare a screenshot with a golden: `ffmpeg -i ios-scan.png -i golden/scan-393x852.png -filter_complex hstack compare.png`. The fixture shows a real person, so keep those images local.
