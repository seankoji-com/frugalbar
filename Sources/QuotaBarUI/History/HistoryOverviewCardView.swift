import SwiftUI
import Charts
import QuotaBarCore

/// One small multiple in the History overview: a provider's longest window,
/// its latest reading and a sparkline of the readings in range. Clicking it
/// charts that provider below.
struct HistoryOverviewCardView: View {
    let card: HistoryOverviewPresentation.Card
    let isSelected: Bool
    let onSelect: () -> Void

    private var latestRow: ReadingReadout.Row? {
        card.latest.fraction.map {
            ReadingReadout.Row(label: card.barLabel, usedFraction: $0,
                               isBlocked: card.latest.isBlocked, urgency: card.latest.urgency)
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    VendorAvatarView(vendorId: card.subject.vendor, status: .healthy, size: 16)
                    Text(card.subject.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onSurface)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.primary)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let row = latestRow, let percent = card.latestPercent {
                        Image(systemName: ReadingReadout.symbol(for: row))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(ReadingReadout.color(for: row))
                        Text("\(percent)%")
                            .font(.system(size: 18, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.onSurface)
                        Text("\(card.barLabel) used")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                    } else {
                        // The newest poll got no figure; an older one is not
                        // promoted to "latest".
                        Text("No figure at the last reading")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.outline)
                    }
                    Spacer(minLength: 0)
                }

                sparkline
                    .frame(height: 30)

                Text("\(card.readingCount) reading\(card.readingCount == 1 ? "" : "s") · last \(ReadingReadout.timestampText(card.latest.measuredAt, showsDate: true))")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.outline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.primary.opacity(0.10) : Theme.surfaceContainerLowest.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Theme.primary.opacity(0.7) : Theme.outlineVariant.opacity(0.35),
                            lineWidth: isSelected ? 1.2 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Charts this provider below")
    }

    /// Real readings only, on a fixed 0–100% scale so two cards compare by
    /// eye; a gap or reset breaks the line.
    private var sparkline: some View {
        Chart {
            ForEach(card.segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used %", point.fraction * 100),
                        series: .value("Segment", segment.id)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
            }
            if let row = latestRow, let last = card.segments.last?.points.last,
               last.timestamp == card.latest.measuredAt {
                PointMark(x: .value("Time", last.timestamp), y: .value("Used %", last.fraction * 100))
                    .foregroundStyle(ReadingReadout.color(for: row))
                    .symbolSize(22)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        let window = WindowColumn.column(forLabel: card.barLabel)?.spokenName ?? card.barLabel
        var parts = [card.subject.name, "\(window) window"]
        if let percent = card.latestPercent {
            parts.append("latest \(percent) percent used")
            if card.latest.isBlocked { parts.append("blocked") }
        } else {
            parts.append("no figure at the last reading")
        }
        parts.append("\(card.readingCount) readings in range")
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}
