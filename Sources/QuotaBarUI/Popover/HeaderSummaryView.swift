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
                // A shape, not colour alone, carries the status (WCAG 1.4.1):
                // a checkmark, a triangle, or an octagon reads the same
                // whether or not colour vision distinguishes green from red.
                Image(systemName: SystemHealthPresentation.symbol(for: summary))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(SystemHealthPresentation.color(for: summary))
                    .shadow(color: SystemHealthPresentation.color(for: summary).opacity(0.5), radius: 2, x: 0, y: 0)

                Text(SystemHealthPresentation.text(for: summary))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(SystemHealthPresentation.color(for: summary))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let oldest = summary.oldestReading {
                Text(SystemHealthPresentation.elapsed(since: oldest))
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
        .accessibilityLabel("FrugalBar. \(SystemHealthPresentation.text(for: summary))")

    }
}
