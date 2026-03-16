# UseSense iOS SDK

Native iOS SDK for human presence verification. Verify real humans, detect deepfakes, and prevent identity fraud with three independent verification pillars.

## Requirements

- iOS 15.0+
- Xcode 15.0+
- Swift 5.9+
- Device with front-facing camera (required)
- Device with motion sensors (recommended, improves DeepSense accuracy)

## Installation

### CocoaPods

Add to your Podfile:

```ruby
pod 'UseSenseSDK', '~> 1.0'
```

Then run:

```bash
pod install
```

Open the `.xcworkspace` file (not `.xcodeproj`).

### Swift Package Manager

In Xcode: **File > Add Package Dependencies**, enter:

```
https://github.com/usesense/usesense-ios-sdk.git
```

Select version "Up to Next Major" from `1.0.0`.

Or add to your `Package.swift`:

```swift
.package(url: "https://github.com/usesense/usesense-ios-sdk.git", from: "1.0.0")
```

### Manual Installation

1. Download `UseSenseSDK.xcframework` from the [latest GitHub Release](https://github.com/usesense/usesense-ios-sdk/releases/latest)
2. Drag it into your Xcode project
3. In your target's **General** tab, ensure it appears under "Frameworks, Libraries, and Embedded Content" set to **Embed & Sign**

## Quick Start

```swift
import UseSenseSDK

// 1. Configure the SDK
let config = UseSenseConfig(
    apiKey: "your_sandbox_api_key"  // sk_ prefix = sandbox, pk_ prefix = production
)
let useSense = UseSense(config: config)

// 2. Create a verification session
let session = useSense.createSession(type: .enrollment)

// 3. Present the verification UI (SwiftUI)
UseSenseView(
    session: session,
    onComplete: { result in
        switch result {
        case .success(let decision):
            print("Decision: \(decision.decision)")
            print("Session ID: \(decision.sessionId)")
            if let identityId = decision.identityId {
                print("Identity ID: \(identityId)")
            }
        case .failure(let error):
            print("Error: \(error.code.rawValue) - \(error.message)")
        }
    },
    onCancel: {
        print("User cancelled verification")
    }
)

// The definitive verdict arrives at your backend via webhook.
// The SDK result is for UI feedback only.
```

### UIKit Integration

```swift
import UseSenseSDK

let config = UseSenseConfig(apiKey: "your_sandbox_api_key")
let useSense = UseSense(config: config)
let session = useSense.createSession(type: .enrollment)

let viewController = UseSenseViewController(
    session: session,
    onComplete: { result in
        // Handle result
    },
    onCancel: {
        // Handle cancellation
    }
)
present(viewController, animated: true)
```

## Configuration

### UseSenseConfig

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `apiKey` | `String` | Required | Your API key from the [UseSense dashboard](https://app.usesense.ai). Keys prefixed with `sk_` or `dk_` target sandbox; `pk_` targets production. |
| `apiEndpoint` | `String` | UseSense API | API endpoint URL. Override only for on-premise deployments. |
| `environment` | `Environment?` | Auto-detected | `.sandbox`, `.production`, or `.auto`. Auto-detection uses the API key prefix. |
| `branding` | `BrandingConfig?` | `nil` | Customize the verification UI appearance. |
| `options` | `SDKOptions?` | `nil` | Advanced capture and behavior options. |

### BrandingConfig

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `logoUrl` | `String?` | `nil` | URL to your organization's logo, displayed in the verification UI. |
| `primaryColor` | `String` | `"#4F63F5"` | Primary accent color (hex). Used for buttons and highlights. |
| `buttonRadius` | `CGFloat` | `12` | Corner radius for buttons in the verification UI. |
| `fontFamily` | `String?` | `nil` | Custom font family name. Falls back to system font. |

### SDKOptions

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `audioEnabled` | `AudioMode` | `.riskBased` | `.never`, `.riskBased`, or `.always`. Controls audio capture for voice deepfake detection. |
| `stepUpPolicy` | `StepUpPolicy` | `.riskBased` | `.never`, `.riskBased`, or `.always`. Controls challenge difficulty escalation. |
| `captureDurationMs` | `Int` | `2500` | Duration of the capture phase in milliseconds. |
| `targetFps` | `Int` | `15` | Target frame capture rate. |
| `maxFrames` | `Int` | `40` | Maximum number of frames to capture per session. |
| `maxUploadSizeMb` | `Int` | `10` | Maximum upload payload size in megabytes. |

## Session Types

### Enrollment

First-time face registration. The system captures the user's face, performs a 1:N duplicate scan across all enrolled identities in your organization, and creates an identity record if approved.

```swift
let config = UseSenseConfig(apiKey: "your_api_key")
let useSense = UseSense(config: config)

let session = useSense.createSession(type: .enrollment)

// Or use the VerificationRequest pattern:
let session = useSense.startVerification(
    request: VerificationRequest(
        sessionType: .enrollment,
        externalUserId: "user_123"  // Your internal user identifier
    )
)
```

### Authentication

Returning user claims an existing identity. The system performs 1:1 face verification against the enrolled template, plus a 1:N cross-identity scan to detect identity swapping. The `identityId` must reference a previously enrolled identity.

```swift
let session = useSense.createSession(
    type: .authentication,
    identityId: "idn_abc123"  // From a previous enrollment
)

// Or use the VerificationRequest pattern:
let session = useSense.startVerification(
    request: VerificationRequest(
        sessionType: .authentication,
        identityId: "idn_abc123"
    )
)
```

## Handling Results

The SDK returns a `RedactedDecisionObject`. Scores are intentionally withheld from the client for security -- detailed pillar scores are delivered to your backend via webhook.

### RedactedDecisionObject

| Field | Type | Description |
|-------|------|-------------|
| `sessionId` | `String` | Unique session identifier. |
| `sessionType` | `String?` | `"enrollment"` or `"authentication"`. |
| `identityId` | `String?` | Identity ID. Present on successful enrollment or authentication. |
| `decision` | `String` | `"APPROVE"`, `"REJECT"`, or `"MANUAL_REVIEW"`. |
| `timestamp` | `String` | ISO 8601 timestamp of the decision. |
| `isApproved` | `Bool` | Convenience: `true` if decision is `APPROVE`. |
| `isRejected` | `Bool` | Convenience: `true` if decision is `REJECT`. |
| `isPendingReview` | `Bool` | Convenience: `true` if decision is `MANUAL_REVIEW`. |

### Handling Each Decision Type

```swift
UseSenseView(
    session: session,
    onComplete: { result in
        switch result {
        case .success(let decision):
            if decision.isApproved {
                // Proceed with onboarding/login
                // The webhook will confirm this on your backend
                navigateToSuccess(identityId: decision.identityId)
            } else if decision.isRejected {
                // Show rejection screen, optionally allow retry
                showRejectionScreen(sessionId: decision.sessionId)
            } else if decision.isPendingReview {
                // Show "verification in progress" screen
                // Wait for backend webhook to determine final outcome
                showPendingReviewScreen()
            }
        case .failure(let error):
            handleError(error)
        }
    },
    onCancel: {
        // User dismissed the verification UI
        handleCancellation()
    }
)
```

## Event Listening

Subscribe to real-time session lifecycle events:

```swift
let useSense = UseSense(config: config)

// Global listener (receives events from all sessions)
let removeListener = useSense.onEvent { event in
    switch event.type {
    case .sessionCreated:
        // Session created, camera UI about to appear
        let sessionId = event.data?["session_id"]
        print("Session created: \(sessionId ?? "")")

    case .permissionsRequested:
        print("Requesting camera/microphone permissions")

    case .permissionsGranted:
        print("Permissions granted")

    case .permissionsDenied:
        let type = event.data?["type"]  // "camera" or "microphone"
        print("Permission denied: \(type ?? "")")

    case .captureStarted:
        print("Frame capture started")

    case .frameCaptured:
        let count = event.data?["count"]
        print("Frame captured: \(count ?? "")")

    case .challengeStarted:
        let type = event.data?["type"]  // "follow_dot", "head_turn", "speak_phrase"
        print("Challenge presented: \(type ?? "")")

    case .challengeCompleted:
        print("Challenge completed, uploading signals")

    case .uploadStarted:
        print("Uploading signals to server")

    case .uploadCompleted:
        print("Upload complete")

    case .completeStarted:
        print("Server-side analysis in progress")

    case .decisionReceived:
        let decision = event.data?["decision"]
        print("Decision received: \(decision ?? "")")

    case .imageQualityCheck:
        let score = event.data?["score"]
        let acceptable = event.data?["acceptable"]
        print("Quality: \(score ?? "") acceptable: \(acceptable ?? "")")

    case .error:
        let code = event.data?["code"]
        let message = event.data?["message"]
        print("Error: \(code ?? "") - \(message ?? "")")

    default:
        break
    }
}

// Per-session listener
let session = useSense.createSession(type: .enrollment)
let removeSessionListener = session.addEventListener { event in
    // Same event types as above
}

// Remove listeners when done
removeListener()
removeSessionListener()

// Or clear all global listeners
useSense.reset()
```

## Error Handling

### Error Codes

| Code | Description | Recovery |
|------|-------------|----------|
| `CAMERA_UNAVAILABLE` | No suitable front-facing camera found | Inform user they need a device with a front camera. |
| `CAMERA_PERMISSION_DENIED` | Camera access not granted by user | Prompt user to enable in Settings. Show deep link to app settings. |
| `MIC_PERMISSION_DENIED` | Microphone access not granted (audio enabled) | Prompt user to enable in Settings or disable audio. |
| `NETWORK_ERROR` | UseSense API is unreachable | Check device connectivity. Retry with exponential backoff. |
| `NETWORK_TIMEOUT` | Request timed out | Retry the session. Check if device is on a restricted network. |
| `SESSION_EXPIRED` | 15-minute server-side session expiry reached | Start a new session. This is a hard server limit. |
| `UNAUTHORIZED` | API key rejected by server | Verify the key in your UseSense dashboard. Check environment (sandbox vs production). |
| `INVALID_TOKEN` | Session token is invalid | Start a new session. |
| `SESSION_NOT_FOUND` | Session does not exist on the server | Start a new session. |
| `IDENTITY_NOT_FOUND` | `identityId` does not exist (authentication session) | Verify the identity was previously enrolled successfully. |
| `INVALID_REQUEST` | Invalid request parameters | Check request parameters. |
| `INVALID_CONFIG` | Missing or invalid configuration | Check `apiKey` and required fields. |
| `QUOTA_EXCEEDED` | Rate limit or credit balance exhausted | Check rate limits. Purchase credits in the UseSense dashboard. |
| `USER_CANCELLED` | Session cancelled by user | Handle gracefully -- show previous screen. |
| `CAPTURE_FAILED` | Frame capture pipeline error | Retry the session. Check camera hardware. |
| `ENCODING_FAILED` | JPEG frame encoding failed | Retry the session. |
| `UPLOAD_FAILED` | Signal upload failed after retries | Check network connectivity. Retry the session. |
| `FACE_NOT_DETECTED` | No face detected in captured frames | Ask user to position face in frame and retry. |
| `LOW_LIGHT` | Lighting conditions too poor | Ask user to move to a brighter area. |
| `TIMEOUT` | Session exceeded configured timeout | Retry with a new session. |
| `SERVER_ERROR` | UseSense API returned a 5xx error | Retry after a short delay. Contact support if persistent. |
| `SERVICE_UNAVAILABLE` | UseSense service is temporarily unavailable | Retry after a short delay. |
| `UNKNOWN_ERROR` | Unexpected error | Retry the session. Contact support with the session ID. |

### Error Handling Example

```swift
UseSenseView(
    session: session,
    onComplete: { result in
        switch result {
        case .success(let decision):
            handleDecision(decision)
        case .failure(let error):
            switch error.code {
            case .cameraPermissionDenied:
                showSettingsAlert(
                    title: "Camera Access Required",
                    message: error.message
                )
            case .networkError, .networkTimeout, .uploadFailed:
                if error.isRetryable {
                    showRetryAlert(message: error.message)
                }
            case .sessionExpired:
                showAlert(
                    title: "Session Expired",
                    message: "Please start a new verification."
                )
            case .unauthorized, .invalidToken:
                showAlert(
                    title: "Authentication Error",
                    message: "Please check your API key configuration."
                )
            case .identityNotFound:
                showAlert(
                    title: "Identity Not Found",
                    message: "The identity ID provided does not exist."
                )
            case .userCancelled:
                // User intentionally cancelled -- no alert needed
                break
            default:
                showAlert(
                    title: "Verification Failed",
                    message: error.message
                )
            }
        }
    },
    onCancel: {
        // User dismissed the UI
    }
)
```

## Permissions

### Required Info.plist Entries

```xml
<key>NSCameraUsageDescription</key>
<string>UseSense needs camera access to verify your identity.</string>

<key>NSMicrophoneUsageDescription</key>
<string>UseSense needs microphone access for voice verification.</string>

<key>NSMotionUsageDescription</key>
<string>UseSense uses motion data to improve verification accuracy.</string>
```

**Notes:**
- `NSCameraUsageDescription` is always required.
- `NSMicrophoneUsageDescription` is only required if `audioEnabled` is set to `.always` or `.riskBased` (default). If you set `audioEnabled: .never`, you can omit it.
- `NSMotionUsageDescription` is optional but recommended. Motion data improves DeepSense channel integrity scoring. The SDK functions without it.

The SDK requests permissions at runtime when the session starts. If you want to control the permission UX (e.g., show a pre-permission screen), request camera permission yourself before calling `createSession()`. If already granted, the SDK will not re-prompt.

## Server-Side Webhook Verification

**This is the most important section for secure integration.**

1. **NEVER** trust the SDK result for access-control decisions. The SDK runs on the user's device and can be tampered with.
2. The definitive verdict arrives via HMAC-SHA256 signed webhook to your backend.
3. Always verify the webhook signature before acting on it.

### Webhook Payload

```json
{
  "event": "session.completed",
  "session_id": "ses_abc123",
  "organization_id": "org_xyz",
  "timestamp": "2026-03-12T10:30:00Z",
  "data": {
    "decision": "approved",
    "channel_trust_score": 95,
    "liveness_score": 92,
    "matchsense_risk_score": 8,
    "presence_confidence": 94,
    "session_type": "enrollment",
    "identity_id": "idn_def456",
    "reasons": [],
    "rule_triggered": null,
    "session_signature": "sig_..."
  }
}
```

### Signature Verification (Node.js / Express)

```javascript
const crypto = require('crypto');

app.post('/webhooks/usesense', (req, res) => {
  const signature = req.headers['x-usesense-signature'];
  const timestamp = req.headers['x-usesense-timestamp'];
  const body = req.rawBody; // raw request body as string

  const expected = crypto
    .createHmac('sha256', process.env.USESENSE_WEBHOOK_SECRET)
    .update(timestamp + '.' + body)
    .digest('hex');

  if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) {
    return res.status(401).send('Invalid signature');
  }

  const event = JSON.parse(body);
  // Act on event.data.decision
  res.status(200).send('OK');
});
```

### Signature Verification (Python / Flask)

```python
import hmac
import hashlib
from flask import Flask, request, abort

app = Flask(__name__)

@app.route('/webhooks/usesense', methods=['POST'])
def usesense_webhook():
    signature = request.headers.get('X-UseSense-Signature')
    timestamp = request.headers.get('X-UseSense-Timestamp')
    body = request.get_data(as_text=True)

    expected = hmac.new(
        key=os.environ['USESENSE_WEBHOOK_SECRET'].encode(),
        msg=f'{timestamp}.{body}'.encode(),
        digestmod=hashlib.sha256
    ).hexdigest()

    if not hmac.compare_digest(signature, expected):
        abort(401)

    event = request.get_json()
    # Act on event['data']['decision']
    return 'OK', 200
```

### Signature Verification (Go)

```go
package main

import (
    "crypto/hmac"
    "crypto/sha256"
    "encoding/hex"
    "io"
    "net/http"
    "os"
)

func webhookHandler(w http.ResponseWriter, r *http.Request) {
    signature := r.Header.Get("X-UseSense-Signature")
    timestamp := r.Header.Get("X-UseSense-Timestamp")

    body, err := io.ReadAll(r.Body)
    if err != nil {
        http.Error(w, "Bad request", http.StatusBadRequest)
        return
    }

    mac := hmac.New(sha256.New, []byte(os.Getenv("USESENSE_WEBHOOK_SECRET")))
    mac.Write([]byte(timestamp + "." + string(body)))
    expected := hex.EncodeToString(mac.Sum(nil))

    if !hmac.Equal([]byte(signature), []byte(expected)) {
        http.Error(w, "Invalid signature", http.StatusUnauthorized)
        return
    }

    // Parse body and act on decision
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("OK"))
}
```

## Sandbox vs Production

- **Sandbox is free and unlimited.** Use it for all development and testing.
- Sandbox and production use **separate API keys**. Generate both in the [UseSense dashboard](https://app.usesense.ai).
- Sandbox keys are prefixed with `sk_` or `dk_`. Production keys are prefixed with `pk_`.
- Sandbox sessions are never billed. Production sessions consume one credit each.
- All features work identically in both environments.
- The environment is **auto-detected** from your API key prefix. You can also set it explicitly via the `environment` parameter in `UseSenseConfig`.
- Sandbox uses a shared face collection, so deduplication scores may be higher than expected during testing. This is normal.

## Troubleshooting

**SDK initialization fails silently**
Check your API key, check network connectivity, and ensure the `UseSense` instance is retained (not deallocated immediately after creation).

**Camera preview is black**
`NSCameraUsageDescription` is missing from `Info.plist`, camera is in use by another app, or the privacy permission was not granted. Check `AVCaptureDevice.authorizationStatus(for: .video)`.

**Session always times out**
Check network connectivity, increase the `captureDurationMs` value in `SDKOptions`, and check if the device is on a restricted network that blocks the UseSense API.

**Deduplication always returns high risk on sandbox**
Sandbox uses a shared face collection across all sandbox integrators. This is expected behavior. Production uses isolated collections per organization.

**Build fails with duplicate symbols**
Check for conflicting pods that bundle the same dependencies. Use `pod deintegrate` and `pod install` to clean up.

**App crashes on launch with "no such module UseSenseSDK"**
Ensure `pod install` completed successfully, open `.xcworkspace` (not `.xcodeproj`), and clean the build folder (`Cmd+Shift+K`).

**Submission to App Store rejected for missing privacy manifest**
Ensure the SDK's `PrivacyInfo.xcprivacy` is included in your build. If using CocoaPods, update to the latest pod version. If using SPM, ensure you're on the latest tag.

## API Reference

Full API documentation is generated via Swift DocC. See the [API Reference](https://docs.usesense.ai/ios/api).

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

Proprietary. See [LICENSE](LICENSE) file.

## Support

- **Documentation**: [https://docs.usesense.ai](https://docs.usesense.ai)
- **Dashboard**: [https://app.usesense.ai](https://app.usesense.ai)
- **Email**: [support@usesense.ai](mailto:support@usesense.ai)
