import SwiftUI
import QuotaBarCore

/// A single high-density row showing one provider's status.
///
/// Layout budget: the popover is 340pt wide and this row carries 16pt of
/// horizontal padding, so its content must fit 324pt. The previous revision
/// summed to 356pt and clipped on every launch. Widths here are proportional
/// rather than fixed so the row also survives larger Dynamic Type sizes.
struct MetricRowView: View {

    let snapshot: QuotaSnapshot

    @ScaledMetric(relativeTo: .caption) private var barWidth: CGFloat = 64
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Bar and reset columns are the first things to go when text grows.
    private var showsBar: Bool { !typeSize.isAccessibilitySize }
    private var showsReset: Bool { !typeSize.isAccessibilitySize }

    // MARK: - Derived presentation

    private var p: MetricRowPresentation { MetricRowPresentation(snapshot: snapshot) }

    private var urgencyColor: Color {
        switch p.urgency {
        case .none:     .green
        case .warning:  .orange
        case .critical: .red
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {
            StatusIndicatorDot(status: snapshot.status)

            Text(snapshot.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsBar {
                MicroProgressBar(fraction: p.fraction, statusColor: urgencyColor)
                    .frame(width: barWidth)
            }

            Text(p.valueLabel)
                .font(.caption2)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(
                    p.isMeasured ? urgencyColor : Color.secondary
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if showsReset, snapshot.resetsAt != nil {
                Text(p.resetLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .help(p.accessibilityLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.accessibilityLabel)
    }
}
