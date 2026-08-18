import Testing
import Foundation
@testable import QuotaBarCore

// MARK: - Test doubles

/// Counts invocations without touching a wall clock — safe for asserting
/// "fetched exactly once" style expectations.
private actor InvocationCounter {
    private(set) var value = 0
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

/// A `QuotaProvider` whose entire behaviour is dictated by the test: succeed
/// with a given urgency, throw a given error, or hang for a given duration
/// (to be cut off by `QuotaManager`'s per-provider deadline).
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
        await counter?.increment()
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

// MARK: - Suite

struct QuotaManagerTests {

    @Test("a throwing provider does not prevent its peers from returning")
    func throwingProviderDoesNotBlockPeers() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                [
                    StubProvider(vendorId: .claude, behavior: .throwError(.badResponse)),
                    StubProvider(vendorId: .gemini, behavior: .succeed(.none)),
                ]
            }
        )
        let results = await manager.forceRefresh()
        #expect(results[.claude]?.status == .unavailable(.badResponse))
        #expect(results[.gemini]?.status == .measured(.none))
    }

    @Test("a hanging provider is cut off by the per-provider deadline")
    func hangingProviderTimesOut() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 0.3),
            providerFactory: {
                [StubProvider(vendorId: .claude, behavior: .hang(seconds: 5))]
            }
        )
        let results = await manager.forceRefresh()
        #expect(results[.claude]?.status == .unavailable(.timedOut))
    }

    @Test("a fresh cache short-circuits: two refresh() calls invoke the factory's providers once")
    func freshCacheShortCircuitsSecondRefresh() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                [StubProvider(vendorId: .claude, counter: counter, behavior: .succeed(.none))]
            }
        )
        _ = await manager.refresh()
        _ = await manager.refresh()
        let count = await counter.value
        #expect(count == 1)
    }

    @Test("forceRefresh() bypasses the cache and fetches again")
    func forceRefreshBypassesCache() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                [StubProvider(vendorId: .claude, counter: counter, behavior: .succeed(.none))]
            }
        )
        _ = await manager.refresh()
        _ = await manager.forceRefresh()
        let count = await counter.value
        #expect(count == 2)
    }

    @Test("concurrent refresh() calls collapse into a single fetch")
    func concurrentRefreshesCollapseIntoOneFetch() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                // A short hang widens the window so all three refresh() calls
                // are guaranteed to observe the in-flight fetch and join it,
                // rather than possibly racing a fast completion.
                [StubProvider(vendorId: .claude, counter: counter, behavior: .hang(seconds: 0.2))]
            }
        )
        async let a = manager.refresh()
        async let b = manager.refresh()
        async let c = manager.refresh()
        _ = await (a, b, c)
        let count = await counter.value
        #expect(count == 1)
    }

    @Test("isCacheFresh starts stale before any fetch")
    func cacheStartsStale() async {
        let manager = QuotaManager(
            cachePolicy: .default,
            providerFactory: { [] }
        )
        let fresh = await manager.isCacheFresh()
        #expect(fresh == false)
    }

    @Test("sortedSnapshots returns entries in canonical provider order")
    func sortedSnapshotsCanonicalOrder() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                [
                    StubProvider(vendorId: .githubGraphql, behavior: .succeed(.none)),
                    StubProvider(vendorId: .claude, behavior: .succeed(.none)),
                    StubProvider(vendorId: .openrouter, behavior: .succeed(.none)),
                ]
            }
        )
        _ = await manager.forceRefresh()
        let sorted = await manager.sortedSnapshots()
        #expect(sorted.map(\.vendorId) == [.claude, .openrouter, .githubGraphql])
    }

    @Test("worstUrgency reflects the highest urgency among cached snapshots")
    func worstUrgencyReflectsCache() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                [
                    StubProvider(vendorId: .claude, behavior: .succeed(.warning)),
                    StubProvider(vendorId: .gemini, behavior: .succeed(.critical)),
                ]
            }
        )
        _ = await manager.forceRefresh()
        let worst = await manager.worstUrgency()
        #expect(worst == .critical)
    }
}
