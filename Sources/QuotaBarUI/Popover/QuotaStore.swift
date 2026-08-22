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
    public private(set) var advice: QuotaAdvice = QuotaAdvice.evaluate(from: [])
    public private(set) var isRefreshing = false

    /// Called on the main actor whenever `summary` changes.
    ///
    /// A plain callback rather than observation plumbing: there is exactly one
    /// owner (the AppDelegate, which redraws the status item), and it is set
    /// once at construction. This is not the shared-mutable-callback pattern
    /// that previously let the popover clobber the menu bar's refresh handler.
    public var onSummaryChange: (@MainActor (SystemHealthSummary) -> Void)?

    private let manager: QuotaManager

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
        self.advice = QuotaAdvice.evaluate(from: snaps)
        onSummaryChange?(self.summary)
    }

}


