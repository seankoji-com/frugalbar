import SwiftUI
import Charts
import QuotaBarCore

/// The popover's inline balance sparkline: a compact strip beside a row's
/// figure, drawn only when there is a real trend to draw.
///
/// It carries no axis, no label and no accessibility of its own — the row is
/// one accessibility element and speaks its own figure — because at 46×16pt an
/// axis is unreadable and a screen reader has nothing to gain from the shape.
/// Its job is "is this moving, and which way", and the figure beside it is the
/// number.
struct BalanceSparklineView: View {

    let presentation: BalanceSparklinePresentation
    var width: CGFloat = 46
    var height: CGFloat = 16
    var tint: Color = Theme.onSurfaceVariant.opacity(0.85)

    var body: some View {
        Chart {
            ForEach(Array(presentation.points.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.x),
                    y: .value("Balance", point.y)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// The inspector's balance chart: the same points at a readable size, with the
/// value axis in the vendor's own unit and the latest figure marked.
///
/// The axis is labelled through the same formatter the row prints with, so the
/// chart and the figure it came from can never disagree on what a point means.
struct BalanceChartView: View {

    let presentation: BalanceSparklinePresentation
    /// Formats one figure in the series' own unit — money through `MoneyText`,
    /// a credit count in credits.
    let format: (Decimal) -> String

    var body: some View {
        Chart {
            ForEach(Array(presentation.points.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.x),
                    y: .value("Balance", point.y)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            if let last = presentation.points.last {
                PointMark(x: .value("Time", last.x), y: .value("Balance", last.y))
                    .foregroundStyle(Theme.primary)
                    .symbolSize(24)
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0.0, 1.0]) { value in
                AxisGridLine().foregroundStyle(Theme.outlineVariant.opacity(0.3))
                AxisValueLabel {
                    if let fraction = value.as(Double.self) {
                        // The axis' own ends are the series' real extremes, so
                        // they are labelled with the figures the vendor
                        // published — never with the normalised position.
                        Text(format(fraction >= 0.5 ? presentation.maxValue : presentation.minValue))
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.outline)
                    }
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        "Balance history, \(presentation.sampleCount) readings, latest \(format(presentation.latestValue))"
    }
}
