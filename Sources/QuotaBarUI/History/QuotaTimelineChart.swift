import SwiftUI
import Charts
import QuotaBarCore

/// Line chart displaying historical quota usage segments.
///
/// Discontinuous reset periods and long gaps break the line rather than falling
/// abruptly to 0%, accurately reflecting provider quota windows.
public struct QuotaTimelineChart: View {
    public let segments: [HistoryPresentation.TimelineSegment]
    public let timeRange: HistoryPresentation.TimeRange

    public init(
        segments: [HistoryPresentation.TimelineSegment],
        timeRange: HistoryPresentation.TimeRange
    ) {
        self.segments = segments
        self.timeRange = timeRange
    }

    public var body: some View {
        if segments.isEmpty || segments.allSatisfy({ $0.points.isEmpty }) {
            emptyState
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            // 80% Warning threshold guide
            RuleMark(y: .value("Warning", 80))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Theme.tertiary.opacity(0.6))
                .annotation(position: .top, alignment: .trailing) {
                    Text("80% Warning")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiary.opacity(0.8))
                        .padding(.trailing, 4)
                }

            // 95% Critical threshold guide
            RuleMark(y: .value("Critical", 95))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Theme.error.opacity(0.7))
                .annotation(position: .top, alignment: .trailing) {
                    Text("95% Critical")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.error.opacity(0.9))
                        .padding(.trailing, 4)
                }

            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used %", point.fraction * 100),
                        series: .value("Segment", segment.id.uuidString)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(colorForPoint(point))
                    .lineStyle(StrokeStyle(lineWidth: 2.2))

                    PointMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used %", point.fraction * 100)
                    )
                    .foregroundStyle(colorForPoint(point))
                    .symbolSize(point.isBlocked ? 24 : 14)
                }
            }
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
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.4))

            Text("No readings recorded in this time range")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))

            Text("Readings accumulate automatically as FrugalBar polls your providers.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func colorForPoint(_ point: HistoryPresentation.TimelinePoint) -> Color {
        if point.isBlocked || point.urgency == .critical || point.fraction >= 0.95 {
            return Theme.error
        }
        if point.urgency == .warning || point.fraction >= 0.80 {
            return Theme.tertiary
        }
        return Theme.healthy
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
