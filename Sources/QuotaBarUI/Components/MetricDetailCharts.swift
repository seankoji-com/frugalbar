import SwiftUI
import Charts
import QuotaBarCore

// Charts for the provider inspector. Styling follows `QuotaTimelineChart`:
// colour from the urgency the app computed per reading, and point shape as
// the non-colour channel (WCAG 1.4.1).

enum DetailChartStyle {
    static func symbol(for point: BurndownPresentation.Point) -> BasicChartSymbolShape {
        if point.isBlocked { return .square }
        if point.urgency == .critical { return .triangle }
        if point.urgency == .warning { return .diamond }
        return .circle
    }

    static func color(for point: BurndownPresentation.Point) -> Color {
        if point.isBlocked || point.urgency == .critical { return Theme.error }
        if point.urgency == .warning { return Theme.tertiary }
        return Theme.healthy
    }

    static func axisFormat(span: TimeInterval) -> String {
        if span <= 36 * 3600 { return "HH:mm" }
        if span <= 8 * 86_400 { return "E d" }
        return "MMM d"
    }

    static func axisLabel(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

/// Remaining share of the current window: the readings, the vendor's
/// pro-rata pace when its window is known, the recent-pace projection when
/// one exists, and a rule at `now`.
struct BurndownChartView: View {
    let burndown: BurndownPresentation.Burndown
    let now: Date

    private var range: ClosedRange<Date>? { BurndownPresentation.windowRange(for: burndown) }

    private var axisFormat: String {
        DetailChartStyle.axisFormat(span: range.map { $0.upperBound.timeIntervalSince($0.lowerBound) } ?? 0)
    }

    private var projectionColor: Color {
        burndown.projectedExhaustion != nil ? Theme.error : Theme.tertiary
    }

    var body: some View {
        chart
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Theme.outlineVariant.opacity(0.35))
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)%")
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Theme.outlineVariant.opacity(0.20))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(DetailChartStyle.axisLabel(date, format: axisFormat))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(burndown.barLabel) burndown, remaining quota")
            .accessibilityValue(BurndownPresentation.accessibilityDescription(for: burndown, now: now))
    }

    @ViewBuilder
    private var chart: some View {
        let base = Chart {
            if let ideal = burndown.ideal {
                ForEach(Array(ideal.enumerated()), id: \.offset) { _, p in
                    LineMark(
                        x: .value("Time", p.date),
                        y: .value("Remaining %", p.remainingFraction * 100),
                        series: .value("Line", "Ideal")
                    )
                    .foregroundStyle(Theme.outline.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }

            ForEach(burndown.actual) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Remaining %", point.remainingFraction * 100),
                    series: .value("Line", "Actual")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(DetailChartStyle.color(for: point))
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Remaining %", point.remainingFraction * 100)
                )
                .foregroundStyle(DetailChartStyle.color(for: point))
                .symbol(DetailChartStyle.symbol(for: point))
                .symbolSize(point.isBlocked ? 26 : 14)
            }

            if let projection = burndown.projection {
                ForEach(Array(projection.enumerated()), id: \.offset) { _, p in
                    LineMark(
                        x: .value("Time", p.date),
                        y: .value("Remaining %", p.remainingFraction * 100),
                        series: .value("Line", "Projection")
                    )
                    .foregroundStyle(projectionColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [1.5, 3]))
                }
            }

            if range.map({ $0.contains(now) }) ?? true {
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(Theme.primary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, spacing: 1) {
                        Text("now")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.primary.opacity(0.8))
                    }
            }
        }
        if let range {
            base.chartXScale(domain: range)
        } else {
            base
        }
    }
}

/// Used share over time for every consumable window of one vendor. Windows
/// are told apart by dash pattern (and the legend), not by colour, which
/// stays the per-reading urgency.
struct UsageHistoryChartView: View {
    let series: [BurndownPresentation.Series]
    let range: HistoryPresentation.TimeRange
    let markers: [AIEvent]
    let now: Date

    private var labels: [String] {
        var out: [String] = []
        for s in series where !out.contains(s.label) { out.append(s.label) }
        return out
    }

    private static let dashes: [[CGFloat]] = [[], [5, 3], [1.5, 2.5]]

    private func dash(for label: String) -> [CGFloat] {
        let index = labels.firstIndex(of: label) ?? 0
        return Self.dashes[index % Self.dashes.count]
    }

    private var axisFormat: String {
        switch range {
        case .last24Hours: "HH:mm"
        case .last7Days: "E d"
        case .last30Days, .allTime: "MMM d"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if labels.count > 1 {
                HStack(spacing: 10) {
                    ForEach(labels, id: \.self) { label in
                        HStack(spacing: 4) {
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: 4))
                                p.addLine(to: CGPoint(x: 16, y: 4))
                            }
                            .stroke(Theme.onSurfaceVariant, style: StrokeStyle(lineWidth: 1.5, dash: dash(for: label)))
                            .frame(width: 16, height: 8)
                            Text(label)
                                .font(Theme.Typography.token)
                                .foregroundStyle(Theme.onSurfaceVariant)
                        }
                    }
                }
                .accessibilityHidden(true)
            }
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series) { s in
                ForEach(s.points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used %", point.usedFraction * 100),
                        series: .value("Segment", s.id)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(DetailChartStyle.color(for: point))
                    .lineStyle(StrokeStyle(lineWidth: 1.8, dash: dash(for: s.label)))

                    PointMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used %", point.usedFraction * 100)
                    )
                    .foregroundStyle(DetailChartStyle.color(for: point))
                    .symbol(DetailChartStyle.symbol(for: point))
                    .symbolSize(point.isBlocked ? 22 : 10)
                }
            }

            ForEach(markers) { event in
                RuleMark(x: .value("Event", event.occurredAt))
                    .foregroundStyle(EventsPresentation.kindTint(event.kind).opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 1) {
                        Image(systemName: event.kind.symbolName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(EventsPresentation.kindTint(event.kind))
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: (range.startDate(from: now) ?? now.addingTimeInterval(-86_400))...now)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.35))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.20))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(DetailChartStyle.axisLabel(date, format: axisFormat))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage history, \(range.title)")
        .accessibilityValue(
            ([BurndownPresentation.historyAccessibilityDescription(series: series, range: range)]
             + [EventsPresentation.markerAccessibilitySummary(count: markers.count)].compactMap { $0 })
            .joined(separator: ". ")
        )
    }
}

/// Honest empty state for the inspector chart.
struct ChartEmptyState: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.4))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}
