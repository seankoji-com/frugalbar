import SwiftUI
import QuotaBarCore

/// Header bar: app name, aggregate health, staleness, manual refresh.
///
/// Health and readability are reported separately. "2 not readable" is not the
/// same claim as "2 critical", and collapsing them is what let a stale token
/// mask an exhausted quota in the previous revision.
struct HeaderSummaryView: View {

    let summary: SystemHealthSummary
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("QuotaBar")
                .font(.caption)
                .fontWeight(.semibold)

            Spacer(minLength: 4)

            Label {
                Text(healthText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } icon: {
                Image(systemName: healthSymbol)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .imageScale(.small)
                    .foregroundStyle(healthColor)
            }
            .labelStyle(.titleAndIcon)

            if let oldest = summary.oldestReading {
                Text(elapsed(oldest))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help("Oldest reading in view")
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityLabel(isRefreshing ? "Refreshing" : "Refresh now")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("QuotaBar. \(healthText)")
    }

    // MARK: - Aggregate presentation

    private var healthSymbol: String {
        guard summary.hasAnyReading else { return "minus.circle" }
        switch summary.worstUrgency {
        case .none:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private var healthColor: Color {
        guard summary.hasAnyReading else { return .secondary }
        switch summary.worstUrgency {
        case .none:     return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private var healthText: String {
        var parts: [String] = []
        if summary.hasAnyReading {
            switch summary.worstUrgency {
            case .none:     parts.append("All quotas healthy")
            case .warning:  parts.append("\(summary.warningCount) running low")
            case .critical: parts.append("\(summary.criticalCount) critical")
            }
        } else {
            parts.append("No readings")
        }
        if summary.unavailableCount > 0 {
            parts.append("\(summary.unavailableCount) not readable")
        }
        return parts.joined(separator: " · ")
    }

    private func elapsed(_ date: Date) -> String {
        let interval = max(0, -date.timeIntervalSinceNow)
        if interval < 60 { return "\(Int(interval.rounded()))s" }
        if interval < 3600 { return "\(Int((interval / 60).rounded()))m" }
        return "\(Int((interval / 3600).rounded()))h"
    }
}
