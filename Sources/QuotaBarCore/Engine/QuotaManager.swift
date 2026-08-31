import Foundation

// MARK: - QuotaManager actor

/// Actor-isolated orchestrator that manages all provider adapters, parallel fetch,
/// cache, and state distribution to the UI.
public actor QuotaManager {

    public static let shared = QuotaManager(cycleLookup: SubscriptionCycleStore.cycle(for:))

    // --- State ---
    private var cache: [VendorIdentifier: CacheEntry] = [:]
    private var lastCompleteFetch: Date?
    private let cachePolicy: CachePolicy
    private let providerFactory: @Sendable () -> [any QuotaProvider]
    private let cycleLookup: @Sendable (VendorIdentifier) -> SubscriptionCycle?
    private var activeTask: Task<[VendorIdentifier: QuotaSnapshot], Never>?

    private struct CacheEntry: Sendable {
        let snapshot: QuotaSnapshot
        let fetchedAt: Date
    }

    /// Designated initialiser. `providerFactory` is injectable so tests can
    /// drive the engine with stubs instead of reaching the network.
    ///
    /// `cycleLookup` defaults to reporting no cycle for any vendor rather
    /// than to the real `SubscriptionCycleStore` — that store is backed by
    /// process-wide `UserDefaults`, and a test that doesn't ask for it should
    /// never be able to observe (or race against) another test's writes to
    /// it. `.shared`, the app's real instance, opts into the live store
    /// explicitly above.
    public init(
        cachePolicy: CachePolicy = .default,
        providerFactory: @escaping @Sendable () -> [any QuotaProvider] = QuotaManager.defaultProviders,
        cycleLookup: @escaping @Sendable (VendorIdentifier) -> SubscriptionCycle? = { _ in nil }
    ) {
        self.cachePolicy = cachePolicy
        self.providerFactory = providerFactory
        self.cycleLookup = cycleLookup
    }

    public static let defaultProviders: @Sendable () -> [any QuotaProvider] = {
        [
            ClaudeQuotaProvider(),
            OpenAIQuotaProvider(),
            GeminiQuotaProvider(),
            GitHubCopilotProvider(),
            OpenCodeGoProvider(),
            OpenRouterProvider(),
            GrokQuotaProvider(),
            KiroQuotaProvider(),
            DevPassQuotaProvider(),
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
    /// Fallback ordering, used only to break ties and to place vendors that
    /// published no window at all. Not the primary sort — see below.
    static let canonicalOrder: [VendorIdentifier] = [
        .claude, .openai, .gemini, .copilot, .opencode,
        .openrouter, .grok, .kiro, .devpass,
        .githubRest, .githubGraphql,
    ]

    /// Vendors in the order they demand attention: whichever long window
    /// turns over soonest comes first.
    ///
    /// A fixed vendor order put the thing expiring in an hour below the thing
    /// expiring in three weeks. Sorting by each vendor's *longest* window is
    /// what matches how the list gets read — a five-hour bucket refills on its
    /// own, so it is the monthly or weekly deadline that decides whether a
    /// vendor is worth planning around today.
    ///
    /// Three bands, in order:
    ///   1. Has a dated window — earliest reset first.
    ///   2. Published no window — canonical order, so the list stays stable.
    ///   3. Exhausted — last regardless of reset, because a spent vendor is
    ///      not somewhere to send work however soon it refills.
    public func sortedSnapshots() -> [QuotaSnapshot] {
        let rank = Dictionary(
            uniqueKeysWithValues: Self.canonicalOrder.enumerated().map { ($0.element, $0.offset) })
        let snapshots = Self.canonicalOrder.compactMap { cache[$0]?.snapshot }

        return snapshots.sorted { a, b in
            let bandA = Self.sortBand(a), bandB = Self.sortBand(b)
            if bandA != bandB { return bandA < bandB }

            if bandA == 0, let resetA = a.longestWindowReset, let resetB = b.longestWindowReset,
               resetA != resetB
            {
                return resetA < resetB
            }
            return (rank[a.vendorId] ?? .max) < (rank[b.vendorId] ?? .max)
        }
    }

    static func sortBand(_ snapshot: QuotaSnapshot) -> Int {
        if snapshot.isQuotaExhausted { return 2 }
        return snapshot.longestWindowReset == nil ? 1 : 0
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
        let cycleLookup = self.cycleLookup

        await withTaskGroup(of: (VendorIdentifier, QuotaSnapshot).self) { group in
            for provider in providersToFetch {
                group.addTask {
                    // A whole-provider deadline. URLSession's per-request timeout
                    // does not bound a provider that issues several requests.
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    let outcome = await withDeadline(seconds: budget) {
                        try await provider.fetchSnapshot()
                    }
                    let cycle = cycleLookup(provider.vendorId)
                    switch outcome {
                    case .success(var snapshot):
                        // Measured here rather than guessed in each provider:
                        // one real number for every vendor, including the ones
                        // that issue several requests per refresh.
                        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                        snapshot.latencyMs = Int(elapsed / 1_000_000)
                        return (provider.vendorId, Self.attachingCycleRow(to: snapshot, cycle: cycle))
                    case .failure(let reason):
                        let placeholder = Self.unavailableSnapshot(for: provider, reason: reason)
                        return (provider.vendorId, Self.attachingCycleRow(to: placeholder, cycle: cycle))
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
            let displaySnapshot: QuotaSnapshot
            if snap.status.confidence == .measured || cache[id] == nil {
                displaySnapshot = snap
            } else {
                // The retained snapshot's hand-entered cycle row (if any) was
                // computed at the last successful fetch and frozen there — a
                // vendor down for days would otherwise keep showing e.g. "3
                // days left in monthly cycle" for the whole outage, the one
                // figure here that doesn't depend on the provider at all.
                // Re-attach against `now` so it keeps counting down.
                let retained = cache[id]!.snapshot
                displaySnapshot = Self.attachingCycleRow(
                    to: Self.removingStaleCycleRow(from: retained), cycle: cycleLookup(id), now: now)
            }
            cache[id] = CacheEntry(snapshot: displaySnapshot, fetchedAt: now)
        }
        lastCompleteFetch = now
        return cache.mapValues(\.snapshot)
    }

    /// Adds the user's hand-entered renewal countdown, when they recorded one
    /// for this vendor and the snapshot has a free row.
    ///
    /// Done here rather than inside each provider so it applies uniformly —
    /// including to a vendor FrugalBar could not read at all, which is exactly
    /// the case a renewal date is most useful for. It only ever *adds* a row:
    /// a vendor-published window always outranks a date typed by hand, and is
    /// never overwritten by one.
    ///
    /// Takes the cycle as a parameter rather than looking it up itself, so
    /// this stays a pure function of its arguments: callers that don't care
    /// about hand-entered cycles (most tests) never have to touch
    /// `SubscriptionCycleStore`'s process-wide preference store at all.
    static func attachingCycleRow(
        to snapshot: QuotaSnapshot, cycle: SubscriptionCycle?, now: Date = Date()
    ) -> QuotaSnapshot {
        guard let cycle, let row = cycle.cycleRow(now: now)
        else { return snapshot }

        var updated = snapshot
        if updated.row1 == nil { updated.row1 = row }
        else if updated.row2 == nil { updated.row2 = row }
        else if updated.row3 == nil { updated.row3 = row }
        else if let slot = leastInformativeFilledSlot(in: updated) {
            // Three vendor rows, but one of them has neither a reset nor a
            // window length — nothing to plan around, and the case a
            // renewal date is most useful for is exactly a vendor with rows
            // like that (e.g. Kiro's bonus/overage bars). Recording a cycle
            // used to silently no-op here: the Settings editor still showed
            // it as tracked, but it never rendered anywhere.
            switch slot {
            case 1: updated.row1 = row
            case 2: updated.row2 = row
            default: updated.row3 = row
            }
        } else {
            return snapshot  // Three informative vendor windows; theirs win.
        }

        // A vendor that published no reset can still show when the user's own
        // period turns over. `resetsAt` is a `let`, so this has to rebuild
        // the snapshot rather than assign in place — which means every field
        // the initializer doesn't accept (spendWindows, the two catalog
        // badges) has to be copied across explicitly, or it silently reverts
        // to its default on this one path.
        if updated.resetsAt == nil, let renewal = row.resetsAt {
            var rebuilt = QuotaSnapshot(
                id: updated.id,
                vendorId: updated.vendorId,
                displayName: updated.displayName,
                category: updated.category,
                metric: updated.metric,
                status: updated.status,
                resetsAt: renewal,
                lastUpdated: updated.lastUpdated,
                auxiliaryInfo: updated.auxiliaryInfo,
                row1: updated.row1,
                row2: updated.row2,
                row3: updated.row3,
                badgeText: updated.badgeText,
                planName: updated.planName,
                latencyMs: updated.latencyMs,
                keyMasked: updated.keyMasked,
                cliSource: updated.cliSource,
                currencyBasis: updated.currencyBasis
            )
            rebuilt.spendWindows = updated.spendWindows
            rebuilt.freeTierModelBadge = updated.freeTierModelBadge
            rebuilt.cheapestLargeContextModelBadge = updated.cheapestLargeContextModelBadge
            updated = rebuilt
        }
        return updated
    }

    /// The row slot (1, 2, or 3) holding a bar with neither a reset nor a
    /// window length — the one a hand-entered cycle can usefully replace
    /// when all three are already filled. Nil when every row has something
    /// to plan around, so the vendor's own data always wins.
    private static func leastInformativeFilledSlot(in snapshot: QuotaSnapshot) -> Int? {
        func isUninformative(_ bar: DualBarMetrics?) -> Bool {
            guard let bar else { return false }
            return bar.resetsAt == nil && bar.windowLength == nil
        }
        if isUninformative(snapshot.row1) { return 1 }
        if isUninformative(snapshot.row2) { return 2 }
        if isUninformative(snapshot.row3) { return 3 }
        return nil
    }

    /// Strips a previously-attached hand-entered cycle row (and the
    /// snapshot-level `resetsAt` it adopted, if that's where it came from)
    /// so `attachingCycleRow` can be called again on an already-attached
    /// snapshot and actually recompute the row against a new `now`, instead
    /// of hitting the "row slot already occupied" guard and being a no-op.
    static func removingStaleCycleRow(from snapshot: QuotaSnapshot) -> QuotaSnapshot {
        let staleResetsAt = [snapshot.row1, snapshot.row2, snapshot.row3]
            .compactMap { $0 }
            .first { $0.measuresElapsedTimeOnly }?
            .resetsAt

        var updated = snapshot
        if updated.row1?.measuresElapsedTimeOnly == true { updated.row1 = nil }
        if updated.row2?.measuresElapsedTimeOnly == true { updated.row2 = nil }
        if updated.row3?.measuresElapsedTimeOnly == true { updated.row3 = nil }

        guard let staleResetsAt, updated.resetsAt == staleResetsAt else { return updated }

        var rebuilt = QuotaSnapshot(
            id: updated.id,
            vendorId: updated.vendorId,
            displayName: updated.displayName,
            category: updated.category,
            metric: updated.metric,
            status: updated.status,
            resetsAt: nil,
            lastUpdated: updated.lastUpdated,
            auxiliaryInfo: updated.auxiliaryInfo,
            row1: updated.row1,
            row2: updated.row2,
            row3: updated.row3,
            badgeText: updated.badgeText,
            planName: updated.planName,
            latencyMs: updated.latencyMs,
            keyMasked: updated.keyMasked,
            cliSource: updated.cliSource,
            currencyBasis: updated.currencyBasis
        )
        rebuilt.spendWindows = updated.spendWindows
        rebuilt.freeTierModelBadge = updated.freeTierModelBadge
        rebuilt.cheapestLargeContextModelBadge = updated.cheapestLargeContextModelBadge
        return rebuilt
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
