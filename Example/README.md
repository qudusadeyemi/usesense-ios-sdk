# UseSense iOS Example App

Demonstrates SDK initialization, enrollment, authentication, event listening, and error handling.

## Setup

1. Clone this repository
2. `cd Example/`
3. `pod install`
4. Open `UseSenseExample.xcworkspace` in Xcode
5. Replace the API key placeholder in the app with your sandbox API key from [https://app.usesense.ai](https://app.usesense.ai)
6. Build and run on a physical device (camera required)

## What This Demonstrates

- SDK initialization with sandbox configuration
- Enrollment session (first-time face registration)
- Authentication session (returning user verification)
- Real-time event streaming during sessions
- Error handling for all SDK error codes
- Result interpretation with decision display
