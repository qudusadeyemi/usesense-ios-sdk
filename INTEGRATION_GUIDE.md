# UseSense iOS Integration Guide

## How Verification Works

1. Your app creates a `UseSense` instance with your API key
2. When you need to verify a user (e.g., during onboarding), call `createSession()` or `startVerification()`
3. Present the session using `UseSenseView` (SwiftUI) or `UseSenseViewController` (UIKit)
4. The SDK presents a full-screen camera UI over your app
5. The user completes a short challenge (5-15 seconds): following a dot on screen, turning their head, or speaking a phrase
6. The SDK captures frames, motion sensor data, and optional audio, then uploads everything encrypted to UseSense servers
7. Server-side analysis runs three independent pillars (DeepSense, LiveSense, MatchSense) in parallel
8. The SDK receives a preliminary result -- use this for UI feedback (show success/failure screen)
9. The definitive verdict is delivered to **your backend** via HMAC-signed webhook -- this is what you use for access-control decisions
10. One credit is consumed per completed session, regardless of the decision outcome

```
┌──────────┐     ┌──────────────┐     ┌─────────────┐     ┌──────────────┐
│ Your App │     │ UseSense SDK │     │ UseSense API│     │ Your Backend │
└────┬─────┘     └──────┬───────┘     └──────┬──────┘     └──────┬───────┘
     │ UseSense(config) │                     │                   │
     │─────────────────>│                     │                   │
     │   instance       │                     │                   │
     │<─────────────────│                     │                   │
     │                  │                     │                   │
     │ createSession()  │                     │                   │
     │─────────────────>│                     │                   │
     │                  │ POST /v1/sessions   │                   │
     │                  │────────────────────>│                   │
     │                  │  challenge config   │                   │
     │                  │<────────────────────│                   │
     │   session        │                     │                   │
     │<─────────────────│                     │                   │
     │                  │                     │                   │
     │ Present          │                     │                   │
     │ UseSenseView     │                     │                   │
     │─────────────────>│                     │                   │
     │                  │                     │                   │
     │    [SDK presents camera UI, user completes challenge]      │
     │                  │                     │                   │
     │                  │ POST /signals       │                   │
     │                  │────────────────────>│                   │
     │                  │ POST /complete      │                   │
     │                  │────────────────────>│                   │
     │                  │   decision          │                   │
     │   onComplete     │<────────────────────│                   │
     │<─────────────────│                     │                   │
     │                  │                     │  webhook (verdict)│
     │                  │                     │──────────────────>│
     │                  │                     │                   │
```

## Why Three Independent Pillars?

Most verification providers return one confidence number. This creates a fundamental problem: if channel integrity fails but liveness passes, a single composite score hides the risk.

UseSense scores each dimension independently:

- **DeepSense** (Channel & Device Integrity): Is the device trustworthy? App attestation, runtime integrity checks, capture pipeline analysis, motion-sensor correlation. Produces a `channelTrustScore` (0-100).

- **LiveSense** (Multimodal Proof-of-Life): Is this a live human? Facial dynamics, visual integrity, temporal coherence, presentation attack detection, environmental corroboration, challenge compliance, audio authenticity. Produces a `livenessScore` (0-100).

- **MatchSense** (Identity Collision Detection): Is this the right person? 1:N face search for duplicate detection (enrollment), 1:1 face verification (authentication), cross-identity risk scoring. Produces a `matchSenseRiskScore` (0-100).

A critical failure in any pillar cannot be masked by strong scores in others. Default verdict logic is "weakest link" -- any pillar failing results in REJECT. Organizations can configure alternative logic in the dashboard: majority vote, or weighted composite.

**Note:** Pillar scores are intentionally withheld from the SDK result (`RedactedDecisionObject`). This prevents client-side tampering. Full scores are delivered to your backend via webhook.

## Choosing a Session Type

| Use Case | Session Type | Notes |
|----------|-------------|-------|
| User onboarding | `.enrollment` | First-time face registration. Creates an identity record. |
| Account creation | `.enrollment` | 1:N duplicate scan detects if the face is already enrolled. |
| Login verification | `.authentication` | Requires `identityId` from a prior enrollment. |
| Transaction confirmation | `.authentication` | 1:1 verification against enrolled template. |
| Periodic re-verification | `.authentication` | Same as login verification. |

Both session types run all three pillars. The difference:
- **Enrollment** creates a new identity record and performs a 1:N scan for duplicates.
- **Authentication** requires an existing `identityId` and performs 1:1 verification plus a 1:N cross-identity scan.

```swift
// Enrollment: no identityId needed
let enrollSession = useSense.createSession(type: .enrollment)

// Authentication: identityId required
let authSession = useSense.createSession(
    type: .authentication,
    identityId: "idn_abc123"  // From a previous enrollment webhook
)
```

## Challenge Policies

Challenges are server-configured per session. The SDK presents the challenge UI automatically. Three policies are available (configured in the dashboard or via `stepUpPolicy`):

### Standard
Fixed challenge set, predictable UX. Good for most use cases. Typical challenge: follow a dot on screen for 3-5 seconds.

