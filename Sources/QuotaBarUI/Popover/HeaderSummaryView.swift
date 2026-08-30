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
                    .fill(Self.healthColor(for: summary))
                    .frame(width: 6, height: 6)
                    .shadow(color: Self.healthColor(for: summary).opacity(0.5), radius: 2, x: 0, y: 0)

                Text(Self.healthText(for: summary))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Self.healthColor(for: summary))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let oldest = summary.oldestReading {
                Text(Self.elapsed(since: oldest))
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
        .accessibilityLabel("FrugalBar. \(Self.healthText(for: summary))")

    }

    // MARK: - Aggregate presentation

    static func healthSymbol(for summary: SystemHealthSummary) -> String {
        guard summary.hasAnyReading else { return "minus.circle" }
        switch summary.worstUrgency {
        case .none:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    static func healthColor(for summary: SystemHealthSummary) -> Color {
        guard summary.hasAnyReading else { return Theme.outline }
        switch summary.worstUrgency {
        case .none:     return Theme.secondary
        case .warning:  return Theme.tertiary
        case .critical: return Theme.error
        }
    }

    static func healthText(for summary: SystemHealthSummary) -> String {
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

    /// `now` is a parameter, not a captured `Date()`, so a test can assert an
    /// exact boundary ("59s", not "60s") instead of racing the clock between
    /// building the input date and reading it back.
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "\(Int(interval.rounded()))s" }
        if interval < 3600 { return "\(Int((interval / 60).rounded()))m" }
        return "\(Int((interval / 3600).rounded()))h"
    }
}
