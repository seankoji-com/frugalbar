import SwiftUI
import QuotaBarCore

/// Master container: fixed 340×410 (approx), zero scroll, shows all 7 providers.
public struct PopoverRootView: View {
    public init() {}
    @State private var snapshots: [QuotaSnapshot] = []
    @State private var summary: SystemHealthSummary = .compute(from: [])
    @State private var isRefreshing = false
    @State private var showSettings = false
    @State private var errorAlert: String?

    public var body: some View {
        VStack(spacing: 0) {
            HeaderSummaryView(summary: summary, isRefreshing: isRefreshing, onRefresh: manualRefresh)

            Divider()

            ScrollView {  // allows slight overscroll but layout fits all items
                VStack(spacing: 0) {
                    // Section: AI Subscriptions (4 items)
                    MetricSectionView(
                        category: .aiSubscriptions,
                        snapshots: snapshots.filter { $0.category == .aiSubscriptions }
                    )

                    Divider().padding(.vertical, 2)

                    // Section: API Spend & Credits (1 item)
                    MetricSectionView(
                        category: .apiSpendAndCredits,
                        snapshots: snapshots.filter { $0.category == .apiSpendAndCredits }
                    )

                    Divider().padding(.vertical, 2)

                    // Section: Developer Limits (2 items)
                    MetricSectionView(
                        category: .developerLimits,
                        snapshots: snapshots.filter { $0.category == .developerLimits }
                    )
                }
            }
            .frame(height: 360)

            Divider()

            FooterActionsView(onOpenSettings: { showSettings = true }, onQuit: { NSApp.terminate(nil) })
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loadSnapshots()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Error", isPresented: .constant(errorAlert != nil)) {
            Button("OK") { errorAlert = nil }
        } message: {
            Text(errorAlert ?? "")
        }
    }

    private func loadSnapshots() {
        Task {
            isRefreshing = true
            let manager = QuotaManager.shared
            let cacheFresh = await manager.isCacheFresh()
            if !cacheFresh {
                _ = await manager.refresh()
            }
            let snaps = await manager.sortedSnapshots()
            await MainActor.run {
                self.snapshots = snaps
                self.summary = SystemHealthSummary.compute(from: snaps)
                self.isRefreshing = false
                // Start background polling if not already running
                BackgroundScheduler.shared.onRefresh = { [weak manager] in
                    _ = await manager?.refresh()
                }
            }
        }
    }

    private func manualRefresh() {
        Task {
            isRefreshing = true
            let manager = QuotaManager.shared
            _ = await manager.forceRefresh()
            let snaps = await manager.sortedSnapshots()
            await MainActor.run {
                self.snapshots = snaps
                self.summary = SystemHealthSummary.compute(from: snaps)
                self.isRefreshing = false
            }
        }
    }
}
