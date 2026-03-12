import SwiftUI
import UseSenseSDK

/// Holds event log entries in a plain reference type.
/// NOT an ObservableObject — appending events must not trigger parent-view
/// re-renders that would re-evaluate the fullScreenCover content closure.
final class EventLogger {
    private(set) var events: [String] = []

    func append(_ entry: String) {
        events.append(entry)
    }
}

struct EnrollmentView: View {
    let mode: DemoMode
    @State private var externalUserId = ""
    @State private var enrollmentId = ""
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
                Section("Enrollment Details") {
                    TextField("External User ID (optional)", text: $externalUserId)
                        .autocapitalization(.none)
                    TextField("Enrollment ID (for hosted flow)", text: $enrollmentId)
                        .autocapitalization(.none)
                }

                Section {
                    Button(action: { startEnrollment() }) {
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
        .navigationTitle("Enrollment")
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
            HostedEnrollmentWrapper(
                enrollmentId: enrollmentId,
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

    private func startEnrollment() {
        if mode == .live {
            // If an enrollment ID is provided, use the hosted flow
            if !enrollmentId.isEmpty {
                showHostedFlow = true
                return
            }

            // Otherwise use the direct SDK flow
            let config = UseSenseConfig(apiKey: apiKey)
            let sdk = UseSense(config: config)
            let session = sdk.createSession(
                type: .enrollment,
                externalUserId: externalUserId.isEmpty ? nil : externalUserId
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

/// SwiftUI wrapper for HostedEnrollmentViewController
struct HostedEnrollmentWrapper: UIViewControllerRepresentable {
    let enrollmentId: String
    let apiKey: String
    let onResult: (String) -> Void
    let onError: (UseSenseError) -> Void

    func makeUIViewController(context: Context) -> HostedEnrollmentViewController {
        let config = UseSenseConfig(apiKey: apiKey)
        return HostedEnrollmentViewController(
            enrollmentId: enrollmentId,
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

    func updateUIViewController(_ uiViewController: HostedEnrollmentViewController, context: Context) {}
}
