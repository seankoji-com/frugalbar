import SwiftUI
import QuotaBarCore

/// A window's progress bar: a track, one solid fill, and — only when the
/// vendor published a window length and reset — a single tick where an even
/// pace would be by now.
///
/// The fill is drawn in one state colour (`stateColor(for:)`), the same one
/// the percentage beneath it uses, so a bar and its figure can never disagree.
/// There is no second marker for current usage (the fill's end is that) and no
/// extra over/under-pace segments: they asserted nothing the colour and the
/// tick do not already say, and three colours per bar made the card unreadable.
public struct DualBarProgressView: View {

    let metrics: DualBarMetrics
    /// Draw the window token beside the track. Off in the popover grid, where
    /// the column header names the window and the cell prints the figure.
    let showsLabel: Bool

    /// Track and fill thickness.
    static let barHeight: CGFloat = 6
    /// The pace tick stands slightly proud of the track.
    static let tickHeight: CGFloat = barHeight + 5
    static let tickWidth: CGFloat = 2

    public init(metrics: DualBarMetrics, showsLabel: Bool = true) {
        self.metrics = metrics
        self.showsLabel = showsLabel
    }

    /// nil when the vendor declared this window blocked/critical but reported
    /// no percentage — never coerced to 0 or 1 to give the bar something to
    /// draw against.
    private var consumedPct: Double? {
        metrics.primaryFraction.map { max(0, min(1, $0)) }
    }

    private var hasNoReading: Bool { metrics.primaryFraction == nil }

    /// True exactly in the case the vendor told us "blocked" but gave no
    /// percentage to measure it with. The bar still has to draw *something* —
    /// omitting it reads as "nothing to report" rather than "this window is
    /// blocked" — but it must not fabricate a fraction to do it.
    private var isBlockedWithoutReading: Bool {
        metrics.isBlocked && hasNoReading
    }

    private var labelColor: Color { Self.stateColor(for: metrics) }

    /// The colour that carries a window's state: green at or behind an even
    /// pace, amber when meaningfully ahead of it, red once it is spent or
    /// blocked, neutral with no reading. Shared with the popover grid's
    /// percentage text so a figure and the bar above it never disagree.
    nonisolated static func stateColor(for metrics: DualBarMetrics) -> Color {
        let consumed = metrics.primaryFraction.map { max(0, min(1, $0)) }
        if metrics.isBlocked {
            // The vendor told us this window cannot be used: its own colour
            // when it gave one, otherwise the shared error tone. Whatever the
            // percentage says. A blocked window that reported 40% used must
            // not be drawn green, which is failure rendering as health. This
            // also matches the hatched placeholder's fallback, so a blocked
            // window with no reading never shows a label in one colour beside
            // a bar drawn in another.
            return metrics.blockedColor.flatMap(Color.init(hexString:)) ?? Theme.errorBold
        } else if consumed == nil {
            // No reading and not vendor-flagged blocked: neutral, not a
            // fabricated "healthy" green.
            return Theme.outline
        } else if let consumed, consumed >= 0.999 {
            return Theme.errorBold
        } else if metrics.isMeaningfullyAheadOfPace {
            // The model's "meaningfully ahead" margin, not any difference at
            // all: a window barely open would otherwise be amber at 6% used
            // against 2% elapsed.
            return Color(red: 0.96, green: 0.72, blue: 0.15)
        } else {
            return Theme.healthy
        }
    }

    private var trackColor: Color {
        Color.white.opacity(0.08)
    }

    @ViewBuilder
    private func fill(width w: CGFloat) -> some View {
        if isBlockedWithoutReading {
            RoundedRectangle(cornerRadius: Self.barHeight / 2)
                .fill(labelColor.opacity(0.30))
                .frame(width: w, height: Self.barHeight)
            RoundedRectangle(cornerRadius: Self.barHeight / 2)
                .strokeBorder(labelColor, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: w, height: Self.barHeight)
        } else if let consumed = consumedPct, consumed > 0 {
            // A sliver stays visible at very low values so a small figure
            // reads as "a little used" rather than "not drawn".
            Rectangle()
                .fill(labelColor)
                .frame(width: max(3, consumed * w), height: Self.barHeight)
                .animation(.easeOut(duration: 0.35), value: consumed)
        }
        // No reading and not blocked: the track alone. A fill here would be
        // an invented 0%.
    }

