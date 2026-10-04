import Foundation
import QuotaBarCore

/// The popover's three window columns, in reading order: five-hour, weekly,
/// monthly.
///
/// A row puts each of its bars in the column its window token names, so the
/// same window lines up down the whole card instead of every vendor stacking
/// its own bars in its own order. Columns are keyed on the token rather than
/// on `windowLength`: the token is what each provider deliberately chose to
/// call the window, and a length can be missing (Command Code's monthly plan
/// credits publish no reset) or ambiguous.
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

    /// A spend amount placed in a column (OpenRouter's weekly and monthly
    /// spend). Text, never a bar: spend has no cap to measure against.
    public struct SpendCell: Equatable, Sendable {
        public let amount: Decimal?
        public let currencyCode: String
    }

    /// The bar in each column. A column the vendor does not publish is
    /// simply absent — drawn empty, never as 0%.
    public let bars: [WindowColumn: DualBarMetrics]
    public let spend: [WindowColumn: SpendCell]
    /// Bars that belong to no column, drawn on their own lines under the
    /// row with their own tokens, in the order the provider gave them.
    public let extras: [DualBarMetrics]

    public init(snapshot: QuotaSnapshot) {
        var bars: [WindowColumn: DualBarMetrics] = [:]
        var extras: [DualBarMetrics] = []
        for bar in snapshot.displayBars {
            if let column = WindowColumn.column(forLabel: bar.label), bars[column] == nil {
                bars[column] = bar
            } else {
                extras.append(bar)
            }
        }
        var spend: [WindowColumn: SpendCell] = [:]
        if bars.isEmpty {
            for window in snapshot.spendWindows {
                guard let column = WindowColumn.column(forLabel: window.label), spend[column] == nil else { continue }
                spend[column] = SpendCell(amount: window.amount, currencyCode: window.currencyCode)
            }
        }
        self.bars = bars
        self.spend = spend
        self.extras = extras
    }

    /// True when the row has anything to put in the grid. A row with nothing
    /// there keeps the chip fallback layout.
    public var usesGrid: Bool {
        !bars.isEmpty || !spend.isEmpty
    }

    /// The figure printed under a bar: the share used, which is what the bar
    /// itself draws. nil when the vendor published no fraction — the cell
    /// then says why in words (`unmeasuredText`) instead of printing 0%.
    public static func percentText(for bar: DualBarMetrics) -> String? {
        guard let fraction = bar.primaryFraction else { return nil }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// The words for a bar with no fraction.
    public static func unmeasuredText(for bar: DualBarMetrics) -> String {
        bar.isBlocked ? "Blocked" : "—"
    }

    /// Everything the grid draws, in words, for the row label: "5-hour 42%
    /// used, resets in 3 hours, weekly 80% used, ahead of an even pace, resets
    /// in 6 days", then spend cells ("weekly spend $3.10") and the non-window
    /// pools by token ("BN 50% used"). A figure a sighted user can read must
    /// reach VoiceOver too: the reset time under each bar, and the amber fill
    /// that means "ahead of an even pace", which would otherwise be colour
    /// alone. Only windows in columns show either, so only they speak them.
    public func spokenSummary(now: Date = Date()) -> String? {
        func spoken(_ bar: DualBarMetrics, name: String, isColumn: Bool = false) -> String {
            var text: String
            if let percent = Self.percentText(for: bar) {
                text = "\(name) \(percent) used"
            } else {
                text = "\(name) \(bar.isBlocked ? "blocked" : "no reading")"
            }
            guard isColumn else { return text }
            // The amber fill, in words. Not for a spent window, which is red
            // and draws no pace tick.
            if bar.isAboveProrataPace,
               (bar.primaryFraction ?? 0) < QuotaSnapshot.exhaustionThreshold {
                text += ", ahead of an even pace"
            }
            if let reset = ResetCountdownBadge.compactSpoken(bar.resetsAt, now: now) {
                text += ", \(reset)"
            }
            return text
        }
        var parts = WindowColumn.allCases.compactMap { column -> String? in
            if let bar = bars[column] { return spoken(bar, name: column.spokenName, isColumn: true) }
            if let cell = spend[column] {
                let amount = cell.amount.map { MetricRowPresentation.currency($0, cell.currencyCode) } ?? "not reported"
                return "\(column.spokenName) spend \(amount)"
            }
            return nil
        }
        parts += extras.map { spoken($0, name: $0.label) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
