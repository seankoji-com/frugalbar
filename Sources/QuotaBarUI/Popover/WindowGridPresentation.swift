import Foundation
import QuotaBarCore

/// The popover's three window columns, in reading order: five-hour, weekly,
/// monthly.
///
/// A row puts each of its bars in the column its window token names, so the
/// same window lines up down the whole card instead of every vendor stacking
/// its own bars in its own order. Columns are keyed on the token rather than
/// on `windowLength`: the token is what each provider deliberately chose to
/// call the window, and a length can be missing or ambiguous.
public enum WindowColumn: Int, CaseIterable, Sendable, Identifiable {
    case fiveHour, weekly, monthly

    public var id: Int { rawValue }

    /// The token drawn in the column header, matching the providers' labels.
    public var label: String {
        switch self {
        case .fiveHour: "5H"
        case .weekly:   "WK"
        case .monthly:  "MO"
        }
    }

    /// Spoken form for the row's accessibility label.
    public var spokenName: String {
        switch self {
        case .fiveHour: "5-hour"
        case .weekly:   "weekly"
        case .monthly:  "monthly"
        }
    }

    /// The column a provider's window token belongs in, or nil for a pool
    /// that is not a window (Kiro's bonus "BN" and overage "OV" credits,
    /// Grok's on-demand "OD" budget, DevPass key spend "SP", a daily "1D"
    /// window, an elapsed-time "CYCLE", GitHub's "REST"/"GraphQL").
    public static func column(forLabel label: String) -> WindowColumn? {
        allCases.first { $0.label == label.uppercased() }
    }
}

/// One provider row laid out on the window grid.
public struct WindowGridPresentation: Equatable, Sendable {

    /// The bar in each column. A column the vendor does not publish is
    /// simply absent — drawn empty, never as 0%.
    public let bars: [WindowColumn: DualBarMetrics]
    /// Bars that belong to no column, drawn on their own lines under the
    /// row with their own tokens, in the order the provider gave them.
    public let extras: [DualBarMetrics]
    /// The instant every reset time in this presentation is measured from, so
    /// the compact text a cell draws and the words VoiceOver speaks cannot
    /// land on different sides of a rounding boundary (59m30s is "1h" to one
    /// and "59 minutes" to the other if each reads its own clock).
    public let now: Date
    private let vendorId: VendorIdentifier

    public init(snapshot: QuotaSnapshot, now: Date = Date()) {
        self.now = now
        self.vendorId = snapshot.vendorId
        var bars: [WindowColumn: DualBarMetrics] = [:]
        var extras: [DualBarMetrics] = []
        for bar in snapshot.displayBars {
            if let column = WindowColumn.column(forLabel: bar.label), bars[column] == nil {
                bars[column] = bar
            } else {
                extras.append(bar)
            }
        }
        self.bars = bars
        self.extras = extras
    }

    /// The compact reset text under a column's bar ("45m", "3h", "6d"), or nil
    /// when the window published none. Measured from `now`, like the spoken form.
    public func compactReset(for column: WindowColumn) -> String? {
        ResetCountdownBadge.compact(bars[column]?.resetsAt, now: now)
    }

    /// True when the row has anything to put in the grid. A row with nothing
    /// there keeps the chip fallback layout.
    public var usesGrid: Bool {
        !bars.isEmpty
    }

    /// The one column this row draws, when the vendor published a single meter
    /// and nothing else to put beside it — GitHub Copilot reports a monthly
    /// window only, OpenAI a weekly one.
    ///
    /// A lone cell used to sit marooned in one of the three columns with a
    /// faint dash either side, which reads as two missing readings rather than
    /// as "this vendor publishes one window". The row draws its sole meter
    /// across the whole grid instead (`MetricRowView`).
    ///
    /// nil as soon as the grid holds two cells: the columns are then doing
    /// their job of lining the same window up down the card. nil too when the
    /// row draws a pool on its own line under the grid (`extras`), because
    /// that row shows more than one meter and is not the sparse case this
    /// answers.
    public var soleColumn: WindowColumn? {
        guard extras.isEmpty else { return nil }
        let filled = WindowColumn.allCases.filter { bars[$0] != nil }
        return filled.count == 1 ? filled[0] : nil
    }

