import SwiftUI
import UseSenseSDK

@main
struct UseSenseExampleApp: App {
    init() {
        #if DEBUG
        UseSenseDebugBrand.applyFromLaunchArguments()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = CapturePreview.debugScreen {
                UseSenseDebugScreen(name: screen, backdrop: CapturePreview.backdrop)
            } else if CapturePreview.isEnabled {
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

    /// `-USESENSE_SCREEN <name>`: hold one extra-check screen (UseSenseDebugScreen.names),
    /// with `-USESENSE_FAKE_CAMERA <image>` as the camera.
    static var debugScreen: String? {
        UserDefaults.standard.string(forKey: "USESENSE_SCREEN") ?? ProcessInfo.processInfo.environment["USESENSE_SCREEN"]
    }

    static var backdrop: UIImage? {
        (UserDefaults.standard.string(forKey: "USESENSE_FAKE_CAMERA")).flatMap(UIImage.init(contentsOfFile:))
    }

    private static func arg(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key) ?? ProcessInfo.processInfo.environment[key]
    }

    /// A live session made outside the app (`-USESENSE_SESSION_JSON <file>` or
    /// `-USESENSE_SESSION_B64 <base64>`: a POST /v1/sessions response, with `-USESENSE_API_BASE` and
    /// `-USESENSE_ENV`). The app holds no API key: everything after create
    /// authenticates with the session token. Without it, a stand-in session.
    private let session: UseSenseSession = {
        // A file on the simulator, or the response inline as base64 (a device).
        let live = arg("USESENSE_SESSION_JSON").flatMap { FileManager.default.contents(atPath: $0) }
            ?? arg("USESENSE_SESSION_B64").flatMap { Data(base64Encoded: $0) }
        let environment: UseSenseSDK.Environment? = arg("USESENSE_ENV").flatMap(UseSenseSDK.Environment.init(rawValue:))
        let session = UseSenseSession(
            config: UseSenseConfig(apiEndpoint: live != nil ? (arg("USESENSE_API_BASE") ?? UseSenseConfig.defaultEndpoint)
                                                           : "http://127.0.0.1:9/v1",
                                   apiKey: "preview", environment: environment),
            sessionType: .enrollment
        )
        let json = live ?? Data("""
        {"session_id":"sess_preview","session_token":"preview","expires_at":"2099-01-01T00:00:00.000Z",
         "nonce":"preview","policy":{"requires_audio":false,"requires_stepup":false,"challenge_type":"passive"},
         "upload":{"max_frames":30,"target_fps":3,"capture_duration_ms":8000}}
        """.utf8)
        if let response = try? JSONDecoder().decode(CreateSessionResponse.self, from: json) {
            session.injectHostedSessionData(response)
        }
        _ = session.addEventListener { event in
            print("[UseSense e2e] \(event.type.rawValue) \(event.data ?? [:])")
        }
        return session
    }()

    /// Set when the capture hands its result back (an app would close the screen).
    @State private var finished: String?

    var body: some View {
        if let finished {
            VStack(spacing: 12) {
                Text("Run finished").font(.title2.bold())
                Text(finished).font(.body.monospaced()).multilineTextAlignment(.center)
            }
            .padding()
        } else {
            UseSenseView(session: session, onComplete: { result in
                switch result {
                case .success(let d):
                    print("[UseSense e2e] RESULT \(d.sessionId) \(d.decision)")
                    finished = d.decision
                case .failure(let e):
                    print("[UseSense e2e] ERROR \(e.code.rawValue) \(e.details ?? "")")
                    finished = e.code.rawValue
                }
            }, onCancel: { finished = "Cancelled" })
        }
    }
}
#endif
