import SwiftUI
import QuotaBarCore

/// A single provider row: vendor mark, name and plan, and the burndown bars for
/// every window that vendor publishes.
struct MetricRowView: View {

    let snapshot: QuotaSnapshot
    var onSelect: ((QuotaSnapshot) -> Void)? = nil

    @ScaledMetric(relativeTo: .caption) private var barWidth: CGFloat = 84
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isHovered = false

    private var p: MetricRowPresentation { MetricRowPresentation(snapshot: snapshot) }

    private var accentColor: Color {
        Color(hexString: snapshot.vendorId.accentColorHex) ?? Theme.primary
    }

    private var urgencyColor: Color {
        switch p.urgency {
        case .none:     Theme.secondary
        case .warning:  Theme.tertiary
        case .critical: Theme.error
        }
    }

    /// The second line of the name column. An exhausted provider spends it on
    /// the vendor's own reset text — the plan name is the least useful thing to
    /// print about a quota you cannot currently use. Falls back to the plan
    /// when the vendor published no reset rather than inventing one.
    private var subtitle: String {
        if p.isExhausted, let reset = p.exhaustedResetText, !reset.isEmpty {
            return reset
        }
        return snapshot.shortPlanName
    }

    private var subtitleColor: Color {
        p.isExhausted ? Theme.error : Theme.onSurfaceVariant.opacity(0.85)
    }

    var body: some View {
        HStack(spacing: 9) {
            VendorAvatarView(
                vendorId: snapshot.vendorId,
                status: snapshot.status,
                isExhausted: p.isExhausted,
                size: 30
            )

            // Two lines: vendor, then the plan the provider actually reported.
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.shortVendorName)
                    .font(Theme.Typography.title)
                    .tracking(Theme.Tracking.title)
                    .foregroundStyle(Theme.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                // A money provider has no plan, but it does have the one figure
                // that matters at a glance: what is left. It takes the subtitle
                // slot rather than competing for the row's right-hand side.
                if case .currency(let balance, _, _, let code) = snapshot.metric,
                   snapshot.status.confidence == .measured {
                    // Set as a figure, not as a second title. Two 17pt bolds
                    // stacked made this the heaviest row in the popover for no
                    // reason other than that it happens to hold money.
                    Text(formatCurrency(balance, code: code))
                        .font(Theme.Typography.numeric)
                        .tracking(Theme.Tracking.numeric)
                        .foregroundStyle(snapshot.status.urgency == .none
                                         ? Theme.healthy : Theme.error)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(width: Theme.nameColumnWidth, alignment: .leading)

            if !snapshot.bars.isEmpty {
                // Multi-bar (5H / WK / MO) burndown charts
                VStack(spacing: 5) {
                    ForEach(Array(snapshot.bars.enumerated()), id: \.offset) { _, barMetrics in
                        DualBarProgressView(
                            metrics: barMetrics,
                            accentColor: accentColor,
                            urgency: snapshot.status.urgency
                        )
                    }
                }
            } else if !snapshot.spendWindows.isEmpty {
                // Spend per window. Deliberately not a bar: spend has no cap to
                // measure against, so drawing one would invent a denominator.
                VStack(alignment: .trailing, spacing: 5) {
                    ForEach(Array(snapshot.spendWindows.enumerated()), id: \.offset) { _, window in
                        // Same spacing and token column as a bar row, so the
                        // money card's right edge lines up with the quota
                        // cards' instead of sitting 16pt short of it.
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Text(window.amount.map { formatCurrency($0, code: window.currencyCode) } ?? "—")
                                .font(Theme.Typography.numeric)
                                .tracking(Theme.Tracking.numeric)
                                .foregroundStyle(Theme.onSurface)
                            Text(window.label)
                                .font(Theme.Typography.token)
                                .tracking(Theme.Tracking.token)
                                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(width: Theme.tokenColumnWidth, alignment: .trailing)
                        }
                    }
                }
            } else {
                // Subscription & count fallback layout (no progress bar unless a genuine denominator exists)
                Spacer()

                if let fraction = p.fraction, !typeSize.isAccessibilitySize {
                    MicroProgressBar(fraction: 1.0 - fraction, statusColor: urgencyColor)
                        .frame(width: barWidth)
                }

                Text(p.valueLabel)
                    .font(Theme.Typography.chip)
                    .foregroundStyle(p.isMeasured ? (p.fraction != nil ? urgencyColor : Theme.secondary) : Theme.outline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surfaceContainerHighest.opacity(0.50))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: Theme.rowMinHeight)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
                .padding(.horizontal, -6)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            onSelect?(snapshot)
        }
        .help(p.accessibilityLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.accessibilityLabel)
    }

    private func formatCurrency(_ value: Decimal, code: String) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        if code == "AUD" {
            return String(format: "A$%.2f", d)
        } else if code == "USD" {
            return String(format: "$%.2f", d)
        } else {
            return String(format: "%.2f %@", d, code)
        }
    }
}
