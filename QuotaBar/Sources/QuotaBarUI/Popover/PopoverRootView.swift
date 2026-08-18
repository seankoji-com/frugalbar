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
    private let onOpenSettings: (@MainActor () -> Void)?

    /// Wide enough for the row budget in `MetricRowView` (324pt of content).
    static let popoverWidth: CGFloat = 340
    /// Only engaged when content genuinely cannot fit, e.g. accessibility sizes.
    static let maxContentHeight: CGFloat = 520

    public init(
        store: QuotaStore = QuotaStore(),
        onOpenSettings: (@MainActor () -> Void)? = nil
    ) {
        _store = State(initialValue: store)
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            HeaderSummaryView(
                summary: store.summary,
                isRefreshing: store.isRefreshing,
                onRefresh: { Task { await store.forceRefresh() } }
            )

            Divider()

            ViewThatFits(in: .vertical) {
                sections
                ScrollView { sections }
            }
            .frame(maxHeight: Self.maxContentHeight)

            Divider()

            FooterActionsView(
                onOpenSettings: {
                    if let onOpenSettings {
                        onOpenSettings()
                    } else {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                },
                onQuit: { NSApp.terminate(nil) }
            )
        }
        .frame(width: Self.popoverWidth)
        .task {
            // Background polling is subscribed once by the app delegate, which
            // owns the store. Registering here too ran every tick twice.
            await store.load()
        }
    }

    private var sections: some View {
        VStack(spacing: 0) {
            ForEach(MetricCategory.allCases, id: \.self) { category in
                let items = store.snapshots.filter { $0.category == category }
                if !items.isEmpty {
                    MetricSectionView(category: category, snapshots: items)
                    if category != MetricCategory.allCases.last {
                        Divider().padding(.vertical, 2)
                    }
                }
            }
            if store.snapshots.isEmpty {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
    }
}
