import Foundation
import Synchronization

// MARK: - QuotaManager actor

/// Actor-isolated orchestrator that manages all provider adapters, parallel fetch,
/// cache, and state distribution to the UI.
public actor QuotaManager {

    public static let shared = QuotaManager(
        cycleLookup: { vendor in
            // DevPass is a fixed monthly-budget product and reports its own
            // allowance, so the hand-entered renewal cycle — a feature for
            // vendors that publish no billing period — no longer applies to it.
            // Guarding here (rather than in the store) means a cycle recorded
            // before this change is never resurrected as a CYCLE bar, and there
            // is no UI left to clear it from.
            vendor == .devpass ? nil : SubscriptionCycleStore.cycle(for: vendor)
        },
        displayPreferences: { CredentialStore.providerDisplayPreferences },
        geminiCreditLookup: { GeminiAPICreditStore.load() },
        claudeProviderFactory: { await ClaudeAccountDiscovery.shared.providers() },
        antigravityProviderFactory: { await AntigravityAccountDiscovery.shared.providers() },
        monthlyCreditConnection: { await MainActor.run { ClaudeMonthlyCreditSession.shared.connectionGeneration } },
        monthlyCreditIdentities: { await MainActor.run { ClaudeMonthlyCreditSession.shared.webIdentities } })

    // --- State ---
    /// Keyed by each provider's stable `instanceID`, not by vendor: one vendor
    /// can serve several independent subscriptions (OpenCode Go workspaces),
    /// and they must coexist rather than overwrite each other.
    private var cache: [String: CacheEntry] = [:]
    /// The instance ids in the order the providers were last built, so several
    /// instances of one vendor keep the order the user arranged them in.
    private var instanceOrder: [String] = []
    private var lastCompleteFetch: Date?
    private let cachePolicy: CachePolicy
    private let clock: @Sendable () -> Date
    private let providerFactory: @Sendable () -> [any QuotaProvider]
    private let claudeProviderFactory: (@Sendable () async -> [any QuotaProvider])?
    private let antigravityProviderFactory: (@Sendable () async -> [any QuotaProvider])?
    private let cycleLookup: @Sendable (VendorIdentifier) -> SubscriptionCycle?
    private let displayPreferences: @Sendable () -> ProviderDisplayPreferences
    /// The configured Gemini API credit, read on every snapshot read rather
    /// than stored in the cache: it is user-typed data, so a preference change
    /// takes effect without a poll, and a cached reading can never present an
    /// old figure as the current one.
    private let geminiCreditLookup: @Sendable () -> GeminiAPICredit?
    private var activeTask: Task<[String: QuotaSnapshot], Never>?
    private let monthlyCreditConnection: @Sendable () async -> String?
    private let monthlyCreditIdentities: (@Sendable () async -> Set<String>?)?
    private var monthlyCreditInvalidation = 0
    private var openAIMonthlyCreditInvalidation = 0
    private var activeTaskIsForced = false
    private var forcedPassPending = false

    private struct CacheEntry: Sendable {
        let snapshot: QuotaSnapshot
        /// When this provider was last actually fetched, whoever asked for it.
        /// This is what the *automatic* poll floor is measured from.
        let fetchedAt: Date
        /// When this provider was last fetched in response to a user-initiated
        /// refresh (the ⟳ button, or a Preferences change forcing a pass).
        /// `nil` until the first one, and what the *forced* poll floor is
        /// measured from.
        ///
        /// Kept separate from `fetchedAt` because the two answer different
        /// questions. Measuring a forced refresh from `fetchedAt` meant an
        /// automatic fetch — the 2-minute tick, or the load the popover runs
        /// the moment it opens — armed the floor that then swallowed the user's
        /// own click: open the popover, press ⟳ within 30s, and no request was
        /// issued at all, so the reading never moved and the button looked
        /// dead. A poll nobody asked for must not be able to do that.
        let lastUserFetchAt: Date?
        /// The instant the vendor asked us to come back, when its last answer
        /// to this provider was a 429 carrying a `Retry-After`.
        ///
        /// Held here rather than read off `snapshot`, because the snapshot
        /// often does not carry the 429 at all: a provider with a previous
        /// reading keeps showing it, so the reason — and with it the vendor's
        /// backoff instruction — would be dropped on the floor.
        let vendorRetryAfter: Date?
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
        cycleLookup: @escaping @Sendable (VendorIdentifier) -> SubscriptionCycle? = { _ in nil },
        // Same rule as `cycleLookup`: the default shows every provider in
        // canonical order and reads no preference store, so a test sees
        // exactly the providers its factory serves.
        displayPreferences: @escaping @Sendable () -> ProviderDisplayPreferences = { .default },
        // Also like `cycleLookup`: no test should observe (or race against)
        // the process-wide preference store unless it injects one. `.shared`
        // opts into the live store above.
        geminiCreditLookup: @escaping @Sendable () -> GeminiAPICredit? = { nil },
        // Only the live manager opts into account discovery. Test factories
        // retain full control and never read ambient credentials or preferences.
        claudeProviderFactory: (@Sendable () async -> [any QuotaProvider])? = nil,
        antigravityProviderFactory: (@Sendable () async -> [any QuotaProvider])? = nil,
        // Isolated managers use an injected connection lifetime, never the
        // real web session or preference store. The app opts in above.
        monthlyCreditConnection: @escaping @Sendable () async -> String? = { "injected-connection" },
        // The billing session's current attribution, checked at commit. Nil
        // (isolated managers) skips the check; tests that need it inject one.
        monthlyCreditIdentities: (@Sendable () async -> Set<String>?)? = nil,
        // Cache policy time is injectable independently of vendor observations
        // and real elapsed deadlines, so tests never race the scheduler.
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cachePolicy = cachePolicy
        self.clock = clock
        self.providerFactory = providerFactory
        self.claudeProviderFactory = claudeProviderFactory
        self.antigravityProviderFactory = antigravityProviderFactory
        self.cycleLookup = cycleLookup
        self.displayPreferences = displayPreferences
        self.geminiCreditLookup = geminiCreditLookup
        self.monthlyCreditConnection = monthlyCreditConnection
        self.monthlyCreditIdentities = monthlyCreditIdentities
    }

    public static let defaultProviders: @Sendable () -> [any QuotaProvider] = {
        let agyRequests = AntigravityRequestBatch()
        var providers: [any QuotaProvider] = [
            ClaudeQuotaProvider(),
            OpenAIQuotaProvider(),
            GeminiQuotaProvider(allowance: .gemini, requests: agyRequests),
            GeminiQuotaProvider(allowance: .claude, requests: agyRequests),
            GeminiQuotaProvider(allowance: .argon, requests: agyRequests),
            GitHubCopilotProvider(),
        ]
        // One provider per OpenCode Go workspace, so each subscription is
        // polled with its own key and reported as its own reading. Disabled
        // workspaces are not polled at all — like a hidden provider, they cost
        // nothing and their credential stays where it is.
        //
        // `resolved()` reads without writing: the factory runs at the top of
        // every fetch, so a first run must not write a preference here and
        // post a change notification that kicks off a second poll. The list
        // is made durable once at launch instead.
        for workspace in OpenCodeGoWorkspaceStore.resolved() where workspace.isEnabled {
            providers.append(OpenCodeGoProvider(workspace: workspace))
        }
        providers.append(contentsOf: [
            OpenRouterProvider(),
            DeepSeekProvider(),
            GrokQuotaProvider(),
            KiroQuotaProvider(),
            DevPassQuotaProvider(),
            CommandCodeQuotaProvider(),
            ClinePassQuotaProvider(),
            MuseQuotaProvider(),
            OpenDesignQuotaProvider(),
            GitHubRestProvider(),
            GitHubGraphQLProvider(),
        ] as [any QuotaProvider])
        return providers
    }

    // MARK: Public accessors

    /// Disconnect is a local state change, not a reason to poll quota. Also
    /// invalidate results from a pass already awaiting a provider or deadline.
    public func clearMonthlyCredit() {
        monthlyCreditInvalidation += 1
        for id in Array(cache.keys) {
            guard let entry = cache[id] else { continue }
            var snapshot = entry.snapshot
            snapshot.monthlyAPICredit = nil
            cache[id] = CacheEntry(snapshot: snapshot, fetchedAt: entry.fetchedAt,
                lastUserFetchAt: entry.lastUserFetchAt, vendorRetryAfter: entry.vendorRetryAfter)
        }
    }

    /// Drops every cached reading of one vendor. Disconnecting a sign-in-only
    /// provider (OpenDesign) is the user saying "stop showing this": its last
    /// reading must not survive as a retained, stale row. A pass already in
    /// flight is harmless: its provider re-checks the connection and reports
    /// not-configured, which retention cannot cover with figures that are gone.
    public func forgetReadings(of vendor: VendorIdentifier) {
        forgottenVendors[vendor, default: 0] += 1
        for key in Array(cache.keys) where cache[key]?.snapshot.vendorId == vendor { cache[key] = nil }
    }

    /// Bumped by `forgetReadings`. A pass that started before the bump drops
    /// that vendor's result at commit, so a read that completed just before
    /// the disconnect cannot write the forgotten reading back.
    private var forgottenVendors: [VendorIdentifier: Int] = [:]

    /// Disconnecting the OpenAI billing session is a local state change, not a
    /// reason to poll quota. Clear the independently read grant immediately so
    /// it cannot survive a later quota outage through retention.
    public func clearOpenAIMonthlyCredit() {
        openAIMonthlyCreditInvalidation += 1
        for id in Array(cache.keys) {
            guard let entry = cache[id] else { continue }
            var snapshot = entry.snapshot
            snapshot.openAIMonthlyCredit = nil
            snapshot.openAIMonthlyCreditReadAt = nil
            cache[id] = CacheEntry(snapshot: snapshot, fetchedAt: entry.fetchedAt,
                lastUserFetchAt: entry.lastUserFetchAt, vendorRetryAfter: entry.vendorRetryAfter)
        }
    }

    /// Returns cached snapshots immediately (fast path for UI), keyed by each
    /// provider instance's stable id.
    public func cachedSnapshots() -> [String: QuotaSnapshot] {
        visibleCache()
    }

    /// The cache minus hidden vendors. Every read goes through this, so the
    /// fresh-cache fast path cannot return a provider the user just hid.
    private func visibleCache() -> [String: QuotaSnapshot] {
        let hidden = displayPreferences().hidden
        let credit = geminiCreditLookup()
        return cache.filter { !hidden.contains($0.value.snapshot.vendorId) }
            .mapValues { Self.attachingGeminiCredit(to: $0.snapshot, credit: credit) }
    }

    /// Adds the user-configured Gemini API credit to the Gemini row.
    ///
    /// Done on read, not at fetch time or in the cached snapshot: the figure is
    /// typed by the user and measured by no poll, so it must follow the stored
    /// value immediately — including while a vendor is inside the poll floor —
    /// and it must never be recorded or retained as if a fetch had produced it.
    /// Only the Gemini row hosts it: the AI Studio key is a Gemini API surface,
    /// not Argon's or the shared Claude/GPT pool's allowance.
    static func attachingGeminiCredit(
        to snapshot: QuotaSnapshot, credit: GeminiAPICredit?
    ) -> QuotaSnapshot {
        guard let credit, snapshot.vendorId == .gemini else { return snapshot }
        // Only the primary local account (or legacy bare "gemini" id) hosts
        // the user-configured Gemini API credit; secondary accounts and
        // proxy-only outage placeholders never attach it.
        if let account = snapshot.antigravityAccount {
            guard account.isPrimary else { return snapshot }
        } else if snapshot.id != VendorIdentifier.gemini.rawValue {
            return snapshot
        }
        var updated = snapshot
        updated.geminiAPICredit = credit
        return updated
    }

    /// Returns all snapshots sorted by the canonical provider order.
    /// Fallback ordering, used only to break ties and to place vendors that
    /// published no window at all. Not the primary sort — see below.
    static let canonicalOrder: [VendorIdentifier] = [
        .claude, .openai, .gemini, .antigravityClaude, .antigravityArgon, .copilot, .opencode,
        .openrouter, .deepseek, .grok, .kiro, .devpass,
        .commandcode, .clinepass, .muse, .opendesign,
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
        let credit = geminiCreditLookup()
        return Self.arrange(
            cache.values.map { Self.attachingGeminiCredit(to: $0.snapshot, credit: credit) },
            preferences: displayPreferences(),
            instanceOrder: instanceOrder
        )
    }

    /// The display order for a set of snapshots: pure, so it can be tested
    /// without a fetch.
    ///
    /// Several instances of one vendor (OpenCode Go workspaces) always stay
    /// together, in `instanceOrder` — the order the user arranged them in
    /// Preferences, which is the order the providers are built in. The
    /// automatic sort moves the vendor as a block, placed by its most
    /// actionable instance. It used to sort every instance on its own
    /// deadline, so the workspaces were shuffled by whichever monthly window
    /// turned over first and the up/down arrows in Preferences appeared to do
    /// nothing at all.
    ///
    /// A hidden vendor is dropped here as well as purged at fetch time, so
    /// hiding one takes effect on the very next read, before any poll.
    ///
    /// A custom order collects visible nonempty Antigravity pools at their first
    /// member's position, preserving their within-service order. That block drops
    /// last only when every visible pool has a spent or blocked window. Other
    /// vendors keep their relative order, with exhausted vendors moved as blocks.
    static func arrange(
        _ snapshots: [QuotaSnapshot],
        preferences prefs: ProviderDisplayPreferences,
        instanceOrder: [String]
    ) -> [QuotaSnapshot] {
        let rank = Dictionary(
            prefs.order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        var byVendor: [VendorIdentifier: [QuotaSnapshot]] = [:]
        for snapshot in snapshots where !prefs.hidden.contains(snapshot.vendorId) {
            byVendor[snapshot.vendorId, default: []].append(snapshot)
        }
        let position = Dictionary(
            instanceOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        func instanceRank(_ snapshot: QuotaSnapshot) -> Int {
            position[snapshot.id] ?? Int.max
        }
        for vendor in byVendor.keys {
            // The id is a deterministic fallback for an instance the last
            // fetch did not name.
            byVendor[vendor]?.sort {
                let a = instanceRank($0), b = instanceRank($1)
                return a != b ? a < b : $0.id < $1.id
            }
        }
        // Antigravity meters independent pools, but presents one service.
        // Anchor it at the first visible pool in the saved order. Its members
        // keep that order even when their deadlines or exhaustion differ.
        let antigravity: Set<VendorIdentifier> = [.gemini, .antigravityClaude, .antigravityArgon]
        var addedAntigravity = false
        let groups = prefs.visibleOrder.compactMap { vendor -> [QuotaSnapshot]? in
            // A pool with no snapshots cannot anchor the block: the dictionary
            // is only ever populated by appends, so an empty entry is not a
            // reading and must not claim the anchor.
            guard !(byVendor[vendor] ?? []).isEmpty else { return nil }
            guard antigravity.contains(vendor) else { return byVendor[vendor] }
            guard !addedAntigravity else { return nil }
            addedAntigravity = true
            let poolOrder = prefs.visibleOrder.filter { antigravity.contains($0) }
            let allAGY = poolOrder.flatMap { byVendor[$0] ?? [] }
            let accountIDs = allAGY.reduce(into: [String]()) { order, snapshot in
                let key = snapshot.antigravityAccount?.id ?? ""
                if !order.contains(key) { order.append(key) }
            }
            guard accountIDs.count > 1 else { return allAGY }
            return accountIDs.flatMap { accountID in
                poolOrder.flatMap { pool in
                    (byVendor[pool] ?? []).filter { ($0.antigravityAccount?.id ?? "") == accountID }
                }
            }
        }

        // A custom order has two exceptions: visible nonempty Antigravity pools
        // are collected at their first member's position in stable within-service
        // order, then exhausted blocks move to the bottom. Antigravity's whole
        // block moves last only when every visible pool has a spent or blocked
        // window. Other vendors use the same "best instance" rule as below.
        //
        // Deliberately a stable split rather than a re-sort: everything live
        // keeps the resulting service-block order, and the workspaces of one vendor
        // stay together, placed by whichever of them is most usable. Splitting
        // a block would scatter two OpenCode Go workspaces to opposite ends of
        // the list.
        if prefs.ordering == .custom {
            func isExhausted(_ group: [QuotaSnapshot]) -> Bool {
                group.map(Self.sortBand).min() == 2
            }
            return groups.filter { !isExhausted($0) }.flatMap { $0 }
                + groups.filter(isExhausted).flatMap { $0 }
        }

        // A group's place is its best instance's: the lowest band, and within
        // band 0 the soonest reset. For a single-instance vendor that is
        // exactly its own band and reset, as before.
        func key(_ group: [QuotaSnapshot]) -> (band: Int, reset: Date?) {
            let band = group.map(Self.sortBand).min() ?? 1
            let reset = group.filter { Self.sortBand($0) == band }.compactMap(\.longestWindowReset).min()
            return (band, reset)
        }
        return groups.sorted { a, b in
            let keyA = key(a), keyB = key(b)
            if keyA.band != keyB.band { return keyA.band < keyB.band }
            if keyA.band == 0, let resetA = keyA.reset, let resetB = keyB.reset, resetA != resetB {
                return resetA < resetB
            }
            return (rank[a[0].vendorId] ?? .max) < (rank[b[0].vendorId] ?? .max)
        }.flatMap { $0 }
    }

    static func sortBand(_ snapshot: QuotaSnapshot) -> Int {
        if snapshot.isQuotaExhausted { return 2 }
        return snapshot.longestWindowReset == nil ? 1 : 0
    }




    /// Returns true if cache is still fresh.
    public func isCacheFresh() -> Bool {
        guard let last = lastCompleteFetch else { return false }
        return clock().timeIntervalSince(last) < cachePolicy.cacheTTL
    }

    /// Worst quota pressure across providers we could actually read.
    /// Providers we could not read contribute `.none` — they are reported
    /// separately via `SystemHealthSummary.unavailableCount`.
    public func worstUrgency() -> Urgency {
        visibleCache().values.map(\.status.urgency).max() ?? .none
    }

    // MARK: Fetch (with concurrency + dedup)

    /// Returns cached data when it is still fresh, otherwise fetches.
    /// Concurrent callers share a single in-flight fetch.
    public func refresh() async -> [String: QuotaSnapshot] {
        if isCacheFresh() {
            return cachedSnapshots()
        }
        return await fetchDeduplicated()
    }

    /// Requests a user pass. Concurrent manual callers share it; an automatic
    /// pass already in flight is followed by one user pass.
    public func forceRefresh() async -> [String: QuotaSnapshot] {
        lastCompleteFetch = nil
        return await fetchDeduplicated(force: true)
    }

    /// Lets a UI already awaiting this pass register a click without waiting
    /// for the same task twice. Its original caller receives the final result.
    public func queueUserRefreshIfActive() -> Bool {
        guard activeTask != nil else { return false }
        if !activeTaskIsForced { forcedPassPending = true }
        return true
    }

    // MARK: Private

    private func fetchDeduplicated(force: Bool = false) async -> [String: QuotaSnapshot] {
        // A forced refresh must join too. Keep one owner of the in-flight
        // pass, but queue a user-initiated pass if this one is automatic.
        // Automatic selection may have skipped a vendor under Retry-After or
        // the automatic floor, and cannot satisfy the person's click.
        if let existing = activeTask {
            if force && !activeTaskIsForced { forcedPassPending = true }
            return await existing.value
        }

        activeTaskIsForced = force
        let task = Task {
            var result = await self.parallelFetch(force: force)
            if self.forcedPassPending {
                self.forcedPassPending = false
                self.activeTaskIsForced = true
                // A successful in-flight read already satisfies the click.
                // Retry only skipped providers and unavailable outcomes.
                let satisfied = self.successfulPassIDs
                result = await self.parallelFetch(force: true, excluding: satisfied)
                // Arm the user floor only once the follow-up has settled.
                // Bumping `lastUserFetchAt` before it made the floor, not the
                // exclusion above, the thing that stopped a satisfied provider
                // being asked twice - so a follow-up that re-asked every
                // provider looked identical from the outside. Providers this
                // click satisfied keep the reading they were served and are
                // marked as user-fetched from this instant.
                let satisfiedAt = self.clock()
                for id in satisfied {
                    if let entry = self.cache[id] {
                        self.cache[id] = CacheEntry(snapshot: entry.snapshot, fetchedAt: entry.fetchedAt,
                            lastUserFetchAt: satisfiedAt, vendorRetryAfter: entry.vendorRetryAfter)
                    }
                }
            }
            // Clear ownership before returning, while still on this actor.
            // A caller arriving after completion must start a new pass rather
            // than queue onto a task whose follow-up decision already ran.
            self.activeTask = nil
            return result
        }
        activeTask = task
        return await task.value
    }

    private var successfulPassIDs: Set<String> = []

    private func parallelFetch(force: Bool = false, excluding: Set<String> = []) async -> [String: QuotaSnapshot] {
        // Read once, so a preference change mid-fetch cannot split the pass.
        // A hidden provider is not polled at all, and its cache entry goes so
        // it vanishes from every surface and, once shown again, is fetched at
        // once instead of being served from under the poll floor.
        let hidden = displayPreferences().hidden
        for key in Array(cache.keys) where hidden.contains(cache[key]!.snapshot.vendorId) { cache[key] = nil }
        var allProviders: [any QuotaProvider] = providerFactory()
        if !hidden.contains(.claude), let discover = claudeProviderFactory {
            let discovery = await withDeadline(seconds: cachePolicy.perProviderTimeout) {
                await QuotaFetchContext.$isUserInitiated.withValue(force) { await discover() }
            }
            let accounts: [any QuotaProvider]
            switch discovery {
            case .success(let found): accounts = found
            case .failure(let reason):
                let previous = cache.values.map(\.snapshot).filter { $0.vendorId == .claude }
                accounts = previous.isEmpty
                    ? [UnavailableClaudeInstance(id: "claude", name: "Claude", reason: reason)]
                    : previous.map { UnavailableClaudeInstance(id: $0.id, name: $0.displayName, reason: reason) }
            }
            let insertion = allProviders.firstIndex { $0.vendorId == .claude } ?? 0
            allProviders.removeAll { $0.vendorId == .claude }
            allProviders.insert(contentsOf: accounts, at: min(insertion, allProviders.count))
        }
        let antigravityVendors: Set<VendorIdentifier> = [.gemini, .antigravityClaude, .antigravityArgon]
        if !antigravityVendors.isSubset(of: hidden), let discoverAGY = antigravityProviderFactory {
            let discovery = await withDeadline(seconds: cachePolicy.perProviderTimeout) {
                await QuotaFetchContext.$isUserInitiated.withValue(force) { await discoverAGY() }
            }
            let agyProviders: [any QuotaProvider]
            switch discovery {
            case .success(let found): agyProviders = found
            case .failure(let reason):
                let previous = cache.values.map(\.snapshot).filter { antigravityVendors.contains($0.vendorId) }
                agyProviders = previous.isEmpty
                    ? [
                        UnavailableAntigravityInstance(id: VendorIdentifier.gemini.rawValue, vendorId: .gemini, name: VendorIdentifier.gemini.displayName, account: nil, reason: reason),
                        UnavailableAntigravityInstance(id: VendorIdentifier.antigravityClaude.rawValue, vendorId: .antigravityClaude, name: VendorIdentifier.antigravityClaude.displayName, account: nil, reason: reason),
                        UnavailableAntigravityInstance(id: VendorIdentifier.antigravityArgon.rawValue, vendorId: .antigravityArgon, name: VendorIdentifier.antigravityArgon.displayName, account: nil, reason: reason),
                    ]
                    : previous.map {
                        UnavailableAntigravityInstance(id: $0.id, vendorId: $0.vendorId, name: $0.displayName, account: $0.antigravityAccount, reason: reason)
                    }
            }
            let insertion = allProviders.firstIndex { antigravityVendors.contains($0.vendorId) } ?? allProviders.count
            allProviders.removeAll { antigravityVendors.contains($0.vendorId) }
            allProviders.insert(contentsOf: agyProviders, at: min(insertion, allProviders.count))
        }
        let providers: [any QuotaProvider] = allProviders.filter { !hidden.contains($0.vendorId) }
        // A workspace that was removed (or disabled) must not linger in the
        // cache. Only the multi-instance vendor is pruned here: a single
        // instance's absence from the provider list is not proof it was
        // removed — it may simply have been filtered — and the retention path
        // below depends on its entry surviving a transient failure.
        let liveOpenCodeInstances = Set(
            allProviders.filter { $0.vendorId == .opencode }.map(\.instanceID))
        for key in Array(cache.keys) where key.hasPrefix(OpenCodeGoWorkspaceStore.instancePrefix)
            && !liveOpenCodeInstances.contains(key) {
            cache[key] = nil
        }
        let liveClaude = Set(allProviders.filter { $0.vendorId == .claude }.map(\.instanceID))
        if claudeProviderFactory != nil {
            for key in Array(cache.keys) where (key == VendorIdentifier.claude.rawValue
                || key.hasPrefix(ClaudeAccount.instancePrefix)) && !liveClaude.contains(key) {
                cache[key] = nil
            }
        }
        let liveAntigravity = Set(allProviders.filter { antigravityVendors.contains($0.vendorId) }.map(\.instanceID))
        if antigravityProviderFactory != nil {
            let legacyAGYKeys = Set(antigravityVendors.map(\.rawValue))
            for key in Array(cache.keys) where (legacyAGYKeys.contains(key)
                || key.hasPrefix(AntigravityAccount.instancePrefix)) && !liveAntigravity.contains(key) {
                cache[key] = nil
            }
        }
        // Remember the build order so several instances of one vendor keep the
        // order the user arranged them in when the list is sorted.
        instanceOrder = providers.map(\.instanceID)
        for case let provider as ClaudeAccountQuotaProvider in providers {
            guard let entry = cache[provider.instanceID] else { continue }
            var snapshot = entry.snapshot
            // A nickname is presentation, so editing it takes effect even
            // while this account's vendor backoff retains its last reading.
            snapshot.displayName = provider.account.name
            snapshot.claudeAccount = provider.account
            snapshot.apiCredits = snapshot.apiCredits.map { entry in
                var copy = entry
                if entry.accountID == snapshot.id { copy.accountName = provider.account.name }
                return copy
            }
            cache[provider.instanceID] = CacheEntry(snapshot: snapshot, fetchedAt: entry.fetchedAt,
                lastUserFetchAt: entry.lastUserFetchAt, vendorRetryAfter: entry.vendorRetryAfter)
        }
        for case let provider as GeminiQuotaProvider in providers {
            guard let account = provider.account, let entry = cache[provider.instanceID] else { continue }
            var snapshot = entry.snapshot
            snapshot.antigravityAccount = account
            cache[provider.instanceID] = CacheEntry(snapshot: snapshot, fetchedAt: entry.fetchedAt,
                lastUserFetchAt: entry.lastUserFetchAt, vendorRetryAfter: entry.vendorRetryAfter)
        }
        let budget = cachePolicy.perProviderTimeout
        let minPollInterval = cachePolicy.minPollInterval
        let startNow = clock()

        // Per-vendor poll floor: a vendor fetched more recently than
        // minPollInterval is served its cached snapshot instead of being
        // re-hit, so mashing refresh can't hammer a paid provider's API faster
        // than the floor allows.
        //
        // Which instant the floor is measured from depends on who is asking.
        // An automatic poll measures from `fetchedAt` — the last fetch of any
        // kind — so the 2-minute tick and the load the popover runs when it
        // opens cannot re-hit a vendor between them. A *forced* refresh
        // measures from `lastUserFetchAt` instead: the user pressing ⟳ is not
        // the poll loop, so an automatic fetch a moment earlier must not turn
        // the button into a silent no-op. Mashing it is still bounded, because
        // each forced fetch re-arms `lastUserFetchAt` and the next click inside
        // the floor is served from cache.
        var providersToFetch: [any QuotaProvider] = []
        var throttledOnForce: [String] = []
        for provider in providers {
            if excluding.contains(provider.instanceID) { continue }
            let shouldThrottle: Bool
            if let entry = cache[provider.instanceID] {
                let measuredFrom = force ? entry.lastUserFetchAt : entry.fetchedAt
                let withinFloor = measuredFrom.map {
                    startNow.timeIntervalSince($0) < minPollInterval
                } ?? false
                // The vendor's own backoff, which outranks the floor because it
                // is longer and means more: Anthropic answers a 429 on its usage
                // endpoint with `Retry-After: 2377`, and re-asking every 120s for
                // the next 40 minutes spends a budget the account shares with
                // every other client on it — Claude Code included. Polling
                // through the window cannot produce a reading; it can only keep
                // the account throttled. Only an *automatic* poll waits: the
                // user's own ⟳ is a person asking, not the poll loop, and
                // swallowing their click is the dead-button bug #90 fixed.
                let withinVendorBackoff = !force
                    && (entry.vendorRetryAfter.map { startNow < $0 } ?? false)
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
                    shouldThrottle = withinFloor || withinVendorBackoff
                }
            } else {
                shouldThrottle = false
            }
            if shouldThrottle {
                if force { throttledOnForce.append(provider.instanceID) }
            } else {
                providersToFetch.append(provider)
            }
        }
        // A forced refresh that ends up issuing no network request at all
        // looks, to the caller, exactly like a plain cache read — so this is
        // logged rather than left silent, unlike the throttled-but-not-forced
        // case, which is the poll floor working as designed. Reaching here now
        // means the user asked twice inside the floor, not that an automatic
        // poll beat them to it.
        if force, !throttledOnForce.isEmpty {
            NSLog("frugalbar: forceRefresh() served \(throttledOnForce.count) provider(s) from cache " +
                  "(a refresh was already requested within minPollInterval=\(minPollInterval)s): " +
                  "\(throttledOnForce)")
        }
        var results: [String: QuotaSnapshot] = [:]
        let cycleLookup = self.cycleLookup

        let creditInvalidation = monthlyCreditInvalidation
        let openAICreditInvalidation = openAIMonthlyCreditInvalidation
        let forgottenAtStart = forgottenVendors
        let creditConnection = await monthlyCreditConnection()
        var deadlineFailures: Set<String> = []
        await withTaskGroup(of: (String, QuotaSnapshot, Bool).self) { group in
            for provider in providersToFetch {
                group.addTask {
                    // A whole-provider deadline. URLSession's per-request timeout
                    // does not bound a provider that issues several requests.
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    let deadline = ContinuousClock.now + .seconds(budget)
                    let retained = Mutex<QuotaSnapshot?>(nil)
                    let retain: @Sendable (QuotaSnapshot) -> Void = { snapshot in
                        retained.withLock {
                            guard ContinuousClock.now <= deadline,
                                  snapshot.status.confidence == .measured else { return }
                            $0 = snapshot
                        }
                    }
                    var outcome = await withDeadline(seconds: budget) {
                        try await QuotaFetchContext.$retainOnTimeout.withValue(retain) {
                            try await QuotaFetchContext.$deadline.withValue(deadline) {
                                try await QuotaFetchContext.$isUserInitiated.withValue(force) {
                                    try await provider.fetchSnapshot()
                                }
                            }
                        }
                    }
                    if case .failure(.timedOut) = outcome, let snapshot = retained.withLock({ $0 }) {
                        outcome = .success(snapshot)
                    }
                    // A vendor-wide hand-entered renewal has no account
                    // binding. It cannot be copied onto every Claude account.
                    let cycle = provider.vendorId == .claude && provider.instanceID != "claude"
                        ? nil : cycleLookup(provider.vendorId)
                    switch outcome {
                    case .success(var snapshot):
                        // Measured here rather than guessed in each provider:
                        // one real number for every vendor, including the ones
                        // that issue several requests per refresh.
                        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                        snapshot.latencyMs = Int(elapsed / 1_000_000)
                        return (provider.instanceID, Self.attachingCycleRow(to: snapshot, cycle: cycle), false)
                    case .failure(let reason):
                        let placeholder = Self.unavailableSnapshot(for: provider, reason: reason)
                        return (provider.instanceID, Self.attachingCycleRow(to: placeholder, cycle: cycle), reason == .timedOut)
                    }
                }
            }
            for await (instanceID, snapshot, deadlineFailed) in group {
                results[instanceID] = snapshot
                if deadlineFailed { deadlineFailures.insert(instanceID) }
            }
        }

        let currentCreditConnection = await monthlyCreditConnection()
        // Read once, with no suspension between here and the cache write
        // below, so the check describes the session as the pass commits.
        let currentCreditIdentities: Set<String>?? = if let monthlyCreditIdentities {
            .some(await monthlyCreditIdentities())
        } else { .none }
        let acceptsMonthlyCredit = creditConnection != nil && creditConnection == currentCreditConnection
            && creditInvalidation == monthlyCreditInvalidation
        let acceptsOpenAIMonthlyCredit = openAICreditInvalidation == openAIMonthlyCreditInvalidation
        // A vendor forgotten during this pass (a disconnect) has no result:
        // it is neither committed nor counted as read, so a pass queued
        // behind this one fetches it afresh rather than skipping it.
        for provider in providersToFetch
        where forgottenVendors[provider.vendorId] != forgottenAtStart[provider.vendorId] {
            results[provider.instanceID] = nil
        }
        successfulPassIDs = Set(results.compactMap { id, snapshot in
            snapshot.status.confidence == .measured && snapshot.staleReading == nil ? id : nil
        })
        let now = clock()
        for provider in providersToFetch {
            let id = provider.instanceID
            guard var snap = results[id] else { continue }
            if deadlineFailures.contains(id) {
                snap.monthlyAPICredit = cache[id]?.snapshot.monthlyAPICredit
                snap.monthlyAPICredit?.refreshFailed = true
                snap.openAIMonthlyCredit = cache[id]?.snapshot.openAIMonthlyCredit
                snap.openAIMonthlyCredit?.refreshFailed = true
                snap.openAIMonthlyCreditReadAt = cache[id]?.snapshot.openAIMonthlyCreditReadAt
            }
            if !acceptsMonthlyCredit { snap.monthlyAPICredit = nil }
            // A disconnect while this pass was in flight rejects the pass's
            // independent OpenAI grant, including one already read.
            if !acceptsOpenAIMonthlyCredit {
                snap.openAIMonthlyCredit = nil
                snap.openAIMonthlyCreditReadAt = nil
            }
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
            // Retention preserves *figures*, so it only applies to a provider
            // we previously read. An absence is always the current one: two
            // failures in a row must report the newest reason rather than
            // freeze the first one indefinitely, and a placeholder carries no
            // figures worth keeping.
            // Retention also stays inside one series: a provider that files
            // readings per discovered workspace (OpenDesign) reports a failure
            // under its bare id, and another workspace's figures must not stand
            // in for it.
            let isHardRestriction: Bool = if case .unsupported = snap.status.unavailableReason { true } else { false }
            if let reason = snap.status.unavailableReason,
               !isHardRestriction,
               let previous = cache[id], previous.snapshot.status.confidence == .measured,
               previous.snapshot.id == snap.id {
                // The retained snapshot's hand-entered cycle row (if any) was
                // computed at the last successful fetch and frozen there — a
                // vendor down for days would otherwise keep showing e.g. "3
                // days left in monthly cycle" for the whole outage, the one
                // figure here that doesn't depend on the provider at all.
                // Re-attach against `now` so it keeps counting down.
                var retained = Self.attachingCycleRow(
                    to: Self.removingStaleCycleRow(from: previous.snapshot),
                    cycle: provider.vendorId == .claude && id != "claude" ? nil : cycleLookup(provider.vendorId), now: now)
                // Carry the failure along with the figures. Retention keeps
                // `status` — the last known pressure must still drive the menu
                // bar icon, and an unreadable provider must never outrank a
                // critical quota — so this field is the *only* thing that says
                // these figures are not this poll's reading. Without it the row
                // showed hour-old numbers as current, the footer's oldest
                // reading froze for the whole outage, and the history re-stamped
                // them with a fresh timestamp.
                retained.staleReading = StaleReading(reason: reason, at: now)
                retained.monthlyAPICredit = snap.monthlyAPICredit
                // The billing session is independent of the quota poll. A
                // read completed this pass — including a valid read that
                // found no grant — replaces the retained one; no read keeps
                // the last known grant.
                if let readAt = snap.openAIMonthlyCreditReadAt {
                    retained.openAIMonthlyCredit = snap.openAIMonthlyCredit
                    retained.openAIMonthlyCreditReadAt = readAt
                }
                displaySnapshot = retained
            } else {
                displaySnapshot = snap
            }
            // A provider we attempted re-arms the floors it is supposed to:
            // `fetchedAt` always (so the automatic floor measures from the
            // attempt, not the outcome), and `lastUserFetchAt` when a user
            // requested this user-initiated pass, so another ⟳ is served from
            // cache rather than re-hitting the vendor. A provider never
            // fetched this round is not in this loop at all and keeps both
            // instants.
            let previous = cache[id]
            cache[id] = CacheEntry(
                snapshot: displaySnapshot,
                fetchedAt: now,
                lastUserFetchAt: force ? now : previous?.lastUserFetchAt,
                vendorRetryAfter: Self.vendorRetryAfter(from: snap.status))
        }
        keepOneClaudeMonthlyCredit(currentIdentities: currentCreditIdentities)
        lastCompleteFetch = now
        return visibleCache()
    }

    /// The linked Console credit belongs to one Claude row. Rows read it one
    /// after another, and a row not fetched this pass keeps its cached line,
    /// so an account change in the billing session could leave the old row's
    /// credit beside the new row's. Keep only the latest observation, by the
    /// order the billing session accepted it (`observation`), never by when a
    /// provider happened to start; every other row's line is cleared. Two rows
    /// holding the same observation cannot both have been bound to it, so a
    /// tie keeps none.
    ///
    /// Before that, a named row keeps the credit only while the billing
    /// session still attributes it to the same identity. A row that took the
    /// last read when its wait ran out, or a cached line from an earlier pass,
    /// could otherwise outlive a sign-in change the session saw in between.
    private func keepOneClaudeMonthlyCredit(currentIdentities: Set<String>?? = .none) {
        if case .some(let current) = currentIdentities {
            // A named row is known by its stable instance id: a deadline
            // placeholder carries the previous credit but no account.
            for (id, entry) in cache where entry.snapshot.vendorId == .claude
                && id.hasPrefix(ClaudeAccount.instancePrefix)
                && entry.snapshot.monthlyAPICredit != nil
                && (current == nil || entry.snapshot.monthlyAPICredit?.webIdentities != current) {
                var snapshot = entry.snapshot
                snapshot.monthlyAPICredit = nil
                cache[id] = CacheEntry(snapshot: snapshot, fetchedAt: entry.fetchedAt,
                    lastUserFetchAt: entry.lastUserFetchAt, vendorRetryAfter: entry.vendorRetryAfter)
            }
        }
        let holders = cache.filter { $0.value.snapshot.vendorId == .claude && $0.value.snapshot.monthlyAPICredit != nil }
        guard holders.count > 1 else { return }
        let latest = holders.map { $0.value.snapshot.monthlyAPICredit!.observation }.max()!
        let winners = holders.filter { $0.value.snapshot.monthlyAPICredit!.observation == latest }.map(\.key)
        let newest = winners.count == 1 ? winners[0] : nil
        for (id, entry) in holders where id != newest {
            var snapshot = entry.snapshot
            snapshot.monthlyAPICredit = nil
            cache[id] = CacheEntry(snapshot: snapshot, fetchedAt: entry.fetchedAt,
                lastUserFetchAt: entry.lastUserFetchAt, vendorRetryAfter: entry.vendorRetryAfter)
        }
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
        // the initializer doesn't accept (the credit entries) has to be copied
        // across explicitly, or it silently reverts to its default on this one
        // path.
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
            // A rebuild must not drop real published figures: the credit
            // entries ride this snapshot, and losing them here would make
            // them flicker out whenever a hand-entered cycle row is attached.
            rebuilt.apiCredits = updated.apiCredits
            rebuilt.scopedBars = updated.scopedBars
            rebuilt.monthlyAPICredit = updated.monthlyAPICredit
            rebuilt.openAIMonthlyCredit = updated.openAIMonthlyCredit
            rebuilt.openAIMonthlyCreditReadAt = updated.openAIMonthlyCreditReadAt
            rebuilt.openAIAccountKey = updated.openAIAccountKey
            rebuilt.claudeAccount = updated.claudeAccount
            rebuilt.antigravityAccount = updated.antigravityAccount
            rebuilt.resetCreditExpiries = updated.resetCreditExpiries
            rebuilt.resetCreditGroups = updated.resetCreditGroups
            rebuilt.resetCreditsAvailable = updated.resetCreditsAvailable
            rebuilt.resetCreditsApplicable = updated.resetCreditsApplicable
            // A fact about the poll, not a figure that was re-fetched: the
            // pass that re-attaches a cycle row must not turn a stale reading
            // into a current one.
            rebuilt.staleReading = updated.staleReading
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
        rebuilt.apiCredits = updated.apiCredits
        rebuilt.scopedBars = updated.scopedBars
        rebuilt.monthlyAPICredit = updated.monthlyAPICredit
        rebuilt.openAIMonthlyCredit = updated.openAIMonthlyCredit
        rebuilt.openAIMonthlyCreditReadAt = updated.openAIMonthlyCreditReadAt
        rebuilt.openAIAccountKey = updated.openAIAccountKey
        rebuilt.claudeAccount = updated.claudeAccount
        rebuilt.antigravityAccount = updated.antigravityAccount
        rebuilt.resetCreditExpiries = updated.resetCreditExpiries
        rebuilt.resetCreditGroups = updated.resetCreditGroups
        rebuilt.resetCreditsAvailable = updated.resetCreditsAvailable
        rebuilt.resetCreditsApplicable = updated.resetCreditsApplicable
        // Same rule as the catalog failure above: this snapshot's figures are
        // already known to be old, and stripping a cycle row does not make
        // them current.
        rebuilt.staleReading = updated.staleReading
        return rebuilt
    }

    /// The backoff a vendor attached to its 429, if this attempt was one. Any
    /// other outcome clears it, so a recovered vendor is polled normally.
    private static func vendorRetryAfter(from status: ProviderStatus) -> Date? {
        if case .unavailable(.rateLimited(let retryAfter)) = status { return retryAfter }
        return nil
    }

    /// Builds the placeholder shown when a provider could not be read.
    /// Deliberately carries no metric: there is no number to draw.
    static func unavailableSnapshot(
        for provider: any QuotaProvider,
        reason: UnavailableReason
    ) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(
            id: provider.instanceID,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .subscription(tierName: reason.headline, renewalDate: nil),
            status: .unavailable(reason),
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: reason.remedy
        )
        if let agy = provider as? GeminiQuotaProvider {
            snapshot.antigravityAccount = agy.account
        }
        return snapshot
    }
}

