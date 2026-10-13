import SwiftUI
import Charts
import QuotaBarCore

/// Line chart displaying historical quota usage segments.
///
/// Discontinuous reset periods and long gaps break the line rather than falling
/// abruptly to 0%, accurately reflecting provider quota windows.
///
/// There are deliberately no "80% warning" / "95% critical" guide lines. This
/// app already has a vocabulary for those states — `Urgency` (warning above 70%,
/// critical above 90%) and `DualBarMetrics.exhaustionThreshold` (0.999) — and
/// drawing a third, chart-local pair asserted a policy nobody had measured. The
/// chart now renders the urgency the app actually computed, per point.
public struct QuotaTimelineChart: View {
    public let segments: [HistoryPresentation.TimelineSegment]
    public let timeRange: HistoryPresentation.TimeRange
    /// Recorded reset-type events, drawn as dashed vertical rules. Callers
    /// filter with `EventsPresentation.markerEvents`.
    public let markers: [AIEvent]
    /// Why there is nothing to draw, when there is nothing. Defaults to the
    /// generic explanation.
    public let emptyMessage: String?
    /// The inspected instant: where the pointer is over the plot, or the poll
    /// the keyboard stepped to. Drives the readout.
    @State private var hoverDate: Date?

    public init(
        segments: [HistoryPresentation.TimelineSegment],
        timeRange: HistoryPresentation.TimeRange,
        markers: [AIEvent] = [],
        emptyMessage: String? = nil
    ) {
        self.segments = segments
        self.timeRange = timeRange
        self.markers = markers
        self.emptyMessage = emptyMessage
    }

    public var body: some View {
        if segments.isEmpty || segments.allSatisfy({ $0.points.isEmpty }) {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if labels.count > 1 {
                    WindowDashLegend(labels: labels)
                }
                chart
            }
        }
    }

    /// Windows in the order they first appear. Told apart by dash pattern, not
    /// colour, which stays the per-reading urgency.
    /// The chart with the readout already open at `date`, as the pointer
    /// would leave it. The render harness uses it to show the readout.
    func inspecting(_ date: Date?) -> QuotaTimelineChart {
        var copy = self
        copy._hoverDate = State(initialValue: date)
        return copy
    }

    private var labels: [String] {
        var out: [String] = []
        for segment in segments where !out.contains(segment.barLabel) { out.append(segment.barLabel) }
        return out
    }

    private var tolerance: TimeInterval {
        HistoryOverviewPresentation.inspectionTolerance(
            range: timeRange, now: segments.compactMap { $0.points.last?.timestamp }.max() ?? Date(),
            earliest: segments.compactMap { $0.points.first?.timestamp }.min())
    }

    private var inspected: HistoryOverviewPresentation.InspectedPoll? {
        hoverDate.flatMap { HistoryOverviewPresentation.nearestPoll(to: $0, in: segments, tolerance: tolerance) }
    }

    /// Shape is the non-colour channel: colour alone fails WCAG 1.4.1, and
    /// "glance to know" is the entire product.
    private func symbol(for point: HistoryPresentation.TimelinePoint) -> BasicChartSymbolShape {
        if point.isBlocked { return .square }
        if point.urgency == .critical { return .triangle }
        if point.urgency == .warning { return .diamond }
        return .circle
    }

    private func colorForPoint(_ point: HistoryPresentation.TimelinePoint) -> Color {
        if point.isBlocked || point.urgency == .critical { return Theme.error }
        if point.urgency == .warning { return Theme.tertiary }
        return Theme.healthy
    }

    private func accessibilityDescription(for segment: HistoryPresentation.TimelineSegment) -> String {
        let worst = segment.points.max { $0.fraction < $1.fraction }
        guard let worst else { return "\(segment.barLabel) window, no readings" }
        let percent = Int((worst.fraction * 100).rounded())
        let state: String
        if worst.isBlocked {
            state = "blocked"
        } else if worst.urgency == .critical {
            state = "critical"
        } else if worst.urgency == .warning {
            state = "warning"
        } else {
            state = "healthy"
        }
        return "\(segment.barLabel) window, peak \(percent) percent used, \(state), \(segment.points.count) readings"
    }

    private var chart: some View {
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used %", point.fraction * 100),
                        series: .value("Segment", segment.id)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(colorForPoint(point))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, dash: WindowDashLegend.dash(for: segment.barLabel, in: labels)))

                    PointMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used %", point.fraction * 100)
                    )
                    .foregroundStyle(colorForPoint(point))
                    .symbol(symbol(for: point))
                    .symbolSize(point.isBlocked ? 28 : 18)
                }
            }

            // Shape (the kind's symbol) carries the marker, not the tint.
            ForEach(markers) { event in
                RuleMark(x: .value("Event", event.occurredAt))
                    .foregroundStyle(EventsPresentation.kindTint(event.kind).opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Image(systemName: event.kind.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(EventsPresentation.kindTint(event.kind))
                            .help("\(event.kind.title): \(event.title)")
                    }
            }

            if let poll = inspected {
                RuleMark(x: .value("Inspected", poll.timestamp))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ReadingReadout(poll: poll)
                    }
            }
        }
        .chartOverlay { proxy in
            ChartHoverCatcher(proxy: proxy) { hoverDate = $0 }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.35))
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.35))
                AxisValueLabel {
                    if let intVal = value.as(Int.self) {
                        Text("\(intVal)%")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.20))
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.35))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatAxisDate(date))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                    }
                }
            }
        }
        .modifier(ReadingInspection(
            segments: segments, selection: $hoverDate, tolerance: tolerance,
            label: "Quota timeline, \(timeRange.title)",
            summary: (segments.map(accessibilityDescription(for:))
                      + [EventsPresentation.markerAccessibilitySummary(count: markers.count)].compactMap { $0 })
                .joined(separator: ". ")))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.4))

            Text("No readings recorded in this time range")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))

            Text(emptyMessage ?? "Readings accumulate automatically as FrugalBar polls your providers.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.outline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
    }

    private func formatAxisDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        switch timeRange {
        case .last24Hours:
            formatter.dateFormat = "HH:mm"
        case .last7Days:
            formatter.dateFormat = "E d"
        case .last30Days, .allTime:
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }
}
