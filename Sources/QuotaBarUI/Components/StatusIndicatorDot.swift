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

    // `nonisolated`: pure functions of their arguments, but `View`'s `body`
    // requirement is main-actor-isolated and the compiler can infer that
    // isolation onto every member of a conforming type unless told
    // otherwise. That inference is toolchain-sensitive — it did not fire
    // locally, but did under CI's Xcode/Swift version — and would make these
    // uncallable from the synchronous, non-isolated `@Test` functions that
    // exercise them directly.
    nonisolated static func symbol(for status: ProviderStatus) -> String {
        if status.confidence == .unavailable { return "minus.circle" }
        switch status.urgency {
        case .none:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    nonisolated static func tint(for status: ProviderStatus) -> Color {
        if status.confidence == .unavailable { return Theme.outline }
        switch status.urgency {
        case .none:     return Theme.secondary
        case .warning:  return Theme.tertiary
        case .critical: return Theme.error
        }
    }

    var body: some View {
        Image(systemName: Self.symbol(for: status))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Self.tint(for: status))
            .frame(width: 14)
            .accessibilityHidden(true)   // the row supplies the spoken label
    }
}

