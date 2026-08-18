import SwiftUI
import QuotaBarCore

/// Header bar: app name, overall health, last-updated timestamp, manual refresh button.
struct HeaderSummaryView: View {
    let summary: SystemHealthSummary
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("QuotaBar")
                .font(.system(size: 12, weight: .semibold))

            Spacer()

            // Overall health indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(overallColor)
                    .frame(width: 6, height: 6)

                Text(overallText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }

            // Last updated
            if let last = summary.lastUpdated {
                Text(formattedElapsed(last))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Refresh button
            Button(action: onRefresh) {
                Image(systemName: isRefreshing ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }

    private var overallColor: Color {
        switch summary.overallStatus {
        case .healthy: .green
        case .warning: .orange
        case .critical, .rateLimited: .red
        case .unauthenticated, .networkError: .gray
        case .unsupported: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var overallText: String {
        if summary.errorCount > 0 { return "\(summary.errorCount) errors" }
        switch summary.overallStatus {
        case .healthy: return "All systems normal"
        case .warning: return "\(summary.warningCount) warnings"
        case .critical: return "\(summary.criticalCount) critical"
        case .rateLimited: return "Rate limited"
        case .unauthenticated, .networkError: return "Errors"
        case .unsupported: return "Unsupported"
        }
    }

    private func formattedElapsed(_ date: Date) -> String {
        let interval = abs(date.timeIntervalSinceNow)
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        return "\(Int(interval / 3600))h"
    }
}
