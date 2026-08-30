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

        let task = Task { await self.parallelFetch(force: force) }
        activeTask = task
        let result = await task.value
        // Only clear if this task is still the current one — a forceRefresh
        // may have installed a newer task while we were suspended.
        if activeTask == task { activeTask = nil }
        return result
    }

    private func parallelFetch(force: Bool = false) async -> [VendorIdentifier: QuotaSnapshot] {
        let providers: [any QuotaProvider] = providerFactory()
        let budget = cachePolicy.perProviderTimeout
        let minPollInterval = cachePolicy.minPollInterval
        let startNow = Date()

        // Per-vendor poll floor: a vendor fetched more recently than
        // minPollInterval is served its cached snapshot instead of being
        // re-hit. This applies even on the forceRefresh path (force only
        // bypasses cacheTTL/lastCompleteFetch, not this per-vendor floor),
        // so mashing the manual refresh button can't hammer a paid
        // provider's API faster than the floor allows.
        var providersToFetch: [any QuotaProvider] = []
        var throttledOnForce: [VendorIdentifier] = []
        for provider in providers {
            let shouldThrottle: Bool
            if let entry = cache[provider.vendorId] {
                let withinFloor = startNow.timeIntervalSince(entry.fetchedAt) < minPollInterval
                switch entry.snapshot.status {
                case .unavailable(.notConfigured), .unavailable(.credentialRejected):
                    // These two are the only reasons a Settings change can
                    // fix instantly — a just-saved or just-corrected API key
                    // must take effect on the very next forceRefresh(), so
                    // they never sit under the floor.
                    shouldThrottle = false
                case .measured, .unavailable:
                    // Every other outcome — a real reading, or a vendor-side
                    // signal like rateLimited/offline/timedOut/badResponse —
                    // is exactly what the floor exists to protect: mashing
                    // refresh must not re-hit a throttling or ailing vendor
                    // every cycle just because its last result wasn't a
                    // successful measurement.
                    shouldThrottle = withinFloor
                }
            } else {
                shouldThrottle = false
            }
            if shouldThrottle {
                if force { throttledOnForce.append(provider.vendorId) }
            } else {
                providersToFetch.append(provider)
            }
        }
        // A forced refresh that ends up issuing no network request at all
        // looks, to the caller, exactly like a plain cache read — so this is
        // logged rather than left silent, unlike the throttled-but-not-forced
        // case, which is the poll floor working as designed.
        if force, !throttledOnForce.isEmpty {
            NSLog("frugalbar: forceRefresh() served \(throttledOnForce.count) vendor(s) from cache " +
                  "(within minPollInterval=\(minPollInterval)s): \(throttledOnForce.map(\.rawValue))")
        }
        var results: [VendorIdentifier: QuotaSnapshot] = [:]

        await withTaskGroup(of: (VendorIdentifier, QuotaSnapshot).self) { group in
            for provider in providersToFetch {
                group.addTask {
                    // A whole-provider deadline. URLSession's per-request timeout
                    // does not bound a provider that issues several requests.
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    let outcome = await withDeadline(seconds: budget) {
                        try await provider.fetchSnapshot()
                    }
                    switch outcome {
                    case .success(var snapshot):
                        // Measured here rather than guessed in each provider:
                        // one real number for every vendor, including the ones
                        // that issue several requests per refresh.
                        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                        snapshot.latencyMs = Int(elapsed / 1_000_000)
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
        for provider in providersToFetch {
            let id = provider.vendorId
            guard let snap = results[id] else { continue }
            // Keep the old cache entry's snapshot if a previously successful
            // provider now fails transiently, so we don't wipe out the
            // measured reading the UI is showing. But always bump fetchedAt
            // to `now` for a vendor we actually attempted — throttled
            // vendors (never fetched this round) keep their original
            // timestamp, since it's the attempt, not the outcome, that
            // re-arms the floor. Doing this only on `.measured` used to
            // leave `fetchedAt` frozen at the last success for the entire
            // duration of an outage, so every subsequent forceRefresh
            // re-hit the failing vendor once the floor's window (measured
            // from that stale timestamp) had elapsed.
            let displaySnapshot = (snap.status.confidence == .measured || cache[id] == nil)
                ? snap
                : cache[id]!.snapshot
            cache[id] = CacheEntry(snapshot: displaySnapshot, fetchedAt: now)
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
