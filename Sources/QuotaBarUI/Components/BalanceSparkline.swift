import Foundation
import QuotaBarCore

/// The pure shape of a balance sparkline: the recorded points normalised to a
/// unit box, ready for either the popover's inline strip or the inspector's
/// larger chart.
///
/// Extracted from the view so the two things that can actually go wrong are
/// assertable: drawing a line from a single reading (which would be a
/// fabricated trend rather than a record of change), and normalising a flat
/// series off the top or bottom of its own box.
public struct BalanceSparklinePresentation: Equatable, Sendable {

    /// A normalised point. `x` and `y` are both 0…1; `y` is 1 at the highest
    /// recorded figure and 0 at the lowest.
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
    }

    /// Oldest first. At least two.
    public let points: [Point]
    /// The most recent recorded figure, for the chart's readout. Never derived
    /// from the normalised shape — the shape has no unit.
    public let latestValue: Decimal
    /// The highest and lowest recorded figures, so an axis can label its own
    /// ends with real numbers rather than the normalised positions.
    public let minValue: Decimal
    public let maxValue: Decimal
    /// The change between the first and last recorded figure, signed.
    public let change: Decimal
    /// How many readings the series holds.
    public let sampleCount: Int
    /// True when every recorded figure is identical, so the line is flat. The
    /// view draws it centred rather than pinned to an edge.
    public let isFlat: Bool
    /// When the oldest and newest readings were recorded: a fall over two
    /// days and one over twelve draw the same normalised line, so the span
    /// is said beside it.
    public var firstMeasuredAt: Date = .distantPast
    public var lastMeasuredAt: Date = .distantPast

    /// "over 11 days" (or hours, under a day).
    public var spanDescription: String {
        let span = max(0, lastMeasuredAt.timeIntervalSince(firstMeasuredAt))
        if span >= 86_400 {
            let days = Int((span / 86_400).rounded())
            return "over \(days) day\(days == 1 ? "" : "s")"
        }
        let hours = max(1, Int((span / 3600).rounded()))
        return "over \(hours) hour\(hours == 1 ? "" : "s")"
    }

    /// nil when there is nothing honest to draw: fewer than two readings is not
    /// a trend, it is one observation (or none).
    public static func make(from points: [BalancePoint]) -> BalanceSparklinePresentation? {
        guard points.count >= 2 else { return nil }
        let ordered = points.sorted { $0.measuredAt < $1.measuredAt }
        let firstTime = ordered.first!.measuredAt.timeIntervalSince1970
        let lastTime = ordered.last!.measuredAt.timeIntervalSince1970
        let span = lastTime - firstTime

        let values = ordered.map(\.value)
        let minValue = values.min()!
        let maxValue = values.max()!
        let range = maxValue - minValue
        let isFlat = range == 0

        let normalised: [Point] = ordered.map { point in
            let x = span > 0 ? (point.measuredAt.timeIntervalSince1970 - firstTime) / span : 0
            let y: Double
            if isFlat {
                // A flat series has no top or bottom to sit at. Centred, the
                // line reads as "unchanged"; pinned to 0 it would read as a
                // reserve that emptied.
                y = 0.5
            } else {
                let value = NSDecimalNumber(decimal: point.value).doubleValue
                let low = NSDecimalNumber(decimal: minValue).doubleValue
                let high = NSDecimalNumber(decimal: maxValue).doubleValue
                y = (value - low) / (high - low)
            }
            return Point(x: x, y: y)
        }

        var presentation = BalanceSparklinePresentation(
            points: normalised,
            latestValue: ordered.last!.value,
            minValue: minValue,
            maxValue: maxValue,
            change: ordered.last!.value - ordered.first!.value,
            sampleCount: ordered.count,
            isFlat: isFlat
        )
        presentation.firstMeasuredAt = ordered.first!.measuredAt
        presentation.lastMeasuredAt = ordered.last!.measuredAt
        return presentation
    }

    /// How a series ended against where it began.
    ///
    /// A series can move and come back — readings 5, 1, 5 are not flat, their
    /// range is 4, yet their net change is zero — and picking the arrow from
    /// `change >= 0` printed "▲ 0" for one of those, claiming a rise that did
    /// not happen.
    public enum Trend: Equatable, Sendable {
        case rose, fell, returned

        public static func of(change: Decimal) -> Trend {
            if change > 0 { return .rose }
            if change < 0 { return .fell }
            return .returned
        }
    }

    /// The line under the chart: the latest figure, how it got there, and how
    /// many readings stand behind it. Pure, so the wording for a series that
    /// ended exactly where it started is assertable rather than only visible.
    ///
    /// A flat series is said as *unchanged* rather than as "▲ 0": every figure
    /// is the same, so there was no movement to describe.
    /// The inline strip's direction in words, for the Wallet line's label:
    /// the strip itself is hidden from VoiceOver, so without this the trend a
    /// sighted user reads at a glance was only reachable in the inspector.
    public var spokenTrend: String {
        guard !isFlat else { return "unchanged across \(sampleCount) readings \(spanDescription)" }
        switch Trend.of(change: change) {
        case .rose: return "rising across \(sampleCount) readings \(spanDescription)"
        case .fell: return "falling across \(sampleCount) readings \(spanDescription)"
        case .returned: return "back where it started across \(sampleCount) readings \(spanDescription)"
        }
    }

    public func caption(in unit: BalanceSeries.Unit) -> String {
        let latest = unit.format(latestValue)
        guard !isFlat else {
            return "Unchanged at \(latest) across \(sampleCount) readings"
        }
        switch Trend.of(change: change) {
        case .rose:
            return "\(latest) · ▲ \(unit.format(change)) across \(sampleCount) readings"
        case .fell:
            return "\(latest) · ▼ \(unit.format(-change)) across \(sampleCount) readings"
        case .returned:
            return "\(latest) · no net change across \(sampleCount) readings"
        }
    }
}
