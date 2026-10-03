import Testing
import Foundation
@testable import QuotaBarCore

/// Holds the preferences a `QuotaManager` reads on each poll, so a test can
/// change them between polls without touching the real preference store.
private final class PreferenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ProviderDisplayPreferences
    init(_ value: ProviderDisplayPreferences) { _value = value }
    var value: ProviderDisplayPreferences {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [VendorIdentifier: Int] = [:]
    func hit(_ vendor: VendorIdentifier) { lock.lock(); counts[vendor, default: 0] += 1; lock.unlock() }
    func count(_ vendor: VendorIdentifier) -> Int { lock.lock(); defer { lock.unlock() }; return counts[vendor] ?? 0 }
}

private struct Provider: QuotaProvider {
    let vendorId: VendorIdentifier
    let displayName = "Stub"
    let category: MetricCategory = .aiSubscriptions
    let counter: Counter
    var used: Double = 0.1
    var resetsInHours: Double = 10

    func fetchSnapshot() async throws -> QuotaSnapshot {
        counter.hit(vendorId)
        let reset = Date().addingTimeInterval(resetsInHours * 3600)
        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category,
            metric: .percentage(usedFraction: used, displayDetails: nil),
            status: .measured(.none), resetsAt: reset, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: DualBarMetrics(
                primaryFraction: used, label: "WK",
                resetsAt: reset, windowLength: QuotaWindow.week))
    }
}

@Suite("Provider visibility and order")
struct ProviderVisibilityTests {

    private func manager(
        _ providers: [Provider], box: PreferenceBox, minPoll: TimeInterval = 0
    ) -> QuotaManager {
        QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: minPoll),
            providerFactory: { providers },
            displayPreferences: { box.value })
    }

    @Test("a hidden provider is never polled and never appears")
    func hiddenIsNotPolled() async {
        let counter = Counter()
        let box = PreferenceBox(ProviderDisplayPreferences(hidden: [.grok]))
        let m = manager([Provider(vendorId: .claude, counter: counter), Provider(vendorId: .grok, counter: counter)], box: box)
        let results = await m.forceRefresh()
        #expect(counter.count(.grok) == 0)
        #expect(counter.count(.claude) == 1)
        #expect(results[.grok] == nil)
        #expect(await m.sortedSnapshots().map(\.vendorId) == [.claude])
    }

    @Test("hiding a provider after a good poll purges it")
    func hidingPurgesTheCache() async {
        let counter = Counter()
        let box = PreferenceBox(.default)
        let m = manager([Provider(vendorId: .claude, counter: counter), Provider(vendorId: .grok, counter: counter)], box: box)
        _ = await m.forceRefresh()
        #expect(await m.sortedSnapshots().count == 2)

        box.value.hidden = [.grok]
        // Dropped on the next read, before any poll...
        #expect(await m.sortedSnapshots().map(\.vendorId) == [.claude])
        // ...and out of the urgency summary and the cache after one.
        _ = await m.forceRefresh()
        #expect(await m.cachedSnapshots()[.grok] == nil)
    }

    /// Without the purge, a vendor shown again would be served from under
    /// the 30s poll floor and look stale or missing for half a minute.
    @Test("a provider shown again is fetched immediately, inside the poll floor")
    func unhidingFetchesAtOnce() async {
        let counter = Counter()
        let box = PreferenceBox(ProviderDisplayPreferences(hidden: [.grok]))
        let m = manager([Provider(vendorId: .claude, counter: counter), Provider(vendorId: .grok, counter: counter)],
                        box: box, minPoll: 3600)
        _ = await m.forceRefresh()
        box.value.hidden = []
        _ = await m.forceRefresh()
        #expect(counter.count(.grok) == 1)
        #expect(await m.sortedSnapshots().count == 2)
    }

    @Test("custom order is the user's, verbatim")
    func customOrderIsVerbatim() async {
        let counter = Counter()
        // Claude resets sooner than Grok, so automatic would put it first.
        let providers = [
            Provider(vendorId: .claude, counter: counter, resetsInHours: 5),
            Provider(vendorId: .grok, counter: counter, resetsInHours: 100),
        ]
        let box = PreferenceBox(ProviderDisplayPreferences(ordering: .custom, order: [.grok, .claude]))
        let m = manager(providers, box: box)
        _ = await m.forceRefresh()
        #expect(await m.sortedSnapshots().map(\.vendorId) == [.grok, .claude])

        box.value.ordering = .automatic
        #expect(await m.sortedSnapshots().map(\.vendorId) == [.claude, .grok])
    }

    @Test("a custom order can put a spent vendor first")
    func customOrderIgnoresExhaustion() async {
        let counter = Counter()
        let providers = [
            Provider(vendorId: .claude, counter: counter, used: 1.0),
            Provider(vendorId: .grok, counter: counter),
        ]
        let box = PreferenceBox(ProviderDisplayPreferences(ordering: .custom, order: [.claude, .grok]))
        let m = manager(providers, box: box)
        _ = await m.forceRefresh()
        #expect(await m.sortedSnapshots().map(\.vendorId) == [.claude, .grok])
        box.value.ordering = .automatic
        #expect(await m.sortedSnapshots().map(\.vendorId) == [.grok, .claude])
    }
}
