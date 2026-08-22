import Foundation

// MARK: - QuotaManager actor

/// Actor-isolated orchestrator that manages all provider adapters, parallel fetch,
/// cache, and state distribution to the UI.
public actor QuotaManager {

    public static let shared = QuotaManager()

    // --- State ---
    private var cache: [VendorIdentifier: CacheEntry] = [:]
    private var lastCompleteFetch: Date?
    private let cachePolicy: CachePolicy
    private let providerFactory: @Sendable () -> [any QuotaProvider]
    private var activeTask: Task<[VendorIdentifier: QuotaSnapshot], Never>?

    private struct CacheEntry: Sendable {
        let snapshot: QuotaSnapshot
        let fetchedAt: Date
    }

    /// Designated initialiser. `providerFactory` is injectable so tests can
    /// drive the engine with stubs instead of reaching the network.
    public init(
        cachePolicy: CachePolicy = .default,
        providerFactory: @escaping @Sendable () -> [any QuotaProvider] = QuotaManager.defaultProviders
    ) {
        self.cachePolicy = cachePolicy
        self.providerFactory = providerFactory
    }

    public static let defaultProviders: @Sendable () -> [any QuotaProvider] = {
        [
            ClaudeQuotaProvider(),
            OpenAIQuotaProvider(),
            GeminiQuotaProvider(),
            GitHubCopilotProvider(),
            OpenCodeGoProvider(),
            OpenRouterProvider(),
            GitHubRestProvider(),
            GitHubGraphQLProvider(),
        ]
    }

    // MARK: Public accessors

    /// Returns cached snapshots immediately (fast path for UI).
    public func cachedSnapshots() -> [VendorIdentifier: QuotaSnapshot] {
        cache.mapValues(\.snapshot)
    }

    /// Returns all snapshots sorted by the canonical provider order.
    public func sortedSnapshots() -> [QuotaSnapshot] {
        let order: [VendorIdentifier] = [
            .claude, .openai, .gemini, .copilot, .opencode,
            .openrouter,
            .githubRest, .githubGraphql,
        ]
        let dict = cache.mapValues(\.snapshot)
        return order.compactMap { dict[$0] }
    }




    /// Returns true if cache is still fresh.
    public func isCacheFresh() -> Bool {
        guard let last = lastCompleteFetch else { return false }
        return Date().timeIntervalSince(last) < cachePolicy.cacheTTL
    }

    /// Worst quota pressure across providers we could actually read.
    /// Providers we could not read contribute `.none` — they are reported
    /// separately via `SystemHealthSummary.unavailableCount`.
    public func worstUrgency() -> Urgency {
        cache.values.map(\.snapshot.status.urgency).max() ?? .none
    }

    // MARK: Fetch (with concurrency + dedup)

    /// Returns cached data when it is still fresh, otherwise fetches.
    /// Concurrent callers share a single in-flight fetch.
    public func refresh() async -> [VendorIdentifier: QuotaSnapshot] {
        if isCacheFresh() {
            return cachedSnapshots()
        }
        return await fetchDeduplicated()
    }

    /// Bypasses the cache entirely. Used by the manual refresh button.
    public func forceRefresh() async -> [VendorIdentifier: QuotaSnapshot] {
        lastCompleteFetch = nil
        return await fetchDeduplicated(force: true)
    }

    // MARK: Private

    private func fetchDeduplicated(force: Bool = false) async -> [VendorIdentifier: QuotaSnapshot] {
        if force {
            activeTask?.cancel()
            activeTask = nil
        }

        // Join an in-flight fetch rather than starting a second one.
        if let existing = activeTask {
            return await existing.value
        }

        let task = Task { await self.parallelFetch() }
        activeTask = task
        let result = await task.value
        // Only clear if this task is still the current one — a forceRefresh
        // may have installed a newer task while we were suspended.
        if activeTask == task { activeTask = nil }
        return result
    }

    private func parallelFetch() async -> [VendorIdentifier: QuotaSnapshot] {
        let providers: [any QuotaProvider] = providerFactory()
        let budget = cachePolicy.perProviderTimeout
        var results: [VendorIdentifier: QuotaSnapshot] = [:]

        await withTaskGroup(of: (VendorIdentifier, QuotaSnapshot).self) { group in
            for provider in providers {
                group.addTask {
                    // A whole-provider deadline. URLSession's per-request timeout
                    // does not bound a provider that issues several requests.
                    let outcome = await withDeadline(seconds: budget) {
                        try await provider.fetchSnapshot()
                    }
                    switch outcome {
                    case .success(let snapshot):
                        return (provider.vendorId, snapshot)
                    case .failure(let reason):
                        return (provider.vendorId, Self.unavailableSnapshot(for: provider, reason: reason))
                    }
                }
            }
            for await (vendorId, snapshot) in group {
                results[vendorId] = snapshot
            }
        }

        let now = Date()
        for (id, snap) in results {
            // Keep the old cache entry if a previously successful provider now fails transiently
            // so we don't wipe out the measured reading.
            if snap.status.confidence == .measured || cache[id] == nil {
                cache[id] = CacheEntry(snapshot: snap, fetchedAt: now)
            }
        }
        lastCompleteFetch = now
        return cache.mapValues(\.snapshot)
    }

    /// Builds the placeholder shown when a provider could not be read.
    /// Deliberately carries no metric: there is no number to draw.
    static func unavailableSnapshot(
        for provider: any QuotaProvider,
        reason: UnavailableReason
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .subscription(tierName: reason.headline, renewalDate: nil),
            status: .unavailable(reason),
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: reason.remedy
        )
    }
}

// MARK: - System health summary

public struct SystemHealthSummary: Sendable {
    /// Worst quota pressure across providers we could actually read.
    /// This drives the menu bar icon. Unreadable providers never inflate it.
    public let worstUrgency: Urgency
    /// How many providers we could not read. Surfaced as a decoration on the
    /// icon, not as a replacement for it.
    public let unavailableCount: Int
    public let healthyCount: Int
    public let warningCount: Int
    public let criticalCount: Int
    /// Oldest reading in the set — the honest "data as of" timestamp.
    public let oldestReading: Date?
    public let totalProviders: Int

    /// True when at least one provider was read successfully.
    public var hasAnyReading: Bool { totalProviders > unavailableCount }

    public static func compute(from snapshots: [QuotaSnapshot]) -> SystemHealthSummary {
        var healthy = 0, warning = 0, critical = 0, unavailable = 0
        var worst: Urgency = .none
        var oldest: Date?

        for snap in snapshots {
            switch snap.status.confidence {
            case .unavailable:
                unavailable += 1
            case .measured:
                switch snap.status.urgency {
                case .none:     healthy += 1
                case .warning:  warning += 1
                case .critical: critical += 1
                }
                worst = max(worst, snap.status.urgency)
            }
            // Staleness is defined by the *oldest* successful reading. The
            // newest hides a provider that stopped updating an hour ago, and
            // unavailable placeholders are stamped "now", which would reset
            // the badge to 0s at the moment data stopped arriving.
            if snap.status.confidence == .measured,
               oldest.map({ snap.lastUpdated < $0 }) ?? true {
                oldest = snap.lastUpdated
            }
        }

        return SystemHealthSummary(
            worstUrgency: worst,
            unavailableCount: unavailable,
            healthyCount: healthy,
            warningCount: warning,
            criticalCount: critical,
            oldestReading: oldest,
            totalProviders: snapshots.count
        )
    }
}
