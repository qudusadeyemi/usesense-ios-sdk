import SwiftUI
import UseSenseSDK

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
            .navigationTitle("UseSense Example")
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
