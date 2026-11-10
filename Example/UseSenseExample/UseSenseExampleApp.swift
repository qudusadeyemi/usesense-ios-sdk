import SwiftUI
import UseSenseSDK

@main
struct UseSenseExampleApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if CapturePreview.isEnabled {
                CapturePreview()
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}

#if DEBUG
/// Debug-only capture preview for design work and the capture test kit:
/// launch with `-USESENSE_CAPTURE_PREVIEW 1 -USESENSE_FAKE_CAMERA <video or
/// photo>` (plus optional `-FREEZE_AT 4.0 -FORCE_STATE scan -FORCE_PROGRESS 0.5`).
/// It opens the real capture screen on a stand-in session (no API key, no
/// network), fed by the file. An upload at the end fails, as expected.
struct CapturePreview: View {
    static var isEnabled: Bool {
        UserDefaults.standard.string(forKey: "USESENSE_CAPTURE_PREVIEW") == "1"
            || ProcessInfo.processInfo.environment["USESENSE_CAPTURE_PREVIEW"] == "1"
    }

    private let session: UseSenseSession = {
        let session = UseSenseSession(
            config: UseSenseConfig(apiEndpoint: "http://127.0.0.1:9/v1", apiKey: "preview"),
            sessionType: .enrollment
        )
        let json = """
        {"session_id":"sess_preview","session_token":"preview","expires_at":"2099-01-01T00:00:00.000Z",
         "nonce":"preview","policy":{"requires_audio":false,"requires_stepup":false,"challenge_type":"passive"},
         "upload":{"max_frames":30,"target_fps":3,"capture_duration_ms":8000}}
        """
        if let response = try? JSONDecoder().decode(CreateSessionResponse.self, from: Data(json.utf8)) {
            session.injectHostedSessionData(response)
        }
        return session
    }()

    var body: some View {
        UseSenseView(session: session, onComplete: { _ in })
    }
}
#endif
