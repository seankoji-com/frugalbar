import SwiftUI
import AppKit
import QuotaBarCore

/// Popover contents: header, three category sections, footer.
///
/// The layout is intrinsically sized rather than pinned to a fixed height, and
/// the popover follows it via `NSHostingController.sizingOptions`. Both halves
/// of that are load-bearing: the height constant alone was advisory, and while
/// `NSPopover.contentSize` stayed pinned to it any extra row was silently
/// clipped — which is exactly what a third OpenRouter spend window did, cutting
/// the card's name off mid-glyph.
///
/// Past `maxContentHeight` the rows scroll rather than grow. That ceiling was
/// declared but never applied for several revisions, so the "falls back to
/// scrolling" this comment used to claim was not true of the code.
/// Which row's inspector is open, shared with the status-item owner.
///
/// NSPopover handles Escape itself, before SwiftUI's `onExitCommand` on the
/// inspector ever sees it, so Escape closed the whole popover and reopening it
/// came back to the inspector — while the inspector's close button advertised
/// Escape as "back to the list". The app delegate reads this from
/// `popoverShouldClose` and turns an Escape into closing the inspector.
@MainActor
@Observable
public final class PopoverInspection {
    public var snapshot: QuotaSnapshot?
    public init() {}

    /// Pure motion policy for inspector open/close transitions so Reduce Motion
    /// is respected consistently across SwiftUI views and AppKit Escape handling.
    public static func openAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.84)
    }

    public static func closeAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    public static func usesScaleTransition(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// Closes the open inspector, if any. Returns whether one was open.
    @discardableResult
    public func dismiss(reduceMotion: Bool? = nil) -> Bool {
        guard snapshot != nil else { return false }
        let reduced = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let anim = Self.closeAnimation(reduceMotion: reduced) {
            withAnimation(anim) { snapshot = nil }
        } else {
            snapshot = nil
        }
        return true
    }
}

