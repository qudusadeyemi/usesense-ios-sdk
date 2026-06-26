#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI

// MARK: - USQualityPill
//
// Compact capture-quality cue (e.g. "Move closer", "Hold still", "Good lighting")
// shown over the camera. Severity drives the colour, matching the hosted quality
// banner thresholds.

public struct USQualityPill: View {
    public enum Severity { case good, adjust, critical }

    private let text: String
    private let severity: Severity

    public init(_ text: String, severity: Severity = .adjust) {
        self.text = text
        self.severity = severity
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
            Text(text).font(.usBody(13, .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(tint))
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
    }

    private var tint: Color {
        switch severity {
        case .good:     return USColors.success
        case .adjust:   return USColors.liveSense
        case .critical: return USColors.destructive
        }
    }
    private var icon: String {
        switch severity {
        case .good:     return "checkmark.circle.fill"
        case .adjust:   return "viewfinder"
        case .critical: return "exclamationmark.circle.fill"
        }
    }
}
#endif
