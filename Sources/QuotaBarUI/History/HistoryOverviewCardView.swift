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
                    if let percent = card.latestPercent {
                        Image(systemName: ReadingReadout.symbol(isBlocked: card.latest.isBlocked,
                                                                urgency: card.latest.urgency))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(latestColor)
                        Text("\(percent)%")
                            .font(.system(size: 18, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.onSurface)
                        Text("\(card.barLabel) used")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                    } else {
                        // The newest poll got no figure — it could not be
                        // read, or did not report this window — and an older
                        // one is not promoted to "latest".
                        Image(systemName: card.latestIsCurrent ? "minus.circle" : "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.outline)
                        Text(card.noFigureText ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.outline)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                sparkline
                    .frame(height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(card.sampleCount) sampled reading\(card.sampleCount == 1 ? "" : "s")")
                    Text("Last poll \(ReadingReadout.timestampText(card.lastPoll.measuredAt, showsDate: true))")
                }
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
            if card.latestPercent != nil, let last = card.segments.last?.points.last,
               last.timestamp == card.latest.measuredAt {
                PointMark(x: .value("Time", last.timestamp), y: .value("Used %", last.fraction * 100))
                    .foregroundStyle(latestColor)
                    .symbolSize(22)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }

    private var latestColor: Color {
        ReadingReadout.color(isBlocked: card.latest.isBlocked, urgency: card.latest.urgency)
    }

    private var accessibilityLabel: String {
        let window = WindowColumn.column(forLabel: card.barLabel)?.spokenName ?? card.barLabel
        var parts = [card.subject.name, "\(window) window"]
        if let percent = card.latestPercent {
            parts.append("latest \(percent) percent used")
            if card.latest.isBlocked { parts.append("blocked") }
        } else if let text = card.noFigureText {
            parts.append(text.lowercased())
        }
        parts.append("\(card.sampleCount) sampled readings in range")
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}
