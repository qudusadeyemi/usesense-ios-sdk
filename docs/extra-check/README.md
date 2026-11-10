# Extra check on the scan screen (iOS 4.11.0)

Storyboard flows 4 (after the scan), 5 (before the scan) and 6 (results and
errors). Screens use a synthetic, drawn face; no real person appears here.

- `after-challenge.jpg`: the round-2 sheet, Head Turn and Follow Dot, their
  pause and retry states, the done tick, the leave dialog, the upload-failed sheet.
- `after-pages.jpg`: "Two quick steps", Speak Digits, the microphone page,
  result and error pages.
- `after-inline.jpg`: the suspicion engine's inline step-up (RMAS actions,
  a Flash Reflection colour) on the scan screen.
- `before.jpg`: the screens these replace (still used with
  `guidedCaptureEnabled: false`).

## Reproduce

Debug build of the Example app on a simulator:

```
xcrun simctl launch <sim> ai.usesense.example -USESENSE_SCREEN head_left -USESENSE_FAKE_CAMERA /path/to/face.png
```

Names are in `UseSenseDebugScreen.names` (DEBUG only). Challenge screens are
produced by the real `ChallengeRunner`, driven with scripted observations.

## How it works

- `ChallengeRunner` (pure, unit tested) runs the challenge timeline from one
  observation per tick: face in the oval (centre within 0.55 x 0.45 oval radii,
  lost after 0.3 s, back after 0.15 s), head pose, microphone level.
- The face leaving the oval pauses the timeline; nothing fails on the device.
- Head Turn: a step counts as turned at 10 degrees of yaw (8 of pitch) by the
  face transform; one retry per challenge, direction left to the server.
- Follow Dot: the dot glides to each waypoint (0.6 s, or 40% of the step) and
  holds; the trail is the waypoints passed.
- Speak Digits: quiet below about -40 dB for 2 s; the timer keeps running.
