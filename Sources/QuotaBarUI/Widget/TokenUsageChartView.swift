import SwiftUI
import Charts
import QuotaBarCore

/// The Tokens layout's stacked area: raw token consumption by provider over
/// time, with a legend of totals and the notes that say what the chart does
/// not cover. A pure view over a `TokenUsagePresentation.Chart`.
struct TokenUsageChartView: View {

    let chart: TokenUsagePresentation.Chart
    let range: HistoryPresentation.TimeRange

    private func color(_ vendor: VendorIdentifier) -> Color {
        Color(hexString: TokenUsagePresentation.layerColorHex(for: vendor)) ?? Theme.primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            plot
            legend
            notes
        }
    }

    // MARK: - Plot

    private var plot: some View {
        let names = chart.layers.map { $0.vendorId.displayName }
        let colors = chart.layers.map { color($0.vendorId) }
        return Chart {
            ForEach(chart.layers) { layer in
                let name = layer.vendorId.displayName
                // The area between this layer's edges in the stack...
                ForEach(layer.points) { point in
                    AreaMark(
                        x: .value("Time", point.x),
                        yStart: .value("From", point.lower),
                        yEnd: .value("To", point.upper),
                        series: .value("Area", name)
                    )
                    .foregroundStyle(by: .value("Provider", name))
                    .opacity(0.62)
                    .interpolationMethod(.monotone)
                }
            }
            // One line along the top of the stack: the total. A line per layer
            // would mislead, since where the layers above are empty their
            // edges coincide with the layer below's and would hide it.
            ForEach(chart.totals) { point in
                LineMark(
                    x: .value("Time", point.x),
                    y: .value("Total", point.tokens),
                    series: .value("Line", "Total")
                )
                .foregroundStyle(Theme.onSurface.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartLegend(.hidden)
        .chartXScale(domain: chart.domain)
        .chartYScale(domain: 0...max(chart.peak * 1.08, 1))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.35))
                AxisValueLabel {
                    if let tokens = value.as(Double.self) {
                        Text(TokenUsagePresentation.compact(Int(tokens)))
                            .font(.system(size: 9.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.2))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.axisLabel(date, range: range))
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token usage by provider, \(range.title)")
        .accessibilityValue(TokenUsagePresentation.accessibilitySummary(chart: chart, range: range))
    }

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("HHmm")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static func axisLabel(_ date: Date, range: HistoryPresentation.TimeRange) -> String {
        range == .last24Hours ? hourFormatter.string(from: date) : dayFormatter.string(from: date)
    }

    // MARK: - Legend and notes

    /// Fits on one line at the widget's default width; scrolls when narrower.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            legendRow
            ScrollView(.horizontal, showsIndicators: false) { legendRow }
        }
        .accessibilityHidden(true)   // the chart's accessibility value covers it
    }

    private var legendRow: some View {
            HStack(spacing: 10) {
                // The total is a real sum: tokens share one unit. It is said
                // to be observed, and where from, in the tooltip.
                Text("\(TokenUsagePresentation.compact(chart.totalTokens)) observed")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.onSurface)
                    .help("Tokens recorded by local sessions on this Mac, cache included, as each tool reports them. Not a quota, and not what any vendor billed.")
                ForEach(chart.layers) { layer in
                    HStack(spacing: 4) {
                        Capsule().fill(color(layer.vendorId)).frame(width: 10, height: 3)
                        Text("\(layer.vendorId.displayName) \(TokenUsagePresentation.compact(layer.totalTokens))")
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
            .fixedSize()
    }

    @ViewBuilder
    private var notes: some View {
        let lines = TokenUsagePresentation.notes(for: chart)
        if !lines.isEmpty {
            Text(lines.joined(separator: " "))
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)   // spoken in the chart's value
        }
    }
}
