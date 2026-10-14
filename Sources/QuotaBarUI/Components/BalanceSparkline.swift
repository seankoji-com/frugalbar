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

        return BalanceSparklinePresentation(
            points: normalised,
            latestValue: ordered.last!.value,
            minValue: minValue,
            maxValue: maxValue,
            change: ordered.last!.value - ordered.first!.value,
            sampleCount: ordered.count,
            isFlat: isFlat
        )
    }
}
