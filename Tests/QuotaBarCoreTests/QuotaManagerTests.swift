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

    @Test("minPollInterval does not throttle notConfigured/credentialRejected — a just-fixed key must retry immediately")
    func minPollIntervalIgnoresCredentialRecoverableFailures() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(
                cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2,
                minPollInterval: 3600
            ),
            providerFactory: {
                [StubProvider(vendorId: .claude, counter: counter, behavior: .throwError(.notConfigured))]
            }
        )
        let first = await manager.forceRefresh()
        #expect(first[.claude]?.status == .unavailable(.notConfigured))
        #expect(counter.value == 1)

        // notConfigured/credentialRejected are the two reasons a Settings
        // change can fix instantly, so they never sit under the floor — a
        // just-saved API key must be retried on the very next forceRefresh.
        let second = await manager.forceRefresh()
        #expect(second[.claude]?.status == .unavailable(.notConfigured))
        #expect(counter.value == 2)
    }

    @Test("minPollInterval throttles a vendor-side failure (rateLimited) exactly like a measured reading")
    func minPollIntervalThrottlesRateLimitedFailure() async {
        let counter = InvocationCounter()
        let noRetryAfter: Date? = nil
        let expectedStatus = ProviderStatus.unavailable(.rateLimited(retryAfter: noRetryAfter))
        let manager = QuotaManager(
            cachePolicy: CachePolicy(
                cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2,
                minPollInterval: 3600
            ),
            providerFactory: {
                [StubProvider(vendorId: .claude, counter: counter, behavior: .throwError(ProviderError(.rateLimited(retryAfter: noRetryAfter))))]
            }
        )
        let first = await manager.forceRefresh()
        #expect(first[.claude]?.status == expectedStatus)
        #expect(counter.value == 1)

        // rateLimited is the vendor's own signal to back off — mashing
        // refresh must not re-hit it every cycle just because the last
        // result wasn't a successful measurement. This is the exact
        // "hammering a paid provider" scenario minPollInterval exists to
        // stop, and the one case where the vendor itself asked to be left
        // alone.
        let second = await manager.forceRefresh()
        #expect(second[.claude]?.status == expectedStatus)
        #expect(counter.value == 1)
    }

    @Test("minPollInterval re-arms during an outage instead of re-hitting a failing vendor every cycle")
    func minPollIntervalReArmsDuringOutage() async {
        // Two independent counters: `factoryCallCount` only decides which
        // behavior providerFactory hands back next; `fetchCounter` is what
        // StubProvider bumps inside fetchSnapshot() and is the one that
        // actually proves whether the vendor was hit over the network.
        let factoryCallCount = InvocationCounter()
        let fetchCounter = InvocationCounter()
        // A short floor so the test can genuinely let it expire once (via a
        // real sleep) before the outage, then prove the failed attempt
        // re-arms a fresh window rather than leaving fetchedAt frozen at
        // the last success.
        let manager = QuotaManager(
            cachePolicy: CachePolicy(
                cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2,
                minPollInterval: 0.05
            ),
            providerFactory: {
                let call = factoryCallCount.increment()
                if call == 1 {
                    return [StubProvider(vendorId: .claude, counter: fetchCounter, behavior: .succeed(.warning))]
                } else {
                    return [StubProvider(vendorId: .claude, counter: fetchCounter, behavior: .throwError(.badResponse))]
                }
            }
        )
        let first = await manager.forceRefresh()
        #expect(first[.claude]?.status == .measured(.warning))
        #expect(fetchCounter.value == 1)

        // Let the floor expire before the vendor starts failing.
        try? await Task.sleep(for: .seconds(0.1))

        let second = await manager.forceRefresh()
        #expect(second[.claude]?.status == .measured(.warning)) // stale reading preserved
        #expect(fetchCounter.value == 2)

        // Immediately re-refresh, well within a fresh floor window measured
        // from the failed attempt above. Without re-arming fetchedAt on
        // failure, this would incorrectly re-hit the vendor a third time.
        let third = await manager.forceRefresh()
        #expect(third[.claude]?.status == .measured(.warning))
        #expect(fetchCounter.value == 2) // still 2 — the floor re-armed on the failed attempt above
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
