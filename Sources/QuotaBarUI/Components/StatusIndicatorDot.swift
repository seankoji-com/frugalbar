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
    /// Side length of the avatar this dot overlays. The glyph and frame are
    /// derived from it so the mark always fits inside the avatar's corner
    /// rather than hanging off it at the smallest used size (30pt).
    var size: CGFloat = 14

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

    /// Whether the avatar should draw a status badge at all.
    ///
    /// The badge exists to flag *something wrong* — quota pressure or an
    /// unreadable provider. A healthy avatar is already identified by its logo
    /// and a redundant checkmark over it is noise (issue #39 / I17). Only
    /// non-healthy states show a mark; the glyphs (`symbol(for:)`) still carry
    /// shape meaning for exactly the states that do appear.
    nonisolated static func shouldShowIndicator(for status: ProviderStatus) -> Bool {
        switch (status.confidence, status.urgency) {
        case (.unavailable, _):      return true
        case (_, .warning):          return true
        case (_, .critical):         return true
        default:                     return false
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
        // Proportional to the avatar, not fixed 14pt/11pt, so the mark stays
        // inside the corner of even the smallest avatar (30pt). The frame is
        // ~0.42 of the avatar side and the glyph ~72% of that (~size*0.30).
        let frame = size * 0.42
        Image(systemName: Self.symbol(for: status))
            .font(.system(size: frame * 0.72, weight: .semibold))
            .foregroundStyle(Self.tint(for: status))
            .frame(width: frame, height: frame)
            .accessibilityHidden(true)   // the row supplies the spoken label
    }
}

