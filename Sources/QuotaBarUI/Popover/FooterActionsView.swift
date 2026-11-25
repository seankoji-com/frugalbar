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
    /// Recent surfaced events. Events no longer take the popover's top slot;
    /// a labelled pill here opens the list. Nil hides the pill.
    var eventCount: Int? = nil
    /// The latest recent-events read failed (`QuotaStore.recentEventsReadFailed`).
    var eventsReadFailed = false

    /// No events read has completed yet (`QuotaStore.recentEventsLoaded`).
    var eventsNotYetRead = false

    nonisolated static func eventsLabel(count: Int, readFailed: Bool, notYetRead: Bool = false) -> String {
        if readFailed { return "Recent events could not be read. Open the events list" }
        if notYetRead { return "Recent events not read yet. Open the events list" }
        return count == 1 ? "1 recent event. Open the events list" : "\(count) recent events. Open the events list"
    }
    var onOpenEvents: () -> Void = { HistoryWindow.show(tab: .events) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isGearHovered = false
    @State private var isRefreshHovered = false

    /// Pure motion policy for the refresh button so Reduce Motion disables
    /// continuous spin deterministically.
    static func refreshRotationDegrees(isRefreshing: Bool, reduceMotion: Bool) -> Double {
        (isRefreshing && !reduceMotion) ? 360 : 0
    }

    static func refreshAnimation(isRefreshing: Bool, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            footer(now: context.date)
        }
    }

    /// The glyph beside the check time describes the check, not the quotas:
    /// the worst quota's red octagon there read as "the check failed" while
    /// Subscriptions already showed the spent pool. Stale figures are the
    /// check's own failure, and the only one it reports.
    private var checkSymbol: (name: String, color: Color) {
        switch SystemHealthPresentation.checkState(for: summary) {
        case .noReadings: ("minus.circle", Theme.outline)
        case .partial: ("exclamationmark.triangle.fill", Theme.tertiary)
        case .complete: ("checkmark.circle.fill", Theme.secondary)
        }
    }

    private func statusCluster(now: Date, wordmark: Bool, version: Bool) -> some View {
        HStack(spacing: 6) {
            if wordmark {
                Text("FrugalBar")
                    .font(Theme.Typography.footer)
                    .foregroundStyle(Theme.onSurface)
            }

            // The running version, as a token: "v1.4.2", or "dev" for a
            // local build. Muted so the wordmark still leads; the tooltip
            // carries the long form the About window shows.
            if version {
                Text(AppInfo.compactVersion)
                    .font(Theme.Typography.footerMeta)
                    .foregroundStyle(Theme.outline)
                    .help(AppInfo.versionDisplay)
            }

            // A shape, not colour alone, carries the status (WCAG 1.4.1).
            Image(systemName: checkSymbol.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(checkSymbol.color)

            Text(SystemHealthPresentation.pollStatus(
                lastAttemptAt: summary.lastAttemptAt, isRefreshing: isRefreshing, now: now))
                .font(Theme.Typography.footerMeta)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.80))
                .fixedSize()
                .help("Most recent provider check. A failed check keeps the previous figures, marked stale on that provider's row.")

            // A completed check can still leave old figures. Keep that
            // failure visible beside the check time.
            // The check's failures, beside the check time: an offline provider
            // with nothing retained, and figures carried over from an earlier
            // poll. The same words VoiceOver reads.
            if let problems = SystemHealthPresentation.checkProblems(for: summary) {
                Text(problems)
                    .font(Theme.Typography.footerMeta)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize()
                    .help("Not readable: the newest poll returned nothing. Stale: it failed, so the figures are from an earlier one.")
            }
        }
        .fixedSize()
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 8) {
            // FrugalBar Branding + Live status dot
            // The check status never truncates: with a release version, an
            // events pill and a stale count, "Checked 59m ago" had 55pt of the
            // 96pt it needs. The version token goes first, then the wordmark.
            ViewThatFits(in: .horizontal) {
                statusCluster(now: now, wordmark: true, version: true)
                statusCluster(now: now, wordmark: true, version: false)
                statusCluster(now: now, wordmark: false, version: false)
            }
            .accessibilityElement(children: .combine)
            // The dot carries the health state in colour alone, so the label
            // has to say it — a static "FrugalBar health status" combines the
            // children and then throws the status away, leaving VoiceOver with
            // a category name and no reading. Same wording as the header's own
            // label so the two announce consistently.
            .accessibilityLabel(footerAccessibilityLabel(now: now))

            Spacer()

            if let eventCount {
                Button(action: onOpenEvents) {
                    HStack(spacing: 4) {
                        // A failed read wears a warning, not a quiet zero.
                        Image(systemName: eventsReadFailed ? "exclamationmark.triangle.fill" : "bell.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(eventsReadFailed ? Theme.tertiary : (eventCount > 0 ? Theme.primary : Theme.onSurfaceVariant))
                        // "recent", not "new": nothing records which events
                        // have been seen, so "new" would claim a fact we lack.
                        Text(eventCount == 0 || eventsReadFailed ? "Events" : "\(eventCount) recent")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(eventCount > 0 && !eventsReadFailed ? Theme.primary : Theme.onSurfaceVariant)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.primary.opacity(eventCount > 0 ? 0.14 : 0.06)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.eventsLabel(count: eventCount, readFailed: eventsReadFailed,
                                                     notYetRead: eventsNotYetRead))
                .help("Open the events list in the History window")
            }

            // Manual Refresh Button
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isRefreshHovered ? Theme.onSurface : Theme.onSurfaceVariant.opacity(0.85))
                    .rotationEffect(.degrees(Self.refreshRotationDegrees(isRefreshing: isRefreshing, reduceMotion: reduceMotion)))
                    .animation(
                        Self.refreshAnimation(isRefreshing: isRefreshing, reduceMotion: reduceMotion),
                        value: isRefreshing
                    )
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isRefreshHovered ? Theme.rowHover : Color.clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Never disabled: an automatic pass (one runs whenever the popover
            // opens) used to swallow the click meant to recover a reading.
            // `QuotaStore.forceRefresh` joins the running pass or queues one
            // more, so repeated clicks cost at most one extra pass.
            .onHover { isRefreshHovered = $0 }
            .accessibilityLabel(isRefreshing ? "Refreshing; press to refresh again when done" : "Refresh now")
            .help(isRefreshing ? "Checking… a click queues a fresh check" : "Refresh readings (⌘R)")

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
                    HistoryWindow.show()
                } label: {
                    Label("History…", systemImage: "chart.line.uptrend.xyaxis")
                }
                .keyboardShortcut("y", modifiers: .command)

                Toggle(isOn: Binding(
                    get: { DesktopWidgetVisibility.shared.isVisible },
                    set: { _ in DesktopWidgetWindow.toggle() }
                )) {
                    Label("Desktop Widget", systemImage: "rectangle.on.rectangle")
                }
                .keyboardShortcut("d", modifiers: .command)

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
            .accessibilityLabel("FrugalBar menu")
            .help("Settings, history and desktop widget")
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
    /// in colour, plus the most recent provider check.
    ///
    /// Derived from `SystemHealthPresentation` rather than a second copy of
    /// the mapping — the footer dot and the header dot must never be able to
    /// disagree about what a given summary means.
    private func footerAccessibilityLabel(now: Date) -> String {
        // The version token is on screen, so it is spoken too — in the long
        // form, since "vee one point four" is not how anyone says a version.
        "FrugalBar, \(AppInfo.versionDisplay). "
            + SystemHealthPresentation.pollStatus(
                lastAttemptAt: summary.lastAttemptAt, isRefreshing: isRefreshing, now: now)
            + ". \(SystemHealthPresentation.checkSpoken(for: summary))"
    }
}


