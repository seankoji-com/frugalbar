import SwiftUI
import QuotaBarCore

/// A single high-density row showing one provider's status with micro progress bar.
struct MetricRowView: View {
    let snapshot: QuotaSnapshot

    private var statusColor: Color {
        switch snapshot.status {
        case .healthy:        .green
        case .warning:        .orange
        case .critical:       .red
        case .unauthenticated: .gray
        case .rateLimited:    .red
        case .networkError:   .gray
        }
    }

    private var progressColor: Color {
        let frac = snapshot.consumptionFraction
        if frac > 0.90 { return .red }
        if frac > 0.70 { return .orange }
        return .green
    }

    private var fractionLabel: String {
        switch snapshot.metric {
        case .percentage(let used, _):
            return "\(Int(used * 100))%"
        case .count(let remaining, let limit, _):
            return "\(remaining)/\(limit)"
        case .currency(let balance, let limit, _, let code):
            let bd = NSDecimalNumber(decimal: balance).doubleValue
            if let limit {
                let ld = NSDecimalNumber(decimal: limit).doubleValue
                return "\(formatCurrency(bd, code))/\(formatCurrency(ld, code))"
            }
            return formatCurrency(bd, code)
        case .subscription(let tierName, _):
            return tierName
        }
    }

    private func formatCurrency(_ val: Double, _ code: String) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = code
        return fmt.string(from: NSNumber(value: val)) ?? "\(val)"
    }

    private var resetText: String {
        ResetCountdownBadge.format(snapshot.resetsAt)
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicatorDot(status: snapshot.status)
                .frame(width: 8)

            Text(snapshot.displayName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            MicroProgressBar(fraction: snapshot.consumptionFraction, statusColor: progressColor)
                .frame(width: 80)

            Text(fractionLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(progressColor)
                .frame(width: 60, alignment: .trailing)

            Text(resetText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
    }
}
