import SwiftUI
import UIKit
import UseSenseSDK

// Public API base for creating flow runs and for the SDK Flow runner. Sandbox
// vs production is selected by the API key plus the x-environment header.
private let kApiBase = "https://api.usesense.ai"

/// Wrapper that lets us drive .fullScreenCover(item:) with a UseSenseSession.
/// Two separate @State vars (activeSession + showVerification) had a
/// coordination bug where SwiftUI would evaluate the cover's content closure
/// with activeSession still nil because the state changes were visible to the
/// closure in a non-atomic order. .fullScreenCover(item:) binds presentation
/// and payload to a single optional, eliminating that split state.
struct SessionWrapper: Identifiable {
    let id = UUID()
    let session: UseSenseSession
}

struct ContentView: View {
    // TODO: Replace with your sandbox API key from https://watchtower.usesense.ai
    @AppStorage("apiKey") private var apiKey = ""
    @State private var identityId = ""
    @State private var useProduction = false
    @State private var activeSession: SessionWrapper?
    @State private var sessionType: SessionType = .enrollment
    @State private var result: RedactedDecisionObject?
    @State private var error: UseSenseError?
    @State private var events: [EventEntry] = []
    @State private var flowId = ""
    @State private var flowMessage: String?
    @State private var isRunningFlow = false

    private var useSense: UseSense {
        // Force the environment from the toggle instead of relying on
        // Environment.detect(from:), which defaults to .production for any
        // key that does not literally start with `sk_sandbox_` / `sk_prod_`.
        // Real-world keys (e.g. `sk_76p1...`) do not carry that marker, so
        // auto-detection silently routes sandbox keys to the production
        // account and fails with 402 insufficient_credits.
        let config = UseSenseConfig(
            apiKey: apiKey,
            environment: useProduction ? .production : .sandbox
        )
        return UseSense(config: config)
    }

    var body: some View {
        NavigationView {
            Form {
                configSection
                actionSection
                flowSection
                if let result = result {
                    NavigationLink {
                        VerificationResultView(result: result)
                    } label: {
                        resultSummary(result)
                    }
                }
                if let error = error {
                    errorSection(error)
                }
                if !events.isEmpty {
                    NavigationLink {
                        EventLogView(events: events)
                    } label: {
                        Label("Event Log (\(events.count))", systemImage: "list.bullet.rectangle")
                    }
                }
            }
            .navigationTitle("Sense Example")
            .fullScreenCover(item: $activeSession) { wrapper in
                UseSenseView(
                    session: wrapper.session,
                    onComplete: { completionResult in
                        activeSession = nil
                        switch completionResult {
                        case .success(let decision):
                            result = decision
                            error = nil
                        case .failure(let err):
                            error = err
                            result = nil
                        }
                    },
                    onCancel: {
                        activeSession = nil
                    }
                )
            }
        }
    }

    // MARK: - Sections

