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
                    .fill(healthColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: healthColor.opacity(0.6), radius: 2)

                if let oldest = summary.oldestReading {
                    Text(elapsed(oldest))
                        .font(Theme.Typography.footerMeta)
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.80))
                        .help("Oldest reading in view")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("FrugalBar health status")

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

    private var healthColor: Color {
        guard summary.hasAnyReading else { return Theme.outline }
        switch summary.worstUrgency {
        case .none:     return Theme.secondary
        case .warning:  return Theme.tertiary
        case .critical: return Theme.error
        }
    }

    private func elapsed(_ date: Date) -> String {
        let interval = max(0, -date.timeIntervalSinceNow)
        if interval < 60 { return "\(Int(interval.rounded()))s" }
        if interval < 3600 { return "\(Int((interval / 60).rounded()))m" }
        return "\(Int((interval / 3600).rounded()))h"
    }
}



