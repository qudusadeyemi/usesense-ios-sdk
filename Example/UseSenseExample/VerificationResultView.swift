import SwiftUI
import UseSenseSDK

struct VerificationResultView: View {
    let result: RedactedDecisionObject

    var body: some View {
        List {
            Section {
                decisionBadge
            }

            Section("Session Details") {
                row("Session ID", value: result.sessionId)
                if let sessionType = result.sessionType {
                    row("Session Type", value: sessionType)
                }
                if let identityId = result.identityId {
                    row("Identity ID", value: identityId)
                }
                row("Timestamp", value: result.timestamp)
            }

            Section {
                Text("Pillar scores (DeepSense, LiveSense, MatchSense) are delivered to your backend via webhook for security. The SDK result is for UI feedback only.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Note")
            }
        }
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var decisionBadge: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                icon
                    .font(.system(size: 48))
                Text(result.decision)
                    .font(.headline)
                    .foregroundColor(decisionColor)
            }
            .padding(.vertical, 12)
            Spacer()
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch result.decision {
        case Decision.approve.rawValue:
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
        case Decision.reject.rawValue:
            Image(systemName: "xmark.seal.fill")
                .foregroundColor(.red)
        default:
            Image(systemName: "clock.badge.questionmark")
                .foregroundColor(.orange)
        }
    }

    private var decisionColor: Color {
        switch result.decision {
        case Decision.approve.rawValue: return .green
        case Decision.reject.rawValue: return .red
        default: return .orange
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}