    private var configSection: some View {
        Section {
            SecureField("API Key", text: $apiKey)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Toggle("Production", isOn: $useProduction)
            if apiKey.isEmpty {
                Label(
                    "Enter your API key from watchtower.usesense.ai",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundColor(.orange)
            }
        } header: {
            Text("Configuration")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                startSession(type: .enrollment)
            } label: {
                Label("Enroll", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(apiKey.isEmpty)

            TextField("Identity ID (for authentication)", text: $identityId)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            Button {
                startSession(type: .authentication)
            } label: {
                Label("Authenticate", systemImage: "person.badge.shield.checkmark")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(apiKey.isEmpty || identityId.isEmpty)
        } header: {
            Text("Verification")
        }
    }

    private var flowSection: some View {
        Section {
            TextField("Flow ID (flw_...)", text: $flowId)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button {
                startFlow()
            } label: {
                Label("Run a Flow", systemImage: "arrow.triangle.branch")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(apiKey.isEmpty || flowId.isEmpty || isRunningFlow)
            if let flowMessage = flowMessage {
                Text(flowMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Flows")
        } footer: {
            Text("The example creates the run with your API key, then launches the Flow runner. In production your backend creates the run and ships flowRunId + sdkToken to the app.")
        }
    }

    private func resultSummary(_ decision: RedactedDecisionObject) -> some View {
        HStack {
            decisionIcon(decision.decision)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last Result")
                    .font(.subheadline)
                Text(decision.decision)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func errorSection(_ error: UseSenseError) -> some View {
        Section("Error") {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.message)
                        .font(.subheadline)
                    Text(error.code.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Actions

    private func startSession(type: SessionType) {
        events = []
        result = nil
        error = nil
        sessionType = type

        let sdk = useSense
        let session: UseSenseSession

        if type == .authentication {
            session = sdk.createSession(
                type: .authentication,
                identityId: identityId
            )
        } else {
            session = sdk.createSession(type: .enrollment)
        }

        let _ = sdk.onEvent { event in
            let entry = EventEntry(
                timestamp: event.timestamp,
                type: event.type,
                data: event.data
            )
            DispatchQueue.main.async {
                events.append(entry)
            }
        }

        activeSession = SessionWrapper(session: session)
    }

    // Run a Flow. Flows are token-based and do NOT use UseSense init: the host
    // backend creates the run and returns flowRunId + sdkToken. The example does
    // that inline with the API key so a developer can test a flow end to end,
    // then hands the minted credentials to the Flow runner.
    private func startFlow() {
        result = nil
        error = nil
        flowMessage = nil
        isRunningFlow = true

        guard let url = URL(string: "\(kApiBase)/v1/flow-runs") else {
            flowMessage = "Invalid API base URL."
            isRunningFlow = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(useProduction ? "production" : "sandbox", forHTTPHeaderField: "x-environment")
        let payload: [String: Any] = [
            "flowId": flowId,
            "subject": ["externalRef": "ios-demo-user"],
            "mint_sdk_token": true,
            "sdk_version": "ios-demo",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, err in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                if let err = err {
                    flowMessage = "Could not create flow run: \(err.localizedDescription)"
                    isRunningFlow = false
                    return
                }
                guard (200..<300).contains(status),
                      let json = json,
                      let flowRun = json["flowRun"] as? [String: Any],
                      let runId = flowRun["id"] as? String,
                      let sdkToken = json["sdkToken"] as? String else {
                    flowMessage = (json?["message"] as? String) ?? "Could not create flow run (HTTP \(status))."
                    isRunningFlow = false
                    return
                }
                launchFlow(flowRunId: runId, sdkToken: sdkToken)
            }
        }.resume()
    }

    private func launchFlow(flowRunId: String, sdkToken: String) {
        guard let apiBaseURL = URL(string: kApiBase),
              let presenter = Self.topViewController() else {
            flowMessage = "No view controller available to present the flow."
            isRunningFlow = false
            return
        }
        UseSenseFlows.run(
            flowRunId: flowRunId,
            sdkToken: sdkToken,
            apiBaseURL: apiBaseURL,
            from: presenter
        ) { runResult in
            DispatchQueue.main.async {
                isRunningFlow = false
                switch runResult {
                case .success(let r):
                    let outcome = r.outcome.map { " — \($0.rawValue)" } ?? ""
                    flowMessage = "Flow \(r.state.rawValue)\(outcome)"
                case .failure(let e):
                    flowMessage = e.code == .cancelled
                        ? "Flow cancelled."
                        : "Flow failed: \(e.code.rawValue) - \(e.message)"
                }
            }
        }
    }

    // Walk to the top-most presented view controller to present the (UIKit)
    // Flow runner from a SwiftUI app.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let keyWindow = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - Helpers

    @ViewBuilder
    private func decisionIcon(_ decision: String) -> some View {
        switch decision {
        case Decision.approve.rawValue:
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.title2)
        case Decision.reject.rawValue:
            Image(systemName: "xmark.seal.fill")
                .foregroundColor(.red)
                .font(.title2)
        default:
            Image(systemName: "clock.badge.questionmark")
                .foregroundColor(.orange)
                .font(.title2)
        }
    }
}

struct EventEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: UseSenseEventType
    let data: [String: String]?
}
