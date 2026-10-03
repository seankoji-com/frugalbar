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

private struct StubProvider: QuotaProvider {
    let vendorId: VendorIdentifier
    let displayName = "Stub"
    let category: MetricCategory = .aiSubscriptions
    let hits: Hits
    var status: ProviderStatus = .healthy
    var delay: Duration = .zero

    func fetchSnapshot() async throws -> QuotaSnapshot {
        hits.hit(vendorId)
        if delay > .zero { try await Task.sleep(for: delay) }
        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category,
            metric: .percentage(usedFraction: 0.1, displayDetails: nil),
            status: status, resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil)
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

    @Test("load populates snapshots, summary and advice")
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

    @Test("a refresh requested during a refresh is dropped, not doubled")
    func overlappingRefreshesCollapse() async {
        let hits = Hits()
        let s = store([StubProvider(vendorId: .claude, hits: hits, delay: .milliseconds(150))], cacheTTL: 0)
        async let first: Void = s.load()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(s.isRefreshing)
        await s.forceRefresh()   // returns at once: one is already in flight
        await first
        #expect(hits.count(.claude) == 1)
        #expect(s.isRefreshing == false)
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
}
