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
        if status.confidence == .unavailable { return Theme.outline }
        switch status.urgency {
        case .none:     return Theme.secondary
        case .warning:  return Theme.tertiary
        case .critical: return Theme.error
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 14)
            .accessibilityHidden(true)   // the row supplies the spoken label
    }
}

