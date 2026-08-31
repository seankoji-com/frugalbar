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
public struct PopoverRootView: View {

    @State private var store: QuotaStore
    @State private var selectedSnapshot: QuotaSnapshot? = nil
    private let onOpenSettings: (@MainActor () -> Void)?

    /// Wide enough for the row budget in `MetricRowView` (324pt of content).
    public static let popoverWidth: CGFloat = Theme.popoverWidth
    public static let popoverHeight: CGFloat = 640
    /// Only engaged when content genuinely cannot fit, e.g. accessibility sizes.
    /// Raised from 580 with the comfortable row height: a full set of providers
    /// plus the suggestion card lands near 670pt, which still clears the usable
    /// height below the menu bar on a 13" display.
    public static let maxContentHeight: CGFloat = 760

    public init(
        store: QuotaStore = QuotaStore(),
        onOpenSettings: (@MainActor () -> Void)? = nil
    ) {
        _store = State(initialValue: store)
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // `fixedSize` first so the scroll view adopts its content's
                // height, then the frame clamps it: the popover is exactly as
                // tall as it needs to be until it hits the ceiling, and scrolls
                // from there instead of growing off the screen.
                ScrollView(.vertical) {
                    sections
                        .frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: Self.maxContentHeight)
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
                    onRefresh: { Task { await store.forceRefresh() } }
                )
            }
            .frame(width: Self.popoverWidth)
            .background(Theme.surface)




            if let snap = selectedSnapshot {
                MetricDetailModalView(
                    snapshot: snap,
                    onClose: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selectedSnapshot = nil
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedSnapshot != nil)
        .task {
            // Background polling is subscribed once by the app delegate, which
            // owns the store. Registering here too ran every tick twice.
            await store.load()
        }
    }

    /// Launches the recommended agent, when the advice names a vendor that has
    /// one. Advice about GitHub API limits names no tool to open, so the card
    /// renders without a button rather than with a dead one.
    private var adviceAction: (() -> Void)? {
        guard let vendorId = store.advice.vendorId,
              CLILauncher.command(for: vendorId) != nil
        else { return nil }
        return { Task { @MainActor in CLILauncher.launch(for: vendorId) } }
    }

    private var sections: some View {
        VStack(spacing: Theme.sectionGap) {
            // The recommendation leads. It is the one thing in the popover that
            // answers the question the user opened it to ask; underneath five
            // provider cards it was the last thing they reached.
            if !store.snapshots.isEmpty {
                AdviceSectionView(advice: store.advice, onActionTap: adviceAction)
            }

            ForEach(MetricCategory.allCases, id: \.self) { category in
                let items = store.snapshots.filter {
                    if category == .developerLimits {
                        return $0.vendorId == .githubRest
                    } else {
                        return $0.category == category
                    }
                }

                // Suppress developerLimits UNLESS at least one limit is in danger of being exceeded (>= 70% or warning/critical)
                let shouldShowSection: Bool = {
                    guard !items.isEmpty else { return false }
                    if category == .developerLimits {
                        return items.contains { snap in
                            if snap.status.urgency >= .warning { return true }
                            // A limit we could not read is not an elevated one.
                            // Coercing its missing fraction to 0 happened to be
                            // right here, but it is the same `?? 0.0` that read
                            // as "plenty left" elsewhere — so it is spelled out.
                            let measured = snap.quotaBars.compactMap(\.primaryFraction)
                                + [snap.consumptionFraction].compactMap { $0 }
                            return measured.contains { $0 >= 0.70 }
                        }
                    }
                    return true
                }()

                if shouldShowSection {
                    MetricSectionView(
                        category: category,
                        snapshots: items,
                        onSelect: { snap in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                selectedSnapshot = snap
                            }
                        }
                    )
                }
            }



            if store.snapshots.isEmpty {
                Text("Loading…")
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.outline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            }
        }
        .padding(.horizontal, Theme.edgeMargin)
        .padding(.top, Theme.edgeMargin)
        .padding(.bottom, Theme.edgeMargin)
        .background(Theme.surface)
    }
}



