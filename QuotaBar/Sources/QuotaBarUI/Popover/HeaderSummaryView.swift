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

    @State private var isRefreshHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text("FrugalBar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.onSurface)

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: healthColor.opacity(0.5), radius: 2, x: 0, y: 0)

                Text(healthText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(healthColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let oldest = summary.oldestReading {
                Text(elapsed(oldest))
                    .font(.system(size: 9, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                    .help("Oldest reading in view")
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isRefreshHovered ? Theme.onSurface : Theme.onSurfaceVariant)
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .onHover { isRefreshHovered = $0 }
            .accessibilityLabel(isRefreshing ? "Refreshing" : "Refresh now")
        }
        .padding(.horizontal, Theme.edgeMargin)
        .frame(height: 32)
        .background(Theme.surfaceContainerLow)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.outlineVariant.opacity(0.6))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("FrugalBar. \(healthText)")

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
        guard summary.hasAnyReading else { return Theme.outline }
        switch summary.worstUrgency {
        case .none:     return Theme.secondary
        case .warning:  return Theme.tertiary
        case .critical: return Theme.error
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

