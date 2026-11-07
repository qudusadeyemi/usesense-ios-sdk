import SwiftUI
import UseSenseSDK

@main
struct UseSenseExampleApp: App {
    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(simulator)
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

#if targetEnvironment(simulator)
/// Simulator-only capture preview for design work: launch with
/// `USESENSE_SIM_CAMERA=<portrait photo path>` and `USESENSE_CAPTURE_PREVIEW=1`.
/// It opens the real capture screen on a stand-in session (no API key, no
/// network), fed by the photo. The upload at the end fails, as expected.
struct CapturePreview: View {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["USESENSE_CAPTURE_PREVIEW"] == "1" }

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
