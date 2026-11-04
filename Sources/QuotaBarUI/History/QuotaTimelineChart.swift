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
    /// Overrides the empty state's title, for polls that happened but left
    /// nothing to draw.
    public let emptyTitle: String?
    /// The inspected instant: where the pointer is over the plot, or the poll
    /// the keyboard stepped to. Drives the readout.
    @State private var hoverDate: Date?

    /// What the marks draw: `segments` thinned to real readings at about one
    /// per bucket (`HistoryPresentation.thinnedForDisplay`). Computed once here,
    /// not per body evaluation, because the body re-runs on every pointer move.
    /// Inspection and the spoken summary read the full `segments`.
    private let drawnSegments: [HistoryPresentation.TimelineSegment]
    /// Nearby events merged into one rule (about 32 across the plot, room for a
    /// symbol and a two-digit count), so a month of resets does not stack
    /// dozens of symbols along the top edge.
    private let markerClusters: [MarkerCluster]
    /// The drawn points are a thinned copy (a long range).
    private let isThinned: Bool

    public init(
        segments: [HistoryPresentation.TimelineSegment],
        timeRange: HistoryPresentation.TimeRange,
        markers: [AIEvent] = [],
        emptyMessage: String? = nil,
        emptyTitle: String? = nil
    ) {
        self.segments = segments
        self.timeRange = timeRange
        self.markers = markers
        self.emptyMessage = emptyMessage
        self.emptyTitle = emptyTitle
        self.drawnSegments = HistoryPresentation.thinnedForDisplay(segments)
        self.labels = Self.labels(of: segments)
        self.isThinned = drawnSegments != segments
        let times = segments.flatMap { $0.points.map(\.timestamp) } + markers.map(\.occurredAt)
        let span = (times.max() ?? Date()).timeIntervalSince(times.min() ?? Date())
        self.markerClusters = Self.clusters(markers, span: span)
    }

    /// One or more recorded events drawn as a single rule.
    struct MarkerCluster: Identifiable, Equatable {
        var id: String { events[0].id }
        let events: [AIEvent]
        var date: Date { events[0].occurredAt }
    }

    /// Events grouped while each falls within `span / slots` of its group's
    /// first event: about `slots` rules across the chart at most. Every event
    /// stays in exactly one group, so the help text and the count can name all
    /// of them; nothing is dropped.
    static func clusters(_ markers: [AIEvent], span: TimeInterval, slots: Int = 32) -> [MarkerCluster] {
        let sorted = markers.sorted { $0.occurredAt < $1.occurredAt }
        let width = max(span / Double(max(slots, 1)), 0)
        var out: [[AIEvent]] = []
        for event in sorted {
            if let start = out.last?.first,
               event.occurredAt.timeIntervalSince(start.occurredAt) <= width {
                out[out.count - 1].append(event)
            } else {
                out.append([event])
            }
        }
        return out.map { MarkerCluster(events: $0) }
    }

    private static func clusterHelp(_ cluster: MarkerCluster) -> String {
        let lines = cluster.events.prefix(6).map { "\($0.kind.title): \($0.title)" }
        let more = cluster.events.count > 6 ? ["and \(cluster.events.count - 6) more"] : []
        return (lines + more).joined(separator: "\n")
    }

    public var body: some View {
        if segments.isEmpty || segments.allSatisfy({ $0.points.isEmpty }) {
            emptyState
        } else {
            // The legend sits under the plot: above it, the event symbols that
            // annotate the plot's top edge collided with it.
            VStack(alignment: .leading, spacing: 6) {
                chart
                if labels.count > 1 {
                    WindowDashLegend(labels: labels)
                }
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

    /// Computed once in `init`. As a computed property it walked every segment
    /// for every drawn point (it fed each point's dash), which a stack sample
    /// of All Time put second only to Charts itself on the main thread.
    private let labels: [String]

    private static func labels(of segments: [HistoryPresentation.TimelineSegment]) -> [String] {
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
            ForEach(drawnSegments) { segment in
                let dash = WindowDashLegend.dash(for: segment.barLabel, in: labels)
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used %", point.fraction * 100),
                        series: .value("Segment", segment.id)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(colorForPoint(point))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, dash: dash))

                    // A thinned (long-range) chart marks only the readings
                    // that are not healthy: their shapes stay the non-colour
                    // channel, and a symbol on every healthy point was most of
                    // the clutter at 30 days and beyond. Short ranges keep a
                    // symbol on every reading.
                    if !isThinned || point.isBlocked || point.urgency != .none {
                        PointMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Used %", point.fraction * 100)
                        )
                        .foregroundStyle(colorForPoint(point))
                        .symbol(symbol(for: point))
                        .symbolSize(point.isBlocked ? 28 : 18)
                    }
                }
            }

            // Shape (the kind's symbol) carries the marker, not the tint.
            ForEach(markerClusters) { cluster in
                let kind = cluster.events[0].kind
                RuleMark(x: .value("Event", cluster.date))
                    .foregroundStyle(EventsPresentation.kindTint(kind).opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        HStack(spacing: 1) {
                            Image(systemName: kind.symbolName)
                                .font(.system(size: 10, weight: .semibold))
                            if cluster.events.count > 1 {
                                Text("\(cluster.events.count)")
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            }
                        }
                        .foregroundStyle(EventsPresentation.kindTint(kind))
                        .help(Self.clusterHelp(cluster))
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

            Text(emptyTitle ?? "No readings recorded in this time range")
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
