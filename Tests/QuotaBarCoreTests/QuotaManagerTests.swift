import Testing
import Foundation
@testable import QuotaBarCore

// MARK: - Test doubles

/// Counts invocations without touching a wall clock — safe for asserting
/// "fetched exactly once" style expectations.
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
        let count = counter.value
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
        let count = counter.value
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
        let count = counter.value
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

    @Test("minPollInterval throttles a vendor even on forceRefresh, serving its cached snapshot")
    func minPollIntervalThrottlesForceRefresh() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(
                cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2,
                minPollInterval: 3600
            ),
            providerFactory: {
                [StubProvider(vendorId: .claude, counter: counter, behavior: .succeed(.none))]
            }
        )
        let first = await manager.forceRefresh()
        #expect(first[.claude]?.status == .measured(.none))
        #expect(counter.value == 1)

        // cacheTTL is 0, so refresh()/forceRefresh() would normally re-fetch —
        // but the vendor was just fetched well inside the one-hour poll
        // floor, so it must be served from cache rather than re-hit.
        let second = await manager.forceRefresh()
        #expect(second[.claude]?.status == .measured(.none))
        #expect(counter.value == 1)
    }

    @Test("minPollInterval does not throttle a vendor whose only cached snapshot was never measured")
    func minPollIntervalIgnoresUnmeasuredCache() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(
                cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2,
                minPollInterval: 3600
            ),
            providerFactory: {
                [StubProvider(vendorId: .claude, counter: counter, behavior: .throwError(.badResponse))]
            }
        )
        let first = await manager.forceRefresh()
        #expect(first[.claude]?.status == .unavailable(.badResponse))
        #expect(counter.value == 1)

        // The floor exists to stop hammering a vendor with a *real* reading
        // to protect — a cached `.unavailable` snapshot has nothing like
        // that to protect, so a just-fixed credential must be retried
        // immediately rather than waiting out the one-hour floor.
        let second = await manager.forceRefresh()
        #expect(second[.claude]?.status == .unavailable(.badResponse))
        #expect(counter.value == 2)
    }

    @Test("transient provider error preserves existing measured cache entry")
    func transientErrorPreservesMeasuredCache() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2),
            providerFactory: {
                let call = counter.increment()
                if call == 1 {
                    return [StubProvider(vendorId: .claude, behavior: .succeed(.warning))]
                } else {
                    return [StubProvider(vendorId: .claude, behavior: .throwError(.badResponse))]
                }
            }
        )
        let first = await manager.forceRefresh()
        #expect(first[.claude]?.status == .measured(.warning))

        let second = await manager.forceRefresh()
        #expect(second[.claude]?.status == .measured(.warning))
    }
}
