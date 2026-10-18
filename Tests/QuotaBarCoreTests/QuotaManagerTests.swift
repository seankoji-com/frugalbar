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
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: {
                [
                    StubProvider(vendorId: .claude, behavior: .throwError(.badResponse)),
                    StubProvider(vendorId: .gemini, behavior: .succeed(.none)),
                ]
            }
        )
        let results = await manager.forceRefresh()
        #expect(results[VendorIdentifier.claude.rawValue]?.status == .unavailable(.badResponse))
        #expect(results[VendorIdentifier.gemini.rawValue]?.status == .measured(.none))
    }

    @Test("a hanging provider is cut off by the per-provider deadline")
    func hangingProviderTimesOut() async {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 0.3, minPollInterval: 0),
            providerFactory: {
                [StubProvider(vendorId: .claude, behavior: .hang(seconds: 5))]
            }
        )
        let results = await manager.forceRefresh()
        #expect(results[VendorIdentifier.claude.rawValue]?.status == .unavailable(.timedOut))
    }

    @Test("a fresh cache short-circuits: two refresh() calls invoke the factory's providers once")
    func freshCacheShortCircuitsSecondRefresh() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
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
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
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
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
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
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
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
            cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
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

    @Test("a second ⟳ inside the poll floor is served from cache, not re-hit")
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
        #expect(first[VendorIdentifier.claude.rawValue]?.status == .measured(.none))
        #expect(counter.value == 1)

        // cacheTTL is 0, so a forced refresh would normally re-fetch — but the
        // user already forced one well inside the one-hour floor, so mashing
        // the button re-serves the cache rather than hammering the vendor.
        let second = await manager.forceRefresh()
        #expect(second[VendorIdentifier.claude.rawValue]?.status == .measured(.none))
        #expect(counter.value == 1)
    }

    /// The reported bug. Opening the popover runs a load; the user then presses
    /// ⟳. That click used to be measured against the *automatic* fetch the
    /// popover had just made, so it sat inside the floor and issued no request
    /// at all: the icon spun, the rows redrew byte-identical, and the button
    /// looked dead. A poll the user did not ask for must not swallow the click
    /// they did — while a second ⟳ of their own still must.
    @Test("an automatic poll does not throttle the user's own refresh, but two ⟳ in a row do")
    func automaticPollDoesNotThrottleAForcedRefresh() async {
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
        _ = await manager.refresh()
        #expect(counter.value == 1)

        // The user asks. Whatever an automatic poll did a moment ago, this is a
        // fresh request.
        _ = await manager.forceRefresh()
        #expect(counter.value == 2)

        // The user asks again immediately: this is the mashing the floor is for.
        _ = await manager.forceRefresh()
        #expect(counter.value == 2)
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
        #expect(first[VendorIdentifier.claude.rawValue]?.status == .unavailable(.notConfigured))
        #expect(counter.value == 1)

        // notConfigured/credentialRejected are the two reasons a Settings
        // change can fix instantly, so they never sit under the floor — a
        // just-saved API key must be retried on the very next forceRefresh.
        let second = await manager.forceRefresh()
        #expect(second[VendorIdentifier.claude.rawValue]?.status == .unavailable(.notConfigured))
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
        #expect(first[VendorIdentifier.claude.rawValue]?.status == expectedStatus)
        #expect(counter.value == 1)

        // rateLimited is the vendor's own signal to back off — mashing
        // refresh must not re-hit it every cycle just because the last
        // result wasn't a successful measurement. This is the exact
        // "hammering a paid provider" scenario minPollInterval exists to
        // stop, and the one case where the vendor itself asked to be left
        // alone.
        let second = await manager.forceRefresh()
        #expect(second[VendorIdentifier.claude.rawValue]?.status == expectedStatus)
        #expect(counter.value == 1)
    }

    /// A 429 that carries `Retry-After` is an instruction, and the poll loop is
    /// the thing it is addressed to. Anthropic answers the usage endpoint with
    /// `Retry-After: 2377`, so a 2-minute automatic poll spends the next 40
    /// minutes re-asking a vendor that already said no — on a budget the
    /// account shares with Claude Code itself. The user's ⟳ is exempt: a
    /// person asking is not the poll loop.
    @Test("a vendor's Retry-After gates the automatic poll, not the user's ⟳")
    func vendorRetryAfterGatesAutomaticPollOnly() async {
        let counter = InvocationCounter()
        let retryAt = Date().addingTimeInterval(600)
        let manager = QuotaManager(
            cachePolicy: CachePolicy(
                cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2,
                minPollInterval: 0
            ),
            providerFactory: {
                [StubProvider(
                    vendorId: .claude, counter: counter,
                    behavior: .throwError(ProviderError(.rateLimited(retryAfter: retryAt))))]
            }
        )
        _ = await manager.forceRefresh()
        #expect(counter.value == 1)

        // minPollInterval is 0 here on purpose: the vendor's own window is what
        // holds the poll back, not the floor.
        _ = await manager.refresh()
        #expect(counter.value == 1)

        // The user asks anyway, and is answered by the vendor rather than by
        // the cache — the dead ⟳ of #90 stays dead-free.
        _ = await manager.forceRefresh()
        #expect(counter.value == 2)
    }

    /// The gate is the vendor's window, not a permanent mute: once the instant
    /// it named has passed, automatic polling resumes.
    @Test("an elapsed Retry-After does not hold the automatic poll back")
    func elapsedVendorRetryAfterDoesNotThrottle() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(
                cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2,
                minPollInterval: 0
            ),
            providerFactory: {
                [StubProvider(
                    vendorId: .claude, counter: counter,
                    behavior: .throwError(ProviderError(
                        .rateLimited(retryAfter: Date().addingTimeInterval(-1)))))]
            }
        )
        _ = await manager.refresh()
        #expect(counter.value == 1)
        _ = await manager.refresh()
        #expect(counter.value == 2)
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
        #expect(first[VendorIdentifier.claude.rawValue]?.status == .measured(.warning))
        #expect(fetchCounter.value == 1)

        // Let the floor expire before the vendor starts failing.
        try? await Task.sleep(for: .seconds(0.1))

        let second = await manager.forceRefresh()
        #expect(second[VendorIdentifier.claude.rawValue]?.status == .measured(.warning)) // stale reading preserved
        #expect(fetchCounter.value == 2)

        // Immediately re-refresh, well within a fresh floor window measured
        // from the failed attempt above. Without re-arming fetchedAt on
        // failure, this would incorrectly re-hit the vendor a third time.
        let third = await manager.forceRefresh()
        #expect(third[VendorIdentifier.claude.rawValue]?.status == .measured(.warning))
        #expect(fetchCounter.value == 2) // still 2 — the floor re-armed on the failed attempt above
    }

    @Test("transient provider error preserves existing measured cache entry")
    func transientErrorPreservesMeasuredCache() async {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
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
        #expect(first[VendorIdentifier.claude.rawValue]?.status == .measured(.warning))

        let second = await manager.forceRefresh()
        #expect(second[VendorIdentifier.claude.rawValue]?.status == .measured(.warning))
    }

    /// Regression: retention replaced the whole cached snapshot, `status` and
    /// `lastUpdated` included, so a failed poll left no trace anywhere. The row
    /// drew hour-old figures as the provider's state now, the footer's "oldest
    /// reading" froze for the length of the outage (the reported "stuck on
    /// 57m"), and nothing could tell that the poll had failed at all.
    /// Proven red by dropping the `retained.staleReading = ...` assignment.
    @Test("a failed poll keeps the figures, marks them stale, and the next success clears the mark")
    func failedPollMarksTheReadingStale() async throws {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: {
                switch counter.increment() {
                case 1:  return [StubProvider(vendorId: .claude, behavior: .succeed(.warning))]
                case 2:  return [StubProvider(vendorId: .claude, behavior: .throwError(ProviderError(.offline)))]
                default: return [StubProvider(vendorId: .claude, behavior: .succeed(.none))]
                }
            }
        )

        let first = await manager.forceRefresh()
        let measured = try #require(first[VendorIdentifier.claude.rawValue])
        let figuresAt = measured.lastUpdated
        #expect(measured.staleReading == nil)
        #expect(measured.consumptionFraction != nil)

        let second = await manager.forceRefresh()
        let stale = try #require(second[VendorIdentifier.claude.rawValue])
        // The last known figures survive, status included — an unreadable
        // provider must never take over the icon from a real reading...
        #expect(stale.status == .measured(.warning))
        #expect(stale.consumptionFraction == measured.consumptionFraction)
        #expect(stale.lastUpdated == figuresAt)
        // ...but the failure is carried with them, so no surface can present
        // them as this poll's reading.
        let failure = try #require(stale.staleReading)
        #expect(failure.reason == .offline)
        #expect(failure.at >= figuresAt)

        // One stale provider, no unreadable ones, and the quota pressure it
        // last reported still drives the icon.
        let during = SystemHealthSummary.compute(from: Array(second.values))
        #expect(during.staleCount == 1)
        #expect(during.unavailableCount == 0)
        #expect(during.worstUrgency == .warning)
        // The retained reading keeps its original age, so the age is
        // a fact about a provider rather than about the app.
        #expect(during.oldestReading == figuresAt)

        let third = await manager.forceRefresh()
        let recovered = try #require(third[VendorIdentifier.claude.rawValue])
        #expect(recovered.staleReading == nil)
        #expect(recovered.status == .measured(.none))
        #expect(SystemHealthSummary.compute(from: Array(third.values)).staleCount == 0)
    }

    /// Two failures in a row report the newest reason. Retention exists to keep
    /// *figures*, and a placeholder carries none, so freezing the first failure's
    /// reason would leave a provider whose key was rejected reading "Not
    /// configured" for as long as the outage lasted.
    @Test("consecutive failed polls report the newest reason, not the first")
    func consecutiveFailuresReportTheNewestReason() async throws {
        let counter = InvocationCounter()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: {
                switch counter.increment() {
                case 1:  return [StubProvider(vendorId: .claude, behavior: .throwError(.notConfigured))]
                default: return [StubProvider(vendorId: .claude, behavior: .throwError(ProviderError(.offline)))]
                }
            }
        )
        _ = await manager.forceRefresh()
        let second = await manager.forceRefresh()
        let snapshot = try #require(second[VendorIdentifier.claude.rawValue])
        #expect(snapshot.status == .unavailable(.offline))
        // Nothing was carried over, so there is no reading to call stale.
        #expect(snapshot.staleReading == nil)
    }
}
