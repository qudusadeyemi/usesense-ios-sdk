import SwiftUI
import UseSenseSDK

struct EventLogView: View {
    let events: [EventEntry]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        List(events) { entry in
            HStack(alignment: .top, spacing: 10) {
                eventIcon(entry.type)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.type.rawValue)
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.medium)

                    if let data = entry.data, !data.isEmpty {
                        Text(data.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Event Log")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func eventIcon(_ type: UseSenseEventType) -> some View {
        switch type {
        case .sessionCreated:
            Image(systemName: "plus.circle.fill").foregroundColor(.blue)
        case .permissionsRequested:
            Image(systemName: "lock.circle.fill").foregroundColor(.yellow)
        case .permissionsGranted:
            Image(systemName: "lock.open.fill").foregroundColor(.green)
        case .permissionsDenied:
            Image(systemName: "lock.slash.fill").foregroundColor(.red)
        case .captureStarted:
            Image(systemName: "camera.fill").foregroundColor(.blue)
        case .frameCaptured:
            Image(systemName: "photo.fill").foregroundColor(.gray)
        case .captureCompleted:
            Image(systemName: "camera.badge.ellipsis").foregroundColor(.blue)
        case .audioRecordStarted:
            Image(systemName: "mic.fill").foregroundColor(.purple)
        case .audioRecordCompleted:
            Image(systemName: "mic.badge.xmark").foregroundColor(.purple)
        case .challengeStarted:
            Image(systemName: "gamecontroller.fill").foregroundColor(.orange)
        case .challengeCompleted:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .uploadStarted:
            Image(systemName: "arrow.up.circle.fill").foregroundColor(.blue)
        case .uploadProgress:
            Image(systemName: "arrow.up.circle").foregroundColor(.blue)
        case .uploadCompleted:
            Image(systemName: "arrow.up.circle.fill").foregroundColor(.green)
        case .completeStarted:
            Image(systemName: "gearshape.fill").foregroundColor(.gray)
        case .decisionReceived:
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
        case .imageQualityCheck:
            Image(systemName: "sparkles").foregroundColor(.yellow)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
        @unknown default:
            Image(systemName: "questionmark.circle").foregroundColor(.gray)
        }
    }
}
