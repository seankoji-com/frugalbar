import SwiftUI
import AppKit
import QuotaBarCore

/// Popover contents: header, three category sections, footer.
///
/// The layout is intrinsically sized rather than pinned to a fixed height. The
/// previous revision advertised "zero-scroll" while wrapping the rows in a
/// `ScrollView` with a hardcoded 360pt frame — which scrolls as soon as text
/// scales. Here the popover grows to fit its content, and only falls back to
/// scrolling past a ceiling that large accessibility text sizes can reach.
public struct PopoverRootView: View {

    @State private var store: QuotaStore
    @State private var selectedSnapshot: QuotaSnapshot? = nil
    private let onOpenSettings: (@MainActor () -> Void)?

    /// Wide enough for the row budget in `MetricRowView` (324pt of content).
    public static let popoverWidth: CGFloat = Theme.popoverWidth
    public static let popoverHeight: CGFloat = 480
    /// Only engaged when content genuinely cannot fit, e.g. accessibility sizes.
    public static let maxContentHeight: CGFloat = 580

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
                sections
                    .frame(maxWidth: .infinity)

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
                    },
                    onUpdateUsage: { newUsage in
                        store.updateSnapshotUsage(id: snap.id, fraction: newUsage)
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

    private var sections: some View {
        VStack(spacing: Theme.sectionGap) {
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
                            snap.status.urgency == .warning ||
                            snap.status.urgency == .critical ||
                            (snap.consumptionFraction ?? 0.0) >= 0.70 ||
                            (snap.row1?.primaryFraction ?? 0.0) >= 0.70 ||
                            (snap.row2?.primaryFraction ?? 0.0) >= 0.70
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



            if !store.snapshots.isEmpty {
                AdviceSectionView(advice: store.advice)
            } else {
                Text("Loading…")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.outline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .padding(.horizontal, Theme.edgeMargin)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.surface.opacity(0.3))
    }
}