    /// The figure printed under a bar: the share used, which is what the bar
    /// itself draws. nil when the vendor published no fraction — the cell
    /// then says why in words (`unmeasuredText`) instead of printing 0%.
    public static func percentText(for bar: DualBarMetrics) -> String? {
        guard let fraction = bar.primaryFraction else { return nil }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// Display-only treatment. Keep the actual percentage in spoken summaries
    /// and quota calculations, including when its redundant label is hidden.
    public static func isExhausted(_ bar: DualBarMetrics) -> Bool {
        !bar.measuresElapsedTimeOnly
            && bar.primaryFraction.map { $0 >= QuotaSnapshot.exhaustionThreshold } == true
    }

    static func visiblePercentText(for bar: DualBarMetrics) -> String? {
        isExhausted(bar) ? nil : percentText(for: bar)
    }

    static func showsExhaustionGlyph(for bar: DualBarMetrics) -> Bool {
        isExhausted(bar) || showsBlockedGlyph(for: bar)
    }

    /// Whether a figure needs the blocked glyph beside it: the vendor blocked
    /// the window yet reported how much of it was used. Without a percentage
    /// the cell says "Blocked" in words, so the glyph would repeat it.
    public static func showsBlockedGlyph(for bar: DualBarMetrics) -> Bool {
        bar.isBlocked && bar.primaryFraction != nil
    }

    /// The words for a bar with no fraction.
    ///
    /// A published balance prints in the cell. A blocked window says so. A
    /// window with neither stays a dash, which means "not published".
    public static func unmeasuredText(for bar: DualBarMetrics) -> String {
        if bar.isBlocked { return "Blocked" }
        return bar.balanceCaption ?? "—"
    }

    /// Everything the grid draws, in words, for the row label: "5-hour 42%
    /// used, resets in 3 hours, weekly 80% used, ahead of an even pace, resets
    /// in 6 days", then the non-window pools by token ("BN 50% used"). A figure
    /// a sighted user can read must reach VoiceOver too: the reset time under
    /// each bar, and the amber fill that means "ahead of an even pace", which
    /// would otherwise be colour alone. Only windows in columns show either, so
    /// only they speak them.
    public func spokenSummary(now explicitNow: Date? = nil) -> String? {
        let now = explicitNow ?? self.now
        func spoken(_ bar: DualBarMetrics, name: String, isColumn: Bool = false) -> String {
            var text: String
            let isCommandCodeMonth = vendorId == .commandcode && isColumn && bar.label == WindowColumn.monthly.label
            let percent: String?
            if isCommandCodeMonth, let fraction = bar.primaryFraction, fraction < 1, Self.isExhausted(bar) {
                percent = fraction.formatted(.percent.precision(.fractionLength(2))
                    .locale(Locale(identifier: "en_US_POSIX")))
            } else {
                percent = Self.percentText(for: bar)
            }
            if let percent {
                text = "\(name) \(percent) used"
                // The vendor can block a window and still report how much of
                // it was used (OpenCode Go does). The bar then wears the
                // vendor's blocked colour, which is colour alone: say it.
                if bar.isBlocked { text += ", blocked" }
            } else if bar.isBlocked {
                text = "\(name) blocked"
            } else if let balance = bar.balanceCaption {
                text = "\(name) \(balance) remaining, no percentage"
            } else if isCommandCodeMonth, let detail = bar.usedText {
                text = "\(name) \(detail), no percentage"
            } else {
                text = "\(name) no reading"
            }
            guard isColumn else { return text }
            // The amber fill, in words. `isMeaningfullyAheadOfPace` already
            // excludes a blocked window (vendor colour), a spent one (red) and
            // any pace whose tick is not drawn.
            if bar.isMeaningfullyAheadOfPace {
                text += ", ahead of an even pace"
            }
            if let reset = ResetCountdownBadge.compactSpoken(bar.resetsAt, now: now) {
                text += ", \(reset)"
            }
            return text
        }
        var parts = WindowColumn.allCases.compactMap { column -> String? in
            bars[column].map { spoken($0, name: column.spokenName, isColumn: true) }
        }
        parts += extras.map { spoken($0, name: $0.label) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
