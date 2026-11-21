import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

// These drive the real `QuotaStore` over a real `QuotaManager` whose providers
// are stubs. An earlier version of this file tested a private reimplementation
// of the store, so it kept passing whatever the production class did.

private final class Hits: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [VendorIdentifier: Int] = [:]
    func hit(_ vendor: VendorIdentifier) { lock.lock(); counts[vendor, default: 0] += 1; lock.unlock() }
    func count(_ vendor: VendorIdentifier) -> Int { lock.lock(); defer { lock.unlock() }; return counts[vendor] ?? 0 }
}

private final class PrefsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ProviderDisplayPreferences
    init(_ value: ProviderDisplayPreferences = .default) { _value = value }
    var value: ProviderDisplayPreferences {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[VendorIdentifier]] = []
    func add(_ snapshots: [QuotaSnapshot]) { lock.lock(); batches.append(snapshots.map(\.vendorId)); lock.unlock() }
    var all: [[VendorIdentifier]] { lock.lock(); defer { lock.unlock() }; return batches }
}

private final class GeminiCreditBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: GeminiAPICredit?
    init(_ value: GeminiAPICredit?) { _value = value }
    var value: GeminiAPICredit? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

private actor FirstPollGate {
    private var started = false
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func run() async {
        guard !started else { return }
        started = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitForEntry() async {
        guard !started else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

private struct StubProvider: QuotaProvider {
    let vendorId: VendorIdentifier
    let displayName = "Stub"
    let category: MetricCategory = .aiSubscriptions
    let hits: Hits
    var status: ProviderStatus = .healthy
    var delay: Duration = .zero
    var gate: FirstPollGate? = nil
    var measuredAt: Date? = nil
    var failureAfterFirst: ProviderError? = nil

    func fetchSnapshot() async throws -> QuotaSnapshot {
        hits.hit(vendorId)
        if hits.count(vendorId) > 1, let failureAfterFirst { throw failureAfterFirst }
        await gate?.run()
        if delay > .zero { try await Task.sleep(for: delay) }
        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category,
            metric: .percentage(usedFraction: 0.1, displayDetails: nil),
            status: status, resetsAt: nil, lastUpdated: measuredAt ?? Date(), auxiliaryInfo: nil)
    }
}

@Suite("QuotaStore")
@MainActor
struct QuotaStoreTests {

    private func store(
        _ providers: [StubProvider],
        prefs: PrefsBox = PrefsBox(),
        cacheTTL: TimeInterval = 30,
        recorder: Recorded? = nil
    ) -> QuotaStore {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: cacheTTL, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { providers },
            displayPreferences: { prefs.value })
        return QuotaStore(
            manager: manager,
            historyRecorder: recorder.map { r in { @Sendable snaps in r.add(snaps) } })
    }

    @Test("starts empty and not loaded")
    func initialState() {
        let s = store([])
        #expect(s.snapshots.isEmpty)
        #expect(s.summary.totalProviders == 0)
        #expect(s.isRefreshing == false)
        #expect(s.hasLoaded == false)
    }

    @Test("load populates snapshots and summary")
    func loadPopulates() async {
        let hits = Hits()
        let s = store([
            StubProvider(vendorId: .claude, hits: hits),
            StubProvider(vendorId: .grok, hits: hits, status: .critical),
        ])
        await s.load()
        #expect(s.snapshots.count == 2)
        #expect(s.summary.totalProviders == 2)
        #expect(s.summary.criticalCount == 1)
        #expect(s.summary.worstUrgency == .critical)
        #expect(s.hasLoaded)
        #expect(s.isRefreshing == false)
        #expect(hits.count(.claude) == 1)
    }

    @Test("a configured credit reloads snapshots without a poll or a history write")
    func configuredCreditReloadsLocally() async throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        func credit(_ balance: Decimal) throws -> GeminiAPICredit {
            try #require(GeminiAPICredit(currencyCode: "AUD", prepaidBalance: balance,
                                         configuredAt: stamp))
        }
        let hits = Hits()
        let recorder = Recorded()
        let box = GeminiCreditBox(try credit(12))
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120,
                                     perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { [StubProvider(vendorId: .gemini, hits: hits)] },
            geminiCreditLookup: { box.value })
        let store = QuotaStore(
            manager: manager,
            historyRecorder: { @Sendable snaps in recorder.add(snaps) })

        await store.load()
        #expect(hits.count(.gemini) == 1)
        #expect(recorder.all.count == 1)
        #expect(store.snapshots.first?.geminiAPICredit == (try credit(12)))

        box.value = try credit(5)
        await store.reloadConfiguredCredit()
        #expect(store.snapshots.first?.geminiAPICredit == (try credit(5)))
        // A typed figure is not a poll: no vendor request and no history row.
        #expect(hits.count(.gemini) == 1)
        #expect(recorder.all.count == 1)
    }

    @Test("onSummaryChange fires with the new summary")
    func summaryCallback() async {
        let s = store([StubProvider(vendorId: .claude, hits: Hits(), status: .warning)])
        var seen: [Urgency] = []
        s.onSummaryChange = { seen.append($0.worstUrgency) }
        await s.load()
        #expect(seen == [.warning])
    }

    @Test("a fresh cache is served without refetching; forceRefresh bypasses it")
    func cacheVersusForce() async {
        let hits = Hits()
        let s = store([StubProvider(vendorId: .claude, hits: hits)])
        await s.load()
        await s.load()
        #expect(hits.count(.claude) == 1)
        await s.forceRefresh()
        #expect(hits.count(.claude) == 2)
    }

    /// The notification observer runs from this hook, so a manual fresh read
    /// can confirm or discard a restore candidate between scheduled polls.
    @Test("load and manual refresh report their published snapshots in order")
    func userRefreshCompletionHook() async {
        let hits = Hits()
        let s = store([StubProvider(vendorId: .claude, hits: hits)])
        var seen: [Int] = []
        s.onQuotaRefreshCompleted = { snapshots in
            #expect(snapshots.count == 1)
            seen.append(hits.count(.claude))
        }
        await s.load()
        #expect(seen == [1])
        await s.forceRefresh()
        #expect(seen == [1, 2])
        #expect(s.snapshots.count == 1)
    }

    @Test("manual refresh during a successful poll shares its request")
    func overlappingRefreshesCollapse() async {
        let hits = Hits()
        let gate = FirstPollGate()
        let s = store([StubProvider(vendorId: .claude, hits: hits, gate: gate)], cacheTTL: 0)
        var observed: [[String]] = []
        s.onQuotaRefreshCompleted = { observed.append($0.map(\.id)) }
        async let first: Void = s.load()
        await gate.waitForEntry()
        #expect(s.isRefreshing)
        await s.forceRefresh()
        await s.forceRefresh()   // repeated clicks coalesce into one pass
        await gate.resume()
        await first
        #expect(hits.count(.claude) == 1)
        #expect(observed == [["claude"]])
        #expect(s.isRefreshing == false)
    }

    @Test("a manual rebound discards a restore candidate before the next scheduled read")
    func manualReboundDiscardsRestoreCandidate() async {
        actor Readings: QuotaProvider {
            let vendorId: VendorIdentifier = .gemini
            let displayName = "Gemini"
            let category: MetricCategory = .aiSubscriptions
            let start: Date
            var fractions = [0.9, 0.0, 0.9, 0.0]

            init(start: Date) { self.start = start }

            func fetchSnapshot() async throws -> QuotaSnapshot {
                let now = start.addingTimeInterval(Double(4 - fractions.count) * 120)
                let fraction = fractions.removeFirst()
                return QuotaSnapshot(
                    id: vendorId.rawValue, vendorId: vendorId, displayName: displayName, category: category,
                    metric: .subscription(tierName: nil, renewalDate: nil), status: .healthy,
                    resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                    row1: DualBarMetrics(primaryFraction: fraction, label: "WK",
                                        resetsAt: start.addingTimeInterval(86_400)))
            }
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = Readings(start: now)
        let manager = QuotaManager(cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120,
            minPollInterval: 0), providerFactory: { [provider] }, displayPreferences: { PrefsBox().value })
        let store = QuotaStore(manager: manager)
        let observer = QuotaNotificationObserver()
        var restores: [UsageRestoredEvent] = []
        var observed: [Double] = []
        store.onQuotaRefreshCompleted = { snapshots in
            observed += snapshots.compactMap { $0.row1?.primaryFraction }
            restores += await observer.observeTransitions(current: snapshots, now: now).restores
        }

        await store.load()
        await store.load()
        await store.forceRefresh()
        await store.load()
        #expect(observed == [0.9, 0, 0.9, 0])
        #expect(restores.isEmpty)
    }

    @Test("a queued manual click bypasses the automatic floor and vendor backoff")
    func queuedManualRefreshBypassesVendorBackoff() async {
        let hits = Hits()
        let gate = FirstPollGate()
        let provider = StubProvider(vendorId: .claude, hits: hits,
            status: .unavailable(.rateLimited(retryAfter: Date().addingTimeInterval(600))), gate: gate)
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120,
                perProviderTimeout: 2, minPollInterval: 30), providerFactory: { [provider] })
        let s = QuotaStore(manager: manager)
        async let first: Void = s.load()
        await gate.waitForEntry()
        await s.forceRefresh()
        await s.forceRefresh()
        await gate.resume()
        await first
        #expect(hits.count(.claude) == 2)
        // Manual joins manual are coalesced, and the user floor is now armed.
        await s.forceRefresh()
        #expect(hits.count(.claude) == 2)
    }

    /// The reported bug, through the store the popover actually drives. Opening
    /// the popover runs `load()`; the ⟳ the user presses next used to be
    /// swallowed by the poll floor that load had just armed, so the click was a
    /// no-op and the popover kept showing the reading it already had.
    @Test("a ⟳ right after the popover's own load still re-hits the vendor")
    func manualRefreshAfterPopoverLoadIsNotSwallowed() async {
        let hits = Hits()
        // The running app's policy, floor included. The shared helper passes
        // minPollInterval: 0, which is exactly the setting that hides this bug.
        let manager = QuotaManager(
            cachePolicy: CachePolicy(
                cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2,
                minPollInterval: 30),
            providerFactory: { [StubProvider(vendorId: .claude, hits: hits)] })
        let s = QuotaStore(manager: manager)

        await s.load()            // the popover appears: stale cache, so it fetches
        #expect(hits.count(.claude) == 1)

        await s.forceRefresh()    // the ⟳ clicked a moment later
        #expect(hits.count(.claude) == 2)
    }

    @Test("refreshing a failed provider advances check time while retaining its old figures")
    func failedRefreshUpdatesCheckTime() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let hits = Hits()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120,
                perProviderTimeout: 2, minPollInterval: 30),
            providerFactory: {
                [StubProvider(vendorId: .muse, hits: hits, measuredAt: old, failureAfterFirst: .badResponse)]
            })
        let store = QuotaStore(manager: manager)
        await store.load()
        #expect(store.summary.lastAttemptAt == old)
        await store.forceRefresh()
        let retained = try #require(store.snapshots.first)
        let failedAt = try #require(retained.staleReading?.at)
        #expect(retained.lastUpdated == old)
        #expect(store.summary.oldestReading == old)
        #expect(store.summary.lastAttemptAt == failedAt)
        #expect(store.summary.staleCount == 1)
        #expect(!store.isRefreshing)
        #expect(SystemHealthPresentation.pollStatus(lastAttemptAt: store.summary.lastAttemptAt,
            isRefreshing: store.isRefreshing, now: failedAt) == "Checked now")

        // Neither a cached popover load nor a second click inside the poll
        // floor is a new check. Both must preserve the observed attempt time.
        await store.load()
        await store.forceRefresh()
        #expect(hits.count(.muse) == 2)
        #expect(store.summary.lastAttemptAt == failedAt)
    }

    @Test("every poll hands the history recorder the visible snapshots")
    func recorderReceivesSnapshots() async {
        let recorded = Recorded()
        let s = store([StubProvider(vendorId: .claude, hits: Hits())], recorder: recorded)
        await s.load()
        #expect(recorded.all == [[.claude]])
    }

    /// The popover's "Nothing to show" card keys off this: loaded, and empty.
    @Test("hiding every provider leaves a loaded, empty store")
    func allHiddenIsLoadedAndEmpty() async {
        let prefs = PrefsBox(ProviderDisplayPreferences(hidden: Set(VendorIdentifier.allCases)))
        let hits = Hits()
        let s = store([StubProvider(vendorId: .claude, hits: hits)], prefs: prefs)
        await s.load()
        #expect(s.snapshots.isEmpty)
        #expect(s.hasLoaded)
        #expect(hits.count(.claude) == 0)
    }

    @Test("applyProviderPreferences drops a hidden provider and fetches a shown one")
    func applyPreferences() async {
        let prefs = PrefsBox()
        let hits = Hits()
        let s = store([
            StubProvider(vendorId: .claude, hits: hits),
            StubProvider(vendorId: .grok, hits: hits),
        ], prefs: prefs)
        await s.load()
        #expect(s.snapshots.map(\.vendorId) == [.claude, .grok])

        prefs.value.hidden = [.grok]
        await s.applyProviderPreferences()
        #expect(s.snapshots.map(\.vendorId) == [.claude])
        #expect(s.summary.totalProviders == 1)

        prefs.value.hidden = []
        let before = hits.count(.grok)
        await s.applyProviderPreferences()
        #expect(s.snapshots.map(\.vendorId) == [.claude, .grok])
        #expect(hits.count(.grok) == before + 1)
    }

    /// The refresh in flight was planned against the old preferences, so a
    /// provider shown meanwhile was left out of it. The request must be
    /// queued, not dropped.
    @Test("a preference change during a refresh is applied when it ends")
    func preferenceChangeDuringRefreshIsQueued() async {
        let prefs = PrefsBox(ProviderDisplayPreferences(hidden: [.grok]))
        let hits = Hits()
        let s = store([
            StubProvider(vendorId: .claude, hits: hits, delay: .milliseconds(150)),
            StubProvider(vendorId: .grok, hits: hits),
        ], prefs: prefs, cacheTTL: 0)
        async let first: Void = s.load()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(s.isRefreshing)
        prefs.value.hidden = []
        await s.applyProviderPreferences()   // returns at once, queued
        await first
        #expect(s.snapshots.map(\.vendorId) == [.claude, .grok])
        #expect(s.isRefreshing == false)
    }

    /// No status is not "complete": a caller must be able to tell.
    @Test("the activity ingestion status is nil without a loader and the loader's answer with one")
    func ingestionStatus() async {
        let none = store([])
        #expect(await none.activityIngestionStatus() == nil)

        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { [] })
        let status = ActivityIngestionEngine.Status(hasCompletedCleanPass: true, lastPassIncomplete: false, isRunning: false)
        let withLoader = QuotaStore(manager: manager, activityStatusLoader: { status })
        #expect(await withLoader.activityIngestionStatus() == status)
    }

    /// The inline sparklines read through the store, narrowed to the series the
    /// visible rows actually carry — the loader must be hit with those ids and
    /// its points kept.
    @Test("a reload reads balance series for exactly the visible rows' series")
    func balanceSeriesAreLoadedForVisibleRows() async throws {
        let asked = AskedSeries()
        let seriesID = BalanceSeries.id(source: "deepseek", unit: .currency(code: "USD"))
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { [MoneyStubProvider(vendorId: .deepseek)] })
        let s = QuotaStore(
            manager: manager,
            balanceSeriesLoader: { _, _, _, ids in
                asked.record(ids)
                return [seriesID: [BalancePoint(measuredAt: Date(timeIntervalSince1970: 0), value: 42)]]
            })

        await s.load()

        #expect(asked.last == [seriesID])
        #expect(s.balanceSeries[seriesID]?.count == 1)
    }

    /// A failed read keeps the last good series rather than blanking every strip
    /// on a transient error.
    @Test("a failed balance read leaves the last good series in place")
    func failedBalanceReadKeepsLastGood() async throws {
        let seriesID = BalanceSeries.id(source: "deepseek", unit: .currency(code: "USD"))
        let box = SeriesResultBox([seriesID: [BalancePoint(measuredAt: Date(timeIntervalSince1970: 0), value: 42)]])
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { [MoneyStubProvider(vendorId: .deepseek)] })
        let s = QuotaStore(manager: manager, balanceSeriesLoader: { _, _, _, _ in box.result })

        await s.load()
        #expect(s.balanceSeries[seriesID]?.count == 1)

        box.result = nil
        await s.forceRefresh()
        #expect(s.balanceSeries[seriesID]?.count == 1)
    }

    /// `balancePoints` is the inspector's only source of balance history, and
    /// its three outcomes are the failure-vs-absence distinction the balance
    /// card is built on: nil for no loader or a failed read, `[]` for a read
    /// that answered without this series, points for history. None of them was
    /// covered.
    @Test("balancePoints tells a failed read apart from an absence of readings")
    func balancePointsDistinguishesFailureFromAbsence() async throws {
        let seriesID = BalanceSeries.id(source: "deepseek", unit: .currency(code: "USD"))
        let point = BalancePoint(measuredAt: Date(timeIntervalSince1970: 0), value: 42)
        let asked = AskedSeries()
        let box = SeriesResultBox([seriesID: [point]])
        let until = Date(timeIntervalSince1970: 100)
        let since = Date(timeIntervalSince1970: 0)

        // No loader injected at all: a failure to read, not an empty history.
        let unloaded = QuotaStore(manager: QuotaManager(providerFactory: { [] }))
        #expect(await unloaded.balancePoints(
            seriesId: seriesID, since: since, until: until, bucketSeconds: 3600) == nil)

        let store = QuotaStore(
            manager: QuotaManager(providerFactory: { [] }),
            balanceSeriesLoader: { _, _, _, ids in
                asked.record(ids)
                return box.result
            })

        #expect(await store.balancePoints(
            seriesId: seriesID, since: since, until: until, bucketSeconds: 3600) == [point])

        // The read itself failed: nil, so the card says so rather than drawing
        // an empty chart.
        box.result = nil
        #expect(await store.balancePoints(
            seriesId: seriesID, since: since, until: until, bucketSeconds: 3600) == nil)

        // Answered, but without this series: no readings in the window, which
        // is an absence and not a failure.
        box.result = ["other|currency:USD": [point]]
        #expect(await store.balancePoints(
            seriesId: seriesID, since: since, until: until, bucketSeconds: 3600) == [])

        // Narrowed to the one series asked for — never the empty list, which
        // `fetchBalanceSeries` reads as "no filter".
        #expect(asked.last == [seriesID])
    }
}

/// A money-only provider stub: no bars, so its row is its figure and it
/// contributes one balance series.
private struct MoneyStubProvider: QuotaProvider {
    let vendorId: VendorIdentifier
    let displayName = "Stub"
    let category: MetricCategory = .apiSpendAndCredits
    func fetchSnapshot() async throws -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName, category: category,
            metric: .currency(balance: 42, limit: nil, spent: nil, currencyCode: "USD"),
            status: .measured(.none), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            currencyBasis: .accountCredit)
    }
}

private final class AskedSeries: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func record(_ ids: [String]?) { lock.lock(); calls.append(ids ?? []); lock.unlock() }
    var last: [String]? { lock.lock(); defer { lock.unlock() }; return calls.last }
}

private final class SeriesResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: [String: [BalancePoint]]?
    init(_ result: [String: [BalancePoint]]?) { _result = result }
    var result: [String: [BalancePoint]]? {
        get { lock.lock(); defer { lock.unlock() }; return _result }
        set { lock.lock(); _result = newValue; lock.unlock() }
    }
}