private struct UnavailableAntigravityInstance: QuotaProvider {
    let id: String
    let vendorId: VendorIdentifier
    let name: String
    let account: AntigravityAccount?
    let reason: UnavailableReason
    var instanceID: String { id }
    var displayName: String { name }
    var category: MetricCategory { .aiSubscriptions }
    func fetchSnapshot() async throws -> QuotaSnapshot {
        var snapshot = unavailable(reason)
        snapshot.antigravityAccount = account
        snapshot.planName = account?.planName
        return snapshot
    }
}

/// Discovery's own deadline preserves each known row's cache identity so the
/// normal stale-retention path can keep its last reading without relabelling it.
private struct UnavailableClaudeInstance: QuotaProvider {
    let id: String
    let name: String
    let reason: UnavailableReason
    var vendorId: VendorIdentifier { .claude }
    var category: MetricCategory { .aiSubscriptions }
    var displayName: String { name }
    var instanceID: String { id }
    func fetchSnapshot() async throws -> QuotaSnapshot { unavailable(reason) }
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
    /// How many providers are still counted as read, but whose figures came
    /// from an earlier poll because the newest one failed.
    ///
    /// Separate from `unavailableCount` on purpose, and never folded into it:
    /// a stale provider *has* a reading, so it must keep driving the urgency
    /// bucket and the menu bar icon rather than being swapped for the "cannot
    /// read" grey. Counting it as unreadable here is exactly the inversion that
    /// once made the icon a permanent error triangle.
    public let staleCount: Int
    /// Oldest reading in the set — the honest "data as of" timestamp.
    public let oldestReading: Date?
    /// Newest provider check, including failed polls that retained an older
    /// reading. Reading age and check age answer different questions.
    public let lastAttemptAt: Date?
    public let totalProviders: Int

    /// True when at least one provider was read successfully.
    public var hasAnyReading: Bool { totalProviders > unavailableCount }

    public static func compute(from snapshots: [QuotaSnapshot]) -> SystemHealthSummary {
        var healthy = 0, warning = 0, critical = 0, unavailable = 0, stale = 0
        var worst: Urgency = .none
        var oldest: Date?
        var lastAttempt: Date?

        for snap in snapshots {
            let attemptedAt = snap.staleReading?.at ?? snap.lastUpdated
            if lastAttempt.map({ attemptedAt > $0 }) ?? true { lastAttempt = attemptedAt }
            switch snap.status.confidence {
            case .unavailable:
                unavailable += 1
            case .measured:
                if snap.staleReading != nil { stale += 1 }
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
            staleCount: stale,
            oldestReading: oldest,
            lastAttemptAt: lastAttempt,
            totalProviders: snapshots.count
        )
    }
}
