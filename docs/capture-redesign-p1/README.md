# Capture redesign P1 screenshots

`sim-*.png`: the Example app on the iOS simulator running the real pipeline (MediaPipe mesh, quality gate, scan, contour). The simulator has no camera, so frames come from a still photo via `USESENSE_SIM_CAMERA`:

```
SIMCTL_CHILD_USESENSE_SIM_CAMERA=/path/to/portrait.jpg \
SIMCTL_CHILD_USESENSE_CAPTURE_PREVIEW=1 \
xcrun simctl launch booted ai.usesense.example
```

Photo: official NASA portrait of astronaut Jack Hathaway (jsc2025e068207), a US Government work in the public domain, via Wikimedia Commons. It is cropped to selfie framing and, for the low-light shots, darkened by 2.6 EV.

`render-*.png`: SwiftUI renders from `GuidedCaptureSnapshotTests` (synthetic face) for states the still photo can't reach (upload sheet, custom colours).
