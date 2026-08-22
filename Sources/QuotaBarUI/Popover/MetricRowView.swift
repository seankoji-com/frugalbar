import SwiftUI
import QuotaBarCore

/// A single high-density row showing one provider's status, dual-bar burndown chart,
/// and interactive detail trigger.
struct MetricRowView: View {

    let snapshot: QuotaSnapshot
    var isAltRow: Bool = false
    var onSelect: ((QuotaSnapshot) -> Void)? = nil

    @ScaledMetric(relativeTo: .caption) private var barWidth: CGFloat = 64
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

    private var rowBackground: Color {
        if isHovered {
            return Color.white.opacity(0.08)
        } else if isAltRow {
            return Theme.surfaceContainerLow.opacity(0.40)
        } else {
            return Color.clear
        }
    }



    var body: some View {
        HStack(spacing: 8) {
            // Vendor avatar badge
            VendorAvatarView(vendorId: snapshot.vendorId, status: snapshot.status)

            // Two lines: vendor, then the plan the provider actually reported.
            VStack(alignment: .leading, spacing: 1.5) {
                Text(snapshot.shortVendorName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.onSurface)
                    .lineLimit(1)

                if !snapshot.shortPlanName.isEmpty {
                    Text(snapshot.shortPlanName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(width: 80, alignment: .leading)



            if !snapshot.bars.isEmpty {
                // Multi-bar (5H / WK / MO) burndown charts
                VStack(spacing: 3.5) {
                    ForEach(Array(snapshot.bars.enumerated()), id: \.offset) { _, barMetrics in
                        DualBarProgressView(
                            metrics: barMetrics,
                            accentColor: accentColor,
                            urgency: snapshot.status.urgency
                        )
                    }
                }
            } else if case .currency(let balance, let limit, let spent, let currencyCode) = snapshot.metric {
                // Driven by the provider's declared basis, not by matching on
                // prose: a copy edit to auxiliaryInfo must not relabel money.
                let basis: CurrencyBasis = snapshot.currencyBasis ?? (limit == nil ? .lifetimeSpend : .keySpendCap)
                let spendLabel = basis.spendLabel
                let balanceLabel = basis.balanceLabel
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(spendLabel)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))

                            let spentVal = spent ?? balance
                            Text(formatCurrency(spentVal, code: currencyCode))
                                .font(.system(size: 11, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.onSurface)
                        }

                        HStack(spacing: 4) {
                            Text(balanceLabel)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))

                            Text(formatCurrency(balance, code: currencyCode))
                                .font(.system(size: 10.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondary)
                        }
                    }


                    Spacer()

                    // Currency badge
                    Text(currencyCode)
                        .font(.system(size: 9, weight: .bold))
                        .monospaced()
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Theme.surfaceContainerHighest.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } else {
                // Subscription & count fallback layout (no progress bar unless a genuine denominator exists)
                Spacer()

                if let fraction = p.fraction, !typeSize.isAccessibilitySize {
                    MicroProgressBar(fraction: 1.0 - fraction, statusColor: urgencyColor)
                        .frame(width: barWidth)
                }


                Text(p.valueLabel)
                    .font(.system(size: 10.5, weight: p.isMeasured ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(p.isMeasured ? (p.fraction != nil ? urgencyColor : Theme.secondary) : Theme.outline)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Theme.surfaceContainerHighest.opacity(0.50))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4.5)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
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



