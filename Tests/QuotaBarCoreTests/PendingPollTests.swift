import Testing
import Foundation
@testable import QuotaBarCore

/// A watcher must not move its durable checkpoint until the engine has
/// recorded the events derived from it. A checkpoint written first and an
/// insert that then failed (or a crash in between) lost those events for
/// good: the next poll diffed against the moved baseline and never derived
/// them again. The account-model watcher is the one with a checkpoint (the
/// models it has seen); status pages and reset trackers are keyed on the
/// vendor's own ids and need none.
@Suite("PendingPoll checkpoint ordering")
struct PendingPollTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the model watcher's prepare writes nothing until commit")
    func modelPrepareDefersWrite() async throws {
        let store = makeIsolatedEventStore()
        let models = Box([AccountModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol")])
        let watcher = AccountModelWatcher(vendors: [.openai]) { _ in models.value }

        let seed = await watcher.prepare(store: store, vendors: [.openai], now: now)
        #expect(seed.fetched)
        #expect(seed.events.isEmpty)   // first list seeds silently
        #expect(try await store.accountModels(vendor: .openai).isEmpty)
        try await seed.commit()
        #expect(try await store.accountModels(vendor: .openai).count == 1)

        models.value.append(AccountModel(id: "gpt-6.2", name: "GPT-6.2"))
        let pending = await watcher.prepare(store: store, vendors: [.openai], now: now)
        #expect(pending.events.map(\.title) == ["GPT-6.2 now available in Codex"])

        // Re-preparing before commit derives the same event again — which is
        // exactly what lets a failed record be retried.
        let again = await watcher.prepare(store: store, vendors: [.openai], now: now)
        #expect(again.events.map(\.id) == pending.events.map(\.id))

        try await pending.commit()
        let after = await watcher.prepare(store: store, vendors: [.openai], now: now)
        #expect(after.events.isEmpty)
    }

    @Test("an unreadable or empty list reports fetched == false and commits nothing")
    func nothingReachable() async throws {
        let store = makeIsolatedEventStore()
        for answer in [nil, []] as [[AccountModel]?] {
            let watcher = AccountModelWatcher(vendors: [.openai]) { _ in answer }
            let pending = await watcher.prepare(store: store, vendors: [.openai], now: now)
            #expect(!pending.fetched)
            #expect(pending.events.isEmpty)
            try await pending.commit()
            #expect(try await store.accountModels(vendor: .openai).isEmpty)
        }
    }

    @Test("a vendor the user has not configured is never listed")
    func unconfiguredVendorSkipped() async {
        let log = FetchLog()
        let watcher = AccountModelWatcher(vendors: [.openai, .claude]) { vendor in
            log.hit(vendor.rawValue)
            return [AccountModel(id: "m")]
        }
        _ = await watcher.prepare(store: makeIsolatedEventStore(), vendors: [.claude], now: now)
        #expect(log.count("openai") == 0)
        #expect(log.count("claude") == 1)
    }

    @Test("the engine retries a source sooner when nothing was reachable")
    func engineRetriesAfterTotalFailure() async throws {
        let store = makeIsolatedEventStore()
        let log = FetchLog()
        let reachable = Box(false)
        let engine = AIEventEngine(
            store: store,
            trackerFetcher: { _ in log.hit("tracker"); return nil },
            statusFetcher: { _ in log.hit("status"); return nil },
            modelLister: { _ in
                log.hit("models")
                return reachable.value ? [AccountModel(id: "m")] : nil
            },
            modelVendors: [.openai],
            isTrackingEnabled: { true }
        )

        _ = await engine.pollExternalSources(now: now, vendors: [.openai])
        #expect(log.count("models") == 1)

        // Still inside the retry window: no fetch.
        _ = await engine.pollExternalSources(
            now: now.addingTimeInterval(AIEventEngine.failedPollRetryInterval - 60), vendors: [.openai])
        #expect(log.count("models") == 1)

        // Past it, well before the full interval: fetched again.
        reachable.value = true
        _ = await engine.pollExternalSources(
            now: now.addingTimeInterval(AIEventEngine.failedPollRetryInterval + 60), vendors: [.openai])
        #expect(log.count("models") == 2)

        // Now on the normal cadence.
        _ = await engine.pollExternalSources(
            now: now.addingTimeInterval(AIEventEngine.failedPollRetryInterval + 120), vendors: [.openai])
        #expect(log.count("models") == 2)
    }
}
