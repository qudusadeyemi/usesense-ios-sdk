# UseSense iOS Example App

Demonstrates SDK initialization, enrollment, authentication, event listening, and error handling.

## Setup

1. Clone this repository
2. `cd Example/`
3. `pod install`
4. **Configure code signing.** Create `Example/Signing.local.xcconfig` with
   your Apple Developer Team ID:

   ```
   DEVELOPMENT_TEAM = YOURTEAMID
   ```

   Find your team ID in Xcode → Settings → Accounts → select your Apple ID →
   "Team ID" column on the right. It's a 10-character alphanumeric string
   like `ABCDE12345`. The path `Example/Signing.local.xcconfig` is
   gitignored so your team ID never gets committed. This file is
   `#include?`-ed by the committed `Signing.debug.xcconfig` /
   `Signing.release.xcconfig` files, which themselves are the target's
   base build configuration and flow the generated CocoaPods settings
   through to the Example target.
5. Open `UseSenseExample.xcworkspace` in Xcode (**not** `.xcodeproj` —
   CocoaPods requires the workspace so Xcode can see the Pods target
   graph alongside the Example target)
6. Replace the API key placeholder in the app with your sandbox API key from [https://app.usesense.ai](https://app.usesense.ai)
7. Build and run on a physical device (camera required)

## What This Demonstrates

- SDK initialization with sandbox configuration
- Enrollment session (first-time face registration)
- Authentication session (returning user verification)
- Real-time event streaming during sessions
- Error handling for all SDK error codes
- Result interpretation with decision display
