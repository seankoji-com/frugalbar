import Testing
import Foundation
@testable import QuotaBarCore

/// The watchers must not move their durable checkpoint until the engine has
/// recorded the events derived from it. A checkpoint written first and an
/// insert that then failed (or a crash in between) lost those events for
/// good: the next poll diffed against the moved baseline and never derived
/// them again.
@Suite("PendingPoll checkpoint ordering")
struct PendingPollTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let catalog = #"""
    {"data":[
      {"id":"anthropic/claude-opus-5-5","name":"Claude Opus 5.5","created":1799000000,
       "pricing":{"prompt":"0.000005","completion":"0.000025"}}
    ]}
    """#

    @Test("the catalog watcher's prepare writes nothing until commit")
    func catalogPrepareDefersWrite() async throws {
        let store = makeIsolatedEventStore()
        let watcher = OpenRouterCatalogWatcher(fetch: { Data(Self.catalog.utf8) })

        let pending = await watcher.prepare(store: store, now: now)
        #expect(pending.fetched)
        #expect(pending.events.isEmpty)   // first poll seeds silently
        #expect(try await store.catalogModels().isEmpty)

        try await pending.commit()
        #expect(try await store.catalogModels().count == 1)
    }

    @Test("the feed watcher's prepare marks nothing seen until commit")
    func feedPrepareDefersWrite() async throws {
        let store = makeIsolatedEventStore()
        let feed = VendorFeed(name: "openai-news", url: URL(string: "https://example.invalid/f")!,
                              vendorId: .openai, isOfficial: true)
        let watcher = VendorFeedWatcher(feeds: [feed]) { _ in
            [FeedItem(id: "gpt6", title: "Introducing GPT-6", summary: "", link: nil, published: self.now)]
        }

        let pending = await watcher.prepare(store: store, now: now)
        #expect(pending.fetched)
        #expect(pending.events.map(\.title) == ["Introducing GPT-6"])
        #expect(try await store.seenFeedItemIDs(feed: "openai-news").isEmpty)

        // Re-preparing before commit derives the same event again — which is
        // exactly what lets a failed record be retried.
        let again = await watcher.prepare(store: store, now: now)
        #expect(again.events.map(\.id) == pending.events.map(\.id))

        try await pending.commit()
        #expect(try await store.seenFeedItemIDs(feed: "openai-news") == ["gpt6"])
        let after = await watcher.prepare(store: store, now: now)
        #expect(after.events.isEmpty)
    }

    @Test("nothing reachable reports fetched == false and commits nothing")
    func nothingReachable() async throws {
        let store = makeIsolatedEventStore()
        let catalog = OpenRouterCatalogWatcher(fetch: { nil })
        let feed = VendorFeed(name: "openai-news", url: URL(string: "https://example.invalid/f")!,
                              vendorId: .openai, isOfficial: true)
        let feeds = VendorFeedWatcher(feeds: [feed]) { _ in nil }

        let c = await catalog.prepare(store: store, now: now)
        let f = await feeds.prepare(store: store, now: now)
        #expect(!c.fetched && !f.fetched)
        #expect(c.events.isEmpty && f.events.isEmpty)
        try await c.commit()
        try await f.commit()
        #expect(try await store.catalogModels().isEmpty)
        #expect(try await store.seenFeedItemIDs(feed: "openai-news").isEmpty)
    }

    @Test("the engine retries sooner when nothing was reachable")
    func engineRetriesAfterTotalFailure() async throws {
        let store = makeIsolatedEventStore()
        let log = FetchLog()
        let reachable = Box(false)
        let engine = AIEventEngine(
            store: store,
            catalogFetcher: {
                log.hit("catalog")
                return reachable.value ? Data(Self.catalog.utf8) : nil
            },
            feedFetcher: { _ in log.hit("feed"); return nil },
            feeds: [VendorFeed(name: "f", url: URL(string: "https://example.invalid/f")!,
                               vendorId: .openai, isOfficial: true)],
            isTrackingEnabled: { true }
        )

        _ = await engine.pollExternalSources(now: now)
        #expect(log.count("catalog") == 1)

        // Still inside the retry window: no fetch.
        _ = await engine.pollExternalSources(now: now.addingTimeInterval(AIEventEngine.failedPollRetryInterval - 60))
        #expect(log.count("catalog") == 1)

        // Past it, well before the full interval: fetched again.
        reachable.value = true
        _ = await engine.pollExternalSources(now: now.addingTimeInterval(AIEventEngine.failedPollRetryInterval + 60))
        #expect(log.count("catalog") == 2)

        // Now on the normal cadence.
        _ = await engine.pollExternalSources(now: now.addingTimeInterval(AIEventEngine.failedPollRetryInterval + 3600))
        #expect(log.count("catalog") == 2)
    }
}
