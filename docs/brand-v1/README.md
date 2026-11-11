# Capture screens follow the brand (BRAND-v1, iOS 4.11.0)

Simulator screenshots (iPhone 16, iOS 26.3) of the guided capture screens for
the three BRAND-v1 section 8 brands. The camera is a drawn, synthetic face; no
real person appears here.

Each sheet, left to right, top to bottom: "Two quick steps" primer, align
(failing oval), scan, Head Turn, "One more quick check" sheet, upload sheet,
approved, rejected (retry), leave dialog, help dialog, "Getting ready".

- `sense-default.jpg`: no brand set (today's dark look).
- `acme-bank.jpg`: light mode, green primary, Georgia titles, pill buttons, logo.
- `night-pay.jpg`: dark mode, low-contrast primary `#3A1D8F` (the ring comes out
  lightened), pink `capture.challenge`, outline buttons with radius 4.

## Reproduce

Debug build of the Example app:

```
xcrun simctl launch <sim> ai.usesense.example -USESENSE_SCREEN approved -USESENSE_FAKE_CAMERA /path/to/face.png -USESENSE_BRAND acme
xcrun simctl launch <sim> ai.usesense.example -USESENSE_CAPTURE_PREVIEW 1 -USESENSE_FAKE_CAMERA /path/to/face.png -FORCE_STATE scan -FORCE_PROGRESS 0.6 -USESENSE_BRAND nightpay
```

`-USESENSE_BRAND` takes `acme` or `nightpay` (DEBUG only, `UseSenseDebugBrand`).
