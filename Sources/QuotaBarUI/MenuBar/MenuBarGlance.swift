import AppKit
import QuotaBarCore

/// The menu-bar title for the glance design: the top Use-now pick.
///
/// Its colour describes the pick, not global pressure: normal for a
/// qualifying pick, amber for a best-available one, red only when no pool is
/// usable (the owner's decision-6 option, 23 Nov 2026). Each tone also has a
/// non-colour channel: the pick's own logo, a half-gauge glyph for a weak
/// pick, `nosign` when nothing is usable, a question mark when nothing could
/// be confirmed.
public enum MenuBarGlance {

    public struct Presentation: Equatable {
        /// Draw this vendor's logo when set; otherwise `symbolName`.
        public let vendor: VendorIdentifier?
        public let symbolName: String?
        public let text: String
        public let tone: GlancePresentation.MenuTone
        public let accessibilityLabel: String
    }

    public static func presentation(snapshots: [QuotaSnapshot], now: Date) -> Presentation {
        let title = GlancePresentation(snapshots: snapshots, now: now).menuTitle
        let symbol: String? = switch title.tone {
        case .normal: title.vendor == nil ? "gauge.with.dots.needle.67percent" : nil
        case .caveat: title.vendor == nil ? "gauge.with.dots.needle.33percent" : nil
        case .critical: "nosign"
        case .unknown: "questionmark.circle"
        }
        let text = title.tone == .caveat ? "◐ " + title.text : title.text
        return Presentation(vendor: title.vendor, symbolName: symbol, text: text, tone: title.tone,
                            accessibilityLabel: "FrugalBar. " + title.spoken)
    }

    public static func color(for tone: GlancePresentation.MenuTone) -> NSColor {
        switch tone {
        case .normal: .labelColor
        case .caveat: NSColor(red: 0xff / 255.0, green: 0xb8 / 255.0, blue: 0x74 / 255.0, alpha: 1) // Theme.tertiary
        case .critical: NSColor(red: 0xe5 / 255.0, green: 0x3d / 255.0, blue: 0x3d / 255.0, alpha: 1) // Theme.errorBold
        case .unknown: .secondaryLabelColor
        }
    }
}