    public var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // Track and fill are clipped together to one capsule, so
                    // only the bar's two true ends round.
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(trackColor)
                            .frame(height: Self.barHeight)
                        fill(width: w)
                    }
                    .frame(width: w, height: Self.barHeight, alignment: .leading)
                    .clipShape(Capsule())

                    // The single marker: where an even pace would be by now.
                    if let pace = metrics.paceMarker {
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: Self.tickWidth, height: Self.tickHeight)
                            .shadow(color: Color.black.opacity(0.6), radius: 1.5)
                            .position(x: min(max(pace * w, 1), w - 1), y: geo.size.height / 2)
                    }
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(height: Self.tickHeight)

            // The window token, in the state colour.
            if showsLabel {
                HStack(spacing: 2) {
                    if WindowGridPresentation.showsBlockedGlyph(for: metrics) {
                        BlockedGlyph(color: labelColor, size: 8)
                    }
                    Text(metrics.label)
                        .font(Theme.Typography.token)
                        .tracking(Theme.Tracking.token)
                        .foregroundStyle(labelColor)
                        .lineLimit(1)
                        // Most window codes are two characters and need no
                        // scaling. Longer ones (REST, GraphQL, PLAN, CYCLE)
                        // are scaled rather than truncated.
                        .minimumScaleFactor(metrics.label.count > 2 ? 0.6 : 1.0)
                }
                .frame(width: Theme.tokenColumnWidth, alignment: .trailing)
            }
        }
        .help(helpText)
        .accessibilityHidden(true)
    }

    /// The fallback detail shown for a window with no percentage. Blocked
    /// windows name the state plainly; a window that is merely unmeasured
    /// (e.g. a real pace target with no usage to compare it against) is not
    /// "blocked" and must not say it is.
    /// `nonisolated`: a pure function of its argument, and `View`'s `body`
    /// requirement can infer main-actor isolation onto every member of a
    /// conforming type under some toolchains — which would make this uncallable
    /// from the synchronous, non-isolated `@Test` functions that exercise it.
    nonisolated static func blockedFallbackDetail(for metrics: DualBarMetrics) -> String {
        if let usedText = metrics.usedText {
            return usedText
        }
        return metrics.isBlocked
            ? "blocked • no reading reported"
            : "no reading reported"
    }

    private var helpText: String { Self.helpText(for: metrics) }

    /// The tooltip. Its pace wording is the colour's own rule: "ahead" only
    /// when the fill is amber, so a green bar is never called overuse.
    nonisolated static func helpText(for metrics: DualBarMetrics) -> String {
        guard let consumed = metrics.primaryFraction.map({ max(0, min(1, $0)) }) else {
            // No percentage with no usedText: say so plainly rather than
            // printing a "0% used" that would misreport an unmeasured window
            // as an empty one — and don't call an unmeasured window "blocked"
            // unless the vendor actually declared it so.
            let detail = blockedFallbackDetail(for: metrics)
            return "\(metrics.label): \(detail)"
        }
        let usedPctInt = Int((consumed * 100).rounded())
        let detail = metrics.usedText ?? "\(usedPctInt)% used"
        guard let paceStatus = paceStatusText(for: metrics) else {
            return "\(metrics.label): \(usedPctInt)% used • \(detail)"
        }
        return "\(metrics.label): \(usedPctInt)% used • \(paceStatus) • \(detail)"
    }

    /// How the window stands against an even pace, or nil when the bar draws
    /// no pace marker (none published, at an end of the track, spent, or
    /// unread) or is blocked: the tooltip describes the tick, never a pace
    /// the bar does not show.
    nonisolated static func paceStatusText(for metrics: DualBarMetrics) -> String? {
        guard !metrics.isBlocked,
              let used = metrics.primaryFraction.map({ max(0, min(1, $0)) }),
              let pace = metrics.paceMarker
        else { return nil }
        let points = Int(((used - pace) * 100).rounded())
        if metrics.isMeaningfullyAheadOfPace { return "\(points)% ahead of an even pace" }
        if used - pace < -DualBarMetrics.aheadOfPaceMargin { return "\(-points)% behind an even pace" }
        return "close to an even pace"
    }
}

extension Color {
    init?(hexString: String) {
        var clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") { clean.removeFirst() }
        guard let hex = UInt32(clean, radix: 16) else { return nil }
        if clean.count == 6 {
            let r = Double((hex >> 16) & 0xFF) / 255.0
            let g = Double((hex >> 8) & 0xFF) / 255.0
            let b = Double(hex & 0xFF) / 255.0
            self.init(red: r, green: g, blue: b)
        } else {
            return nil
        }
    }
}