### Enhanced
More demanding challenges, higher security, slightly longer session. May combine multiple challenge types (e.g., head turn + speak phrase).

### Adaptive (SenSei)
AI selects challenges based on real-time risk signals. If the device looks suspicious (e.g., failing App Attest, detected hooking frameworks), harder challenges are presented automatically. This is the recommended policy for high-value transactions.

```swift
let config = UseSenseConfig(
    apiKey: "your_api_key",
    options: SDKOptions(
        stepUpPolicy: .riskBased  // Let SenSei decide (default)
    )
)
```

## Handling the Verdict in Your App

### On the Client (SDK Result)

The SDK returns a `RedactedDecisionObject` with the decision but without pillar scores. Use it for immediate UI feedback:

```swift
UseSenseView(
    session: session,
    onComplete: { result in
        switch result {
        case .success(let decision):
            if decision.isApproved {
                // Show success screen
                // Navigate to next step in your flow
                showSuccessScreen()
            } else if decision.isRejected {
                // Show failure screen with option to retry
                showRejectionScreen()
            } else if decision.isPendingReview {
                // Show "verification in progress" state
                // The final decision will arrive via webhook
                showPendingScreen()
            }
        case .failure(let error):
            // Show error with recovery suggestion
            showErrorScreen(error: error)
        }
    },
    onCancel: { /* user dismissed */ }
)
```

**NEVER gate access based solely on the SDK result.** The SDK runs on the user's device and can be tampered with.

### On Your Backend (Webhook)

The webhook is the authoritative source of truth. Your backend should:

1. Verify the HMAC-SHA256 signature (see README for code examples)
2. Map the decision to your business logic:
   - `approved`: activate the account, authorize the transaction, etc.
   - `rejected`: deny the request, flag for investigation
   - `manual_review`: queue for human review, or apply your own risk rules
3. Optionally inspect pillar scores for fine-grained decisions

### Retry Logic

- If a session fails due to network or timeout, start a new session. Sessions cannot be resumed.
- If a session is rejected, allow the user to retry (recommend a limit of 3 attempts).
- Each retry is a new session and consumes one credit in production.

```swift
var retryCount = 0
let maxRetries = 3

func startVerification() {
    guard retryCount < maxRetries else {
        showMaxRetriesReached()
        return
    }

    let session = useSense.createSession(type: .enrollment)
    presentVerification(session: session) { result in
        switch result {
        case .success(let decision):
            if decision.isRejected {
                retryCount += 1
                showRetryOption()
            } else {
                handleDecision(decision)
            }
        case .failure(let error):
            if error.isRetryable {
                retryCount += 1
                showRetryOption()
            } else {
                showError(error)
            }
        }
    }
}
```

## Data Privacy

- The SDK captures face images and optional audio. These are uploaded encrypted (TLS 1.3) and processed server-side.
- **No biometric data is stored on the user's device.** Frames are held in memory during the session and discarded immediately after upload.
- Face templates are stored server-side in your organization's isolated collection.
- Sessions have configurable data retention policies (set in the dashboard).
- UseSense supports GDPR/CCPA privacy requests:
  - **Access**: Users can request their stored biometric data.
  - **Deletion**: Users can request deletion of their face template and session data.
  - **Portability**: Users can request an export of their data.
  - **Correction**: Users can request re-enrollment if their template is outdated.
- The SDK includes a privacy manifest (`PrivacyInfo.xcprivacy`) declaring all data collection for App Store compliance.

## Going to Production

### Pre-Launch Checklist

1. **Switch API key**: Replace your sandbox key (`sk_` prefix) with your production key (`pk_` prefix) in `UseSenseConfig`.
2. **Verify environment**: Confirm the SDK is targeting production (auto-detected from `pk_` prefix, or set explicitly).
3. **Purchase credits**: Production sessions consume one credit each. Purchase credits in the [UseSense dashboard](https://app.usesense.ai).
4. **Configure webhook endpoint**: Set your production webhook URL in the dashboard. Ensure your backend is handling HMAC signature verification.
5. **Test end-to-end**: Run the full flow on a physical device in production. Simulators do not have cameras.
6. **Handle all decision types**: Ensure your backend handles `approved`, `rejected`, and `manual_review`.
7. **Set up billing alerts**: Configure the `billing.credits_low` webhook event to get notified when credits are running low.
8. **Privacy manifest**: Ensure `PrivacyInfo.xcprivacy` is included in your app bundle for App Store submission.
9. **Info.plist entries**: Confirm `NSCameraUsageDescription` (and `NSMicrophoneUsageDescription` if using audio) are present with user-facing strings.

### Environment Comparison

| Aspect | Sandbox | Production |
|--------|---------|------------|
| API key prefix | `sk_` / `dk_` | `pk_` |
| Billing | Free, unlimited | 1 credit per session |
| Face collection | Shared across sandbox users | Isolated per organization |
| Webhooks | Sent to sandbox webhook URL | Sent to production webhook URL |
| Features | Identical | Identical |
| SLA | Best effort | Per your plan |
