import SwiftUI
import UseSenseSDK

/// Holds event log entries in a reference type so that updates don't trigger
/// parent-view re-renders that would recreate the UseSenseView/session.
final class EventLogger: ObservableObject {
    @Published var events: [String] = []
}

struct EnrollmentView: View {
    let mode: DemoMode
    @State private var externalUserId = ""
    @State private var showVerification = false
    @State private var result: RedactedDecisionObject?
    @State private var error: UseSenseError?
    @StateObject private var eventLogger = EventLogger()

    @AppStorage("apiKey") private var apiKey = ""

    var body: some View {
        VStack(spacing: 20) {
            Form {
                Section("Enrollment Details") {
                    TextField("External User ID (optional)", text: $externalUserId)
                        .autocapitalization(.none)
                }

                Section {
                    Button(action: { showVerification = true }) {
                        Label("Start Enrollment", systemImage: "person.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(mode == .live && apiKey.isEmpty)
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

                if let error = error {
                    Section("Error") {
                        Text(error.message)
                            .foregroundColor(.red)
                        Text("Code: \(error.code.rawValue)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if !eventLogger.events.isEmpty {
                    Section("Event Log") {
                        ForEach(Array(eventLogger.events.enumerated()), id: \.offset) { _, event in
                            Text(event)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }
        }
        .navigationTitle("Enrollment")
        .fullScreenCover(isPresented: $showVerification) {
            if mode == .live {
                makeLiveVerificationView()
            } else {
                mockResultView
            }
        }
    }

    private func makeLiveVerificationView() -> some View {
        let config = UseSenseConfig(apiKey: apiKey)
        let sdk = UseSense(config: config)
        let session = sdk.createSession(
            type: .enrollment,
            externalUserId: externalUserId.isEmpty ? nil : externalUserId
        )

        let logger = eventLogger
        let _ = session.addEventListener { event in
            DispatchQueue.main.async {
                logger.events.append("[\(event.type.rawValue)] \(event.data?.description ?? "")")
            }
        }

        return UseSenseView(
            session: session,
            onComplete: { completionResult in
                showVerification = false
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
                showVerification = false
            }
        )
    }

    private var mockResultView: some View {
        VStack {
            Text("Mock Enrollment")
                .font(.title)
                .padding()

            Button("Simulate Success") {
                result = RedactedDecisionObject(
                    sessionId: "mock_\(UUID().uuidString.prefix(8))",
                    sessionType: "enrollment",
                    identityId: "id_mock_\(UUID().uuidString.prefix(8))",
                    decision: "APPROVE",
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )
                error = nil
                showVerification = false
            }
            .buttonStyle(.borderedProminent)
            .padding()

            Button("Simulate Failure") {
                result = RedactedDecisionObject(
                    sessionId: "mock_\(UUID().uuidString.prefix(8))",
                    sessionType: "enrollment",
                    identityId: nil,
                    decision: "REJECT",
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )
                error = nil
                showVerification = false
            }
            .buttonStyle(.bordered)
            .padding()

            Button("Cancel") {
                showVerification = false
            }
            .foregroundColor(.secondary)
        }
    }
}
