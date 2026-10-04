import SwiftUI

/// The non-colour channel for a window the vendor has blocked but still
/// reports a percentage for (OpenCode Go does).
///
/// Such a window wears the vendor's blocked colour, a pink that sits close to
/// the amber of "ahead of pace", so colour alone cannot tell them apart
/// (WCAG 1.4.1). A blocked window with no percentage already says "Blocked"
/// in words and draws a dashed placeholder, so it needs no glyph.
///
/// Hidden from VoiceOver: the spoken label says "blocked" itself.
struct BlockedGlyph: View {

    /// The same SF Symbol shape wherever a blocked figure is drawn, and a
    /// shape no urgency glyph uses (check, exclamation circle, octagon).
    nonisolated static let symbolName = "nosign"

    let color: Color
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: Self.symbolName)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}
