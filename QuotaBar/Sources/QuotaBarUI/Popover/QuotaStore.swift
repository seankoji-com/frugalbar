import Foundation
import Observation
import QuotaBarCore

/// Observable view state for the popover and the menu bar.
///
/// Exists so that neither surface has to rebuild the other. The previous
/// revision rebuilt the popover's `NSHostingController` on every refresh —
/// destroying view state, re-triggering `onAppear`, and so kicking off another
/// refresh in a loop — and had two components racing to own a single
/// `BackgroundScheduler.onRefresh` closure.
@MainActor
@Observable
public final class QuotaStore {

    public private(set) var snapshots: [QuotaSnapshot] = []
    public private(set) var summary: SystemHealthSummary = .compute(from: [])
    public private(set) var isRefreshing = false

    private let manager: QuotaManager
    private var schedulerToken: UUID?

    public init(manager: QuotaManager = .shared) {
        self.manager = manager
    }

    /// Loads from cache when fresh, otherwise fetches.
    public func load() async {
        await run { await self.manager.refresh() }
    }

    /// Explicit user action — bypasses the cache.
    public func forceRefresh() async {
        await run { await self.manager.forceRefresh() }
    }

    private func run(_ fetch: @escaping @Sendable () async -> [VendorIdentifier: QuotaSnapshot]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await fetch()
        await reloadFromCache()
    }

    private func reloadFromCache() async {
        let snaps = await manager.sortedSnapshots()
        self.snapshots = snaps
        self.summary = SystemHealthSummary.compute(from: snaps)
    }

    /// Subscribes to background polls. Uses the scheduler's additive handler
    /// registry, so this cannot displace another component's handler.
    public func startObservingBackgroundRefresh() async {
        guard schedulerToken == nil else { return }
        schedulerToken = await BackgroundScheduler.shared.addHandler { [weak self] in
            guard let self else { return }
            await self.load()
        }
    }

    public func stopObservingBackgroundRefresh() async {
        guard let token = schedulerToken else { return }
        await BackgroundScheduler.shared.removeHandler(token)
        schedulerToken = nil
    }
}
