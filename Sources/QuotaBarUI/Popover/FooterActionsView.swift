import SwiftUI
import AppKit
import QuotaBarCore

/// Clean macOS bottom toolbar with branding, aggregate health, refresh button and gear menu.
struct FooterActionsView: View {
    let summary: SystemHealthSummary
    let isRefreshing: Bool
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    let onRefresh: () -> Void

    @State private var isGearHovered = false
    @State private var isRefreshHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // FrugalBar Branding + Live status dot
            HStack(spacing: 6) {
                Text("FrugalBar")
                    .font(Theme.Typography.footer)
                    .foregroundStyle(Theme.onSurface)

                Circle()
                    .fill(HeaderSummaryView.healthColor(for: summary))
                    .frame(width: 7, height: 7)
                    .shadow(color: HeaderSummaryView.healthColor(for: summary).opacity(0.6), radius: 2)

                if let oldest = summary.oldestReading {
                    Text(HeaderSummaryView.elapsed(since: oldest))
                        .font(Theme.Typography.footerMeta)
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.80))
                        .help("Oldest reading in view")
                }
            }
            .accessibilityElement(children: .combine)
            // The dot carries the health state in colour alone, so the label
            // has to say it — a static "FrugalBar health status" combines the
            // children and then throws the status away, leaving VoiceOver with
            // a category name and no reading. Same wording as the header's own
            // label so the two announce consistently.
            .accessibilityLabel(footerAccessibilityLabel)

            Spacer()

            // Manual Refresh Button
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isRefreshHovered ? Theme.onSurface : Theme.onSurfaceVariant.opacity(0.85))
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: isRefreshing
                    )
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .onHover { isRefreshHovered = $0 }
            .accessibilityLabel(isRefreshing ? "Refreshing" : "Refresh now")

            // Standard macOS Gear Menu
            Menu {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings…", systemImage: "slider.horizontal.3")
                }
                .keyboardShortcut(",", modifiers: .command)

                Button {
                    onRefresh()
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    // Not the standard panel: it reads Bundle.main, which is
                    // empty for the bare executable a release ships.
                    AboutWindow.show()
                } label: {
                    Label("About FrugalBar", systemImage: "info.circle")
                }

                Divider()

                Button(role: .destructive) {
                    onQuit()
                } label: {
                    Label("Quit FrugalBar", systemImage: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(isGearHovered ? Theme.onSurface : Theme.onSurfaceVariant.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }

            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isGearHovered = $0 }
        }
        .padding(.horizontal, Theme.edgeMargin + 4)
        .frame(height: 44)
        .background(Theme.card)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.outlineVariant.opacity(0.30))
                .frame(height: 0.5)
        }
    }

    /// Spoken form of the branding group: the health text the dot only shows
    /// in colour, plus the age of the oldest reading when there is one.
    ///
    /// Derived from `HeaderSummaryView`'s statics rather than a second copy of
    /// the mapping — the footer dot and the header dot must never be able to
    /// disagree about what a given summary means.
    private var footerAccessibilityLabel: String {
        var label = "FrugalBar. \(HeaderSummaryView.healthText(for: summary))"
        if let oldest = summary.oldestReading {
            label += ". Oldest reading \(HeaderSummaryView.elapsed(since: oldest)) ago"
        }
        return label
    }
}


