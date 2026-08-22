import Testing
import Foundation
@testable import QuotaBarCore

/// A QuotaProvider whose behaviour is dictated by the test.
private struct StubProvider: QuotaProvider {
    enum Behavior: Sendable {
        case succeed(Urgency)
        case throwError(ProviderError)
        case hang(seconds: TimeInterval)
    }

    let vendorId: VendorIdentifier
    let displayName: String = "Stub"
    let category: MetricCategory = .aiSubscriptions
    var counter: InvocationCounter?
    let behavior: Behavior

    func fetchSnapshot() async throws -> QuotaSnapshot {
        counter?.increment()
        switch behavior {
        case .succeed(let urgency):
            return QuotaSnapshot(
                id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
                category: category,
                metric: .percentage(usedFraction: 0.1, displayDetails: nil),
                status: .measured(urgency),
                resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil
            )
        case .throwError(let error):
            throw error
        case .hang(let seconds):
            try await Task.sleep(for: .seconds(seconds))
            return QuotaSnapshot(
                id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
                category: category,
                metric: .percentage(usedFraction: 0, displayDetails: nil),
                status: .measured(.none),
                resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil
            )
        }
    }
}

/// Thread-safe invocation counter.
private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
    }
}

@Suite("QuotaManager — extended")
struct QuotaManagerExtendedTests {

    // MARK: - cachedSnapshots

    @Test("cachedSnapshots returns empty dict before any fetch")
    func cachedSnapshotsEmptyInitially() async {
        let manager = QuotaManager(
            cachePolicy: .default,
            providerFactory: { [] }
        )
        let snaps = await manager.cachedSnapshots()
        #expect(snaps.isEmpty)
    }