public struct PopoverRootView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store: QuotaStore
    @State private var inspection: PopoverInspection
    private var selectedSnapshot: QuotaSnapshot? {
        get { inspection.snapshot }
        nonmutating set { inspection.snapshot = newValue }
    }
    @State private var contentHeight: CGFloat = 0
    @State private var availableHeight: CGFloat
    @State private var footerHeight: CGFloat = 44
    private let availableHeightProvider: @MainActor () -> CGFloat?
    private let onOpenSettings: (@MainActor () -> Void)?

    /// The provider accordion uses 420pt for the account name and three
    /// quota columns. `Theme.popoverWidth` is the inspector's row budget.
    public static let popoverWidth: CGFloat = 420
    public static let popoverHeight: CGFloat = 640
    /// Only engaged when content cannot fit, e.g. accessibility sizes.
    public static let maxContentHeight: CGFloat = 760

    public init(
        store: QuotaStore = QuotaStore(),
        inspection: PopoverInspection = PopoverInspection(),
        onOpenSettings: (@MainActor () -> Void)? = nil,
        availableHeightProvider: @escaping @MainActor () -> CGFloat? = {
            NSScreen.main?.visibleFrame.height
        }
    ) {
        _store = State(initialValue: store)
        _inspection = State(initialValue: inspection)
        _availableHeight = State(initialValue: availableHeightProvider() ?? Self.maxContentHeight + 100)
        self.availableHeightProvider = availableHeightProvider
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                sections
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        contentHeight = $0
                    }
            }
            // Measure the content, not the viewport. Fixing the scroll
            // view at its intrinsic height clipped both ends when capped.
            .frame(idealHeight: scrollHeight, maxHeight: scrollHeight, alignment: .top)
            .scrollBounceBehavior(.basedOnSize)

            FooterActionsView(
                summary: store.summary,
                isRefreshing: store.isRefreshing,
                onOpenSettings: {
                    if let onOpenSettings {
                        onOpenSettings()
                    } else {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                },
                onQuit: { NSApp.terminate(nil) },
                onRefresh: { Task { await store.forceRefresh(allowInteractiveUnlock: true) } },
                eventCount: EventsPresentation.popoverEvents(store.recentEvents).count
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                footerHeight = $0
            }
        }
        .frame(width: Self.popoverWidth)
        .frame(minHeight: Self.minimumHeight(isInspecting: selectedSnapshot != nil, availableHeight: availableHeight))
        .background(Theme.surface)
        .allowsHitTesting(selectedSnapshot == nil)
        .accessibilityHidden(selectedSnapshot != nil)
        .overlay {
            if let snap = selectedSnapshot {
                MetricDetailModalView(
                    snapshot: snap,
                    readingsLoader: store.readings(for:since:),
                    eventsLoader: { v, i, k, s, l in
                        await store.events(for: v, instanceId: i, kinds: k, since: s, limit: l)
                    },
                    balanceLoader: { id, since, until, bucket in
                        await store.balancePoints(seriesId: id, since: since, until: until, bucketSeconds: bucket)
                    },
                    onClose: {
                        if let anim = PopoverInspection.closeAnimation(reduceMotion: reduceMotion) {
                            withAnimation(anim) { selectedSnapshot = nil }
                        } else {
                            selectedSnapshot = nil
                        }
                    }
                )
                .transition(
                    PopoverInspection.usesScaleTransition(reduceMotion: reduceMotion)
                        ? .opacity.combined(with: .scale(scale: 0.98))
                        : .identity
                )
                .zIndex(100)
            }
        }
        .animation(PopoverInspection.closeAnimation(reduceMotion: reduceMotion), value: selectedSnapshot != nil)
        .onAppear(perform: updateAvailableHeight)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            updateAvailableHeight()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            updateAvailableHeight()
        }
        .task {
            // Background polling is subscribed once by the app delegate, which
            // owns the store. Registering here too ran every tick twice.
            await store.load()
        }
    }

    private var scrollHeight: CGFloat {
        // Leave room for the footer and popover chrome below the menu bar.
        Self.scrollHeight(contentHeight: contentHeight, availableHeight: availableHeight, footerHeight: footerHeight)
    }

    /// A short provider list must not squeeze the inspector's chart to a sliver.
    static func minimumHeight(isInspecting: Bool, availableHeight: CGFloat) -> CGFloat {
        isInspecting ? min(popoverHeight, max(0, availableHeight - 12)) : 0
    }

    static func scrollHeight(contentHeight: CGFloat, availableHeight: CGFloat, footerHeight: CGFloat) -> CGFloat {
        let available = availableHeight - footerHeight - 12
        // Never request more than the screen can hold; AppKit positions the
        // footer with the remaining space below this viewport.
        let measured = contentHeight > 0 ? contentHeight : Self.popoverHeight
        return min(measured, Self.maxContentHeight, max(0, available))
    }

    private func updateAvailableHeight() {
        if let height = availableHeightProvider() {
            availableHeight = height
        }
    }

    private var sections: some View {
        let now = Date()
        let order = CredentialStore.providerOrder
        let grid = ProviderGridPresentation(snapshots: store.snapshots, serviceOrder: order, now: now)
        // Every credit and balance, direct balances (OpenRouter, DeepSeek)
        // included, under the provider it belongs to.
        let wallet = WalletPresentation(
            snapshots: GlancePresentation(snapshots: store.snapshots, now: now, serviceOrder: order).walletSnapshots,
            now: now)
        return VStack(spacing: Theme.sectionGap) {
            ProviderGridView(
                presentation: grid,
                onSelect: { snap in
                    if let anim = PopoverInspection.openAnimation(reduceMotion: reduceMotion) {
                        withAnimation(anim) { selectedSnapshot = snap }
                    } else {
                        selectedSnapshot = snap
                    }
                }
            )
            if !wallet.rows.isEmpty {
                WalletSection(presentation: wallet, balanceSeries: store.balanceSeries, now: now) { id in
                    guard let snap = store.snapshots.first(where: { $0.id == id }) else { return }
                    if let anim = PopoverInspection.openAnimation(reduceMotion: reduceMotion) {
                        withAnimation(anim) { selectedSnapshot = snap }
                    } else {
                        selectedSnapshot = snap
                    }
                }
            }

            // Developer limits are not coding pools: they never enter the
            // glance, and appear only while one is in danger of running out.
            let limits = store.snapshots.filter { $0.category == .developerLimits && $0.vendorId == .githubRest }
            if limits.contains(where: { snap in
                if snap.status.urgency >= .warning { return true }
                // A limit we could not read is not an elevated one: no `?? 0`.
                let measured = snap.quotaBars.compactMap(\.primaryFraction)
                    + [snap.consumptionFraction].compactMap { $0 }
                return measured.contains { $0 >= 0.70 }
            }) {
                MetricSectionView(
                    category: .developerLimits,
                    snapshots: limits,
                    forecasts: store.forecasts,
                    balanceSeries: store.balanceSeries,
                    onSelect: { snap in
                        if let anim = PopoverInspection.openAnimation(reduceMotion: reduceMotion) {
                            withAnimation(anim) { selectedSnapshot = snap }
                        } else {
                            selectedSnapshot = snap
                        }
                    }
                )
            }


            if store.snapshots.isEmpty {
                if store.hasLoaded {
                    // Loaded, and nothing came back: only possible when every
                    // provider is hidden, so say how to fix that.
                    GlanceCard {
                        VStack(spacing: 10) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Theme.outline)
                                .accessibilityHidden(true)
                            Text("Nothing to show")
                                .font(Theme.Typography.title)
                                .foregroundStyle(Theme.onSurface)
                            Text("Every provider is hidden. Open Settings → Services to turn monitoring on.")
                                .font(Theme.Typography.subtitle)
                                .foregroundStyle(Theme.onSurfaceVariant)
                                .multilineTextAlignment(.center)
                            Button {
                                if let onOpenSettings {
                                    onOpenSettings()
                                } else {
                                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                                }
                            } label: {
                                Text("Open Preferences")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.onSurface)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Theme.surfaceContainerHigh))
                                    .overlay(Capsule().strokeBorder(Theme.outlineVariant.opacity(0.6), lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 26)
                    }
                } else {
                    GlanceCard {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                                .font(Theme.Typography.subtitle)
                                .foregroundStyle(Theme.outline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.edgeMargin)
        .padding(.top, Theme.edgeMargin)
        .padding(.bottom, Theme.edgeMargin)
        .background(Theme.surface)
    }
}
