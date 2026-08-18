import SwiftUI
import QuotaBarCore

/// Per-provider status glyph.
///
/// Shape carries the meaning as well as colour. Colour alone fails WCAG 1.4.1
/// and is unreadable for the ~8% of men with colour vision deficiency — for a
/// product whose entire value is "glance and know", that is the core use case,
/// not an edge case.
struct StatusIndicatorDot: View {

    let status: ProviderStatus

    private var symbol: String {
        if status.confidence == .unavailable { return "minus.circle" }
        switch status.urgency {
        case .none:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        if status.confidence == .unavailable { return .secondary }
        switch status.urgency {
        case .none:     return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.caption2)
            .fontWeight(.semibold)
            .imageScale(.small)
            .foregroundStyle(tint)
            .frame(width: 12)
            .accessibilityHidden(true)   // the row supplies the spoken label
    }
}