    @Test("cachedSnapshots returns values after forceRefresh")
    func cachedSnapshotsAfterFetch() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                [StubProvider(vendorId: .claude, behavior: .succeed(.none))]
            }
        )
        _ = await manager.forceRefresh()
        let snaps = await manager.cachedSnapshots()
        #expect(snaps.count == 1)
        #expect(snaps[.claude] != nil)
    }

    // MARK: - Empty provider list

    @Test("forceRefresh with no providers returns empty and cache is fresh")
    func emptyProviderList() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: { [] }
        )
        let results = await manager.forceRefresh()
        #expect(results.isEmpty)
        let fresh = await manager.isCacheFresh()
        #expect(fresh)
    }

    @Test("refresh with no providers returns empty dict")
    func emptyProviderListRefresh() async {
        let manager = QuotaManager(
            cachePolicy: .default,
            providerFactory: { [] }
        )
        let results = await manager.refresh()
        #expect(results.isEmpty)
    }

    // MARK: - worstUrgency

    @Test("worstUrgency is .none when cache is empty")
    func worstUrgencyEmpty() async {
        let manager = QuotaManager(
            cachePolicy: .default,
            providerFactory: { [] }
        )
        let worst = await manager.worstUrgency()
        #expect(worst == .none)
    }

    @Test("worstUrgency reflects mixed statuses")
    func worstUrgencyMixed() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                [
                    StubProvider(vendorId: .claude, behavior: .succeed(.none)),
                    StubProvider(vendorId: .gemini, behavior: .succeed(.warning)),
                ]
            }
        )
        _ = await manager.forceRefresh()
        #expect(await manager.worstUrgency() == .warning)
    }

    // MARK: - All providers unavailable

    @Test("all providers unavailable: worstUrgency is .none, cache has the TTL-based freshness")
    func allUnavailable() async {
        let manager = QuotaManager(
            // Use a non-zero TTL so cache IS fresh after fetch
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                [StubProvider(vendorId: .claude, behavior: .throwError(.badResponse))]
            }
        )
        let results = await manager.forceRefresh()
        #expect(results[.claude]?.status.confidence == .unavailable)
        #expect(await manager.worstUrgency() == .none)
        #expect(await manager.isCacheFresh())  // non-zero TTL means fresh after fetch
    }

    // MARK: - Provider not in results (timeout)

    @Test("a provider that times out produces .timedOut and does not crash")
    func providerTimesOut() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 0.1),
            providerFactory: {
                [StubProvider(vendorId: .claude, behavior: .hang(seconds: 5))]
            }
        )
        let results = await manager.forceRefresh()
        #expect(results[.claude]?.status == .unavailable(.timedOut))
    }

    // MARK: - Multiple failures

    @Test("all providers throwing errors results in all unavailable")
    func allThrow() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 1),
            providerFactory: {
                [
                    StubProvider(vendorId: .claude, behavior: .throwError(.badResponse)),
                    StubProvider(vendorId: .gemini, behavior: .throwError(.credentialRejected)),
                    StubProvider(vendorId: .opencode, behavior: .throwError(.notConfigured)),
                ]
            }
        )
        let results = await manager.forceRefresh()
        #expect(results.count == 3)
        for (vendor, snap) in results {
            #expect(snap.status.confidence == .unavailable,
                    "\(vendor) should be unavailable, got \(snap.status)")
        }
    }

    // MARK: - Transient error preserves stale data

    @Test("transient error preserves previously measured data when TTL is zero")
    func transientErrorPreservesMeasuredData() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                let call = counter.increment()
                if call == 1 {
                    return [StubProvider(vendorId: .openrouter, behavior: .succeed(.warning))]
                } else {
                    return [StubProvider(vendorId: .openrouter, behavior: .throwError(.badResponse))]
                }
            }
        )
        // First fetch: success with warning
        let first = await manager.forceRefresh()
        #expect(first[.openrouter]?.status == .measured(.warning))
        #expect(first[.openrouter]?.consumptionFraction != nil)

        // Second fetch: failure — should preserve the previous measured entry
        let second = await manager.forceRefresh()
        #expect(second[.openrouter]?.status == .measured(.warning),
                "transient error should preserve measured data")
        #expect(second[.openrouter]?.consumptionFraction != nil)
    }

    // MARK: - sortedSnapshots details

    @Test("sortedSnapshots includes all vendors in canonical order")
    func sortedSnapshotsFullOrder() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                VendorIdentifier.allCases.map {
                    StubProvider(vendorId: $0, behavior: .succeed(.none))
                }
            }
        )
        _ = await manager.forceRefresh()
        let sorted = await manager.sortedSnapshots()
        #expect(sorted.count == VendorIdentifier.allCases.count)
        #expect(sorted[0].vendorId == .claude)

        #expect(sorted[1].vendorId == .openai)
        #expect(sorted[2].vendorId == .gemini)
        #expect(sorted[3].vendorId == .copilot)
        #expect(sorted[4].vendorId == .opencode)
        #expect(sorted[5].vendorId == .openrouter)
        #expect(sorted[6].vendorId == .githubRest)
        #expect(sorted[7].vendorId == .githubGraphql)

    }

    // MARK: - unavailableSnapshot

    @Test("unavailableSnapshot has subscription metric with headline as tierName")
    func unavailableSnapshotFormat() async {
        let provider = StubProvider(vendorId: .claude, behavior: .succeed(.none))
        let snap = QuotaManager.unavailableSnapshot(for: provider, reason: .notConfigured)
        #expect(snap.status == .unavailable(.notConfigured))
        #expect(snap.consumptionFraction == nil)
        guard case .subscription(let tier, _) = snap.metric else {
            Issue.record("expected .subscription metric")
            return
        }
        #expect(tier == "Not configured")
    }

    @Test("unavailableSnapshot auxiliaryInfo is the reason's remedy")
    func unavailableSnapshotRemedy() async {
        let provider = StubProvider(vendorId: .gemini, behavior: .succeed(.none))
        let snap = QuotaManager.unavailableSnapshot(for: provider, reason: .offline)
        #expect(snap.auxiliaryInfo == "Check your connection")
    }

    // MARK: - isCacheFresh

    @Test("isCacheFresh returns false before first fetch even with default TTL")
    func isCacheFreshFalseBeforeFirstFetch() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 60, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: { [] }
        )
        #expect(await manager.isCacheFresh() == false)
    }

    @Test("isCacheFresh returns true after forceRefresh")
    func isCacheFreshTrueAfterFetch() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                [StubProvider(vendorId: .claude, behavior: .succeed(.none))]
            }
        )
        _ = await manager.forceRefresh()
        #expect(await manager.isCacheFresh())
    }
}
