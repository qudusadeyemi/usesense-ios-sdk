import SwiftUI
import UseSenseSDK

struct AuthenticationView: View {
    let mode: DemoMode
    @State private var identityId = ""
    @State private var remoteSessionId = ""
    @State private var showVerification = false
    @State private var showHostedFlow = false
    @State private var activeSession: UseSenseSession?
    @State private var result: RedactedDecisionObject?
    @State private var hostedResult: String?
    @State private var error: UseSenseError?
    @State private var eventLogger = EventLogger()
    @State private var eventLogSnapshot: [String] = []

    @AppStorage("apiKey") private var apiKey = ""

    var body: some View {
        VStack(spacing: 20) {
            Form {
                Section("Authentication Details") {
                    TextField("Identity ID", text: $identityId)
                        .autocapitalization(.none)
                    TextField("Remote Session ID (for hosted flow)", text: $remoteSessionId)
                        .autocapitalization(.none)
                }

                Section {
                    Button(action: { startAuthentication() }) {
                        Label("Start Authentication", systemImage: "person.badge.shield.checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled((mode == .live && apiKey.isEmpty) || (identityId.isEmpty && remoteSessionId.isEmpty))
                }

                if let result = result {
                    Section("Result") {
                        LabeledContent("Decision", value: result.decision)
                        LabeledContent("Session ID", value: result.sessionId)
                        if let identityId = result.identityId {
                            LabeledContent("Identity ID", value: identityId)
                        }
                    }
                }

                if let hostedResult = hostedResult {
                    Section("Hosted Flow Result") {
                        LabeledContent("Decision", value: hostedResult)
                    }
                }

                if let error = error {
                    Section("Error") {
                        Text(error.message)
                            .foregroundColor(.red)
                        Text("Code: \(error.code.rawValue)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !eventLogSnapshot.isEmpty {
                    Section("Event Log") {
                        ForEach(Array(eventLogSnapshot.enumerated()), id: \.offset) { _, event in
                            Text(event)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }
        }
        .navigationTitle("Authentication")
        .fullScreenCover(isPresented: $showVerification) {
            if mode == .live, let session = activeSession {
                UseSenseView(
                    session: session,
                    onComplete: { completionResult in
                        eventLogSnapshot = eventLogger.events
                        showVerification = false
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
                        eventLogSnapshot = eventLogger.events
                        showVerification = false
                        activeSession = nil
                    }
                )
            } else {
                mockResultView
            }
        }
        .fullScreenCover(isPresented: $showHostedFlow) {
            HostedVerificationWrapper(
                remoteSessionId: remoteSessionId,
                apiKey: apiKey,
                onResult: { decision in
                    hostedResult = decision
                    error = nil
                    showHostedFlow = false
                },
                onError: { err in
                    error = err
                    hostedResult = nil
                    showHostedFlow = false
                }
            )
        }
    }

    private func startAuthentication() {
        if mode == .live {
            // If a remote session ID is provided, use the hosted flow
            if !remoteSessionId.isEmpty {
                showHostedFlow = true
                return
            }

            // Otherwise use the direct SDK flow
            let config = UseSenseConfig(apiKey: apiKey)
            let sdk = UseSense(config: config)
            let session = sdk.createSession(
                type: .authentication,
                identityId: identityId
            )

            let logger = eventLogger
            let _ = session.addEventListener { event in
                logger.append("[\(event.type.rawValue)] \(event.data?.description ?? "")")
            }

            activeSession = session
        }
        showVerification = true
    }

    private var mockResultView: some View {
        VStack {
            Text("Mock Authentication")
                .font(.title)
                .padding()

            Button("Simulate Success") {
                result = RedactedDecisionObject(
                    sessionId: "mock_\(UUID().uuidString.prefix(8))",
                    sessionType: "authentication",
                    identityId: identityId,
                    decision: "APPROVE",
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )
                error = nil
                showVerification = false
            }
            .buttonStyle(.borderedProminent)
            .padding()

            Button("Simulate Rejection") {
                result = RedactedDecisionObject(
                    sessionId: "mock_\(UUID().uuidString.prefix(8))",
                    sessionType: "authentication",
                    identityId: identityId,
                    decision: "REJECT",
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )
                error = nil
                showVerification = false
            }
            .buttonStyle(.bordered)
            .padding()

            Button("Simulate Manual Review") {
                result = RedactedDecisionObject(
                    sessionId: "mock_\(UUID().uuidString.prefix(8))",
                    sessionType: "authentication",
                    identityId: identityId,
                    decision: "MANUAL_REVIEW",
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )
                error = nil
                showVerification = false
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .padding()

            Button("Cancel") {
                showVerification = false
            }
            .foregroundColor(.secondary)
        }
    }
}

/// SwiftUI wrapper for HostedVerificationViewController
struct HostedVerificationWrapper: UIViewControllerRepresentable {
    let remoteSessionId: String
    let apiKey: String
    let onResult: (String) -> Void
    let onError: (UseSenseError) -> Void

    func makeUIViewController(context: Context) -> HostedVerificationViewController {
        let config = UseSenseConfig(apiKey: apiKey)
        return HostedVerificationViewController(
            remoteSessionId: remoteSessionId,
            config: config,
            onComplete: { result in
                switch result {
                case .success(let decision):
                    onResult(decision)
                case .failure(let error):
                    onError(error)
                }
            }
        )
    }

    func updateUIViewController(_ uiViewController: HostedVerificationViewController, context: Context) {}
}
