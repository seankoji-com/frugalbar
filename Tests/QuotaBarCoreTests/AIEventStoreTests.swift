import Testing
import Foundation
@testable import QuotaBarCore

@Suite("AIEvent model")
struct AIEventModelTests {

    @Test("ids are built from the defining facts, not from prose")
    func idIsDeterministic() {
        let a = AIEvent.makeID(kind: .usageReset, vendorId: .openai, components: ["WK", "1700000000"])
        let b = AIEvent.makeID(kind: .usageReset, vendorId: .openai, components: ["WK", "1700000000"])
        let c = AIEvent.makeID(kind: .usageReset, vendorId: .openai, components: ["5H", "1700000000"])
        #expect(a == b)
        #expect(a != c)
        #expect(a == "usage_reset|openai|WK|1700000000")
    }

    @Test("every source round-trips through its raw value")
    func sourceRoundTrips() {
        let sources: [AIEventSource] = [.quotaPoll, .openRouterCatalog, .vendorFeed(name: "openai-news")]
        for source in sources {
            #expect(AIEventSource(rawValue: source.rawValue) == source)
        }
        #expect(AIEventSource(rawValue: "feed:") == nil)
        #expect(AIEventSource(rawValue: "something-else") == nil)
    }

    @Test("an event encodes and decodes as JSON unchanged")
    func codableRoundTrip() throws {
        let event = AIEvent(
            id: "new_model|claude|anthropic/claude-opus-5-5",
            kind: .newModel,
            vendorId: .claude,
            title: "Claude Opus 5.5 listed",
            detail: "First seen in the OpenRouter catalog",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            observedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: .openRouterCatalog,
            url: URL(string: "https://openrouter.ai/anthropic/claude-opus-5-5")
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AIEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("kind raw values are the on-disk contract")
    func kindRawValues() {
        #expect(AIEventKind.usageReset.rawValue == "usage_reset")
        #expect(AIEventKind.usageRestored.rawValue == "usage_restored")
        #expect(AIEventKind.newModel.rawValue == "new_model")
        #expect(AIEventKind.priceChange.rawValue == "price_change")
    }
}

@Suite("QuotaHistoryStore events")
struct AIEventStoreTests {

    private func makeIsolatedStore() -> QuotaHistoryStore {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = tempDir.appendingPathComponent("test-events.sqlite3")
        return QuotaHistoryStore(databaseURL: dbURL, isTestHost: true)
    }

    private func event(
        _ id: String,
        kind: AIEventKind = .usageReset,
        vendor: VendorIdentifier = .openai,
        occurredAt: TimeInterval = 1_700_000_000,
        url: URL? = nil
    ) -> AIEvent {
        AIEvent(
            id: id, kind: kind, vendorId: vendor,
            title: "title \(id)", detail: "detail \(id)",
            occurredAt: Date(timeIntervalSince1970: occurredAt),
            observedAt: Date(timeIntervalSince1970: occurredAt + 5),
            source: .quotaPoll, url: url
        )
    }

    @Test("recordEvents returns only the events that were new")
    func recordReturnsOnlyNewEvents() async throws {
        let store = makeIsolatedStore()

        let first = try await store.recordEvents([event("a"), event("b")])
        #expect(first.map(\.id) == ["a", "b"])

        // Same ids again, plus one new one, plus a duplicate inside the batch.
        let second = try await store.recordEvents([event("a"), event("c"), event("c")])
        #expect(second.map(\.id) == ["c"])

        let all = try await store.fetchEvents()
        #expect(Set(all.map(\.id)) == ["a", "b", "c"])
    }

    @Test("a re-recorded event keeps its original observedAt")
    func rerecordKeepsOriginalObservation() async throws {
        let store = makeIsolatedStore()
        let original = event("a", occurredAt: 1_700_000_000)
        try await store.recordEvents([original])

        let later = AIEvent(
            id: "a", kind: .usageReset, vendorId: .openai,
            title: "reworded", detail: nil,
            occurredAt: original.occurredAt,
            observedAt: Date(timeIntervalSince1970: 1_700_009_999),
            source: .quotaPoll
        )
        let inserted = try await store.recordEvents([later])
        #expect(inserted.isEmpty)

        let stored = try await store.fetchEvents()
        #expect(stored.count == 1)
        #expect(stored.first?.observedAt == original.observedAt)
        #expect(stored.first?.title == original.title)
    }

    @Test("every field round-trips, including a nil detail and a URL")
    func fieldsRoundTrip() async throws {
        let store = makeIsolatedStore()
        let withURL = AIEvent(
            id: "new_model|claude|x", kind: .newModel, vendorId: .claude,
            title: "x listed", detail: nil,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            observedAt: Date(timeIntervalSince1970: 1_700_000_050),
            source: .vendorFeed(name: "anthropic-news"),
            url: URL(string: "https://example.com/x")
        )
        try await store.recordEvents([withURL])
        let stored = try await store.fetchEvents(vendor: .claude)
        #expect(stored == [withURL])
    }

    @Test("fetchEvents filters by vendor, kind, and since, newest first")
    func fetchFilters() async throws {
        let store = makeIsolatedStore()
        try await store.recordEvents([
            event("r1", kind: .usageReset, vendor: .openai, occurredAt: 100),
            event("r2", kind: .usageReset, vendor: .claude, occurredAt: 200),
            event("m1", kind: .newModel, vendor: .claude, occurredAt: 300),
            event("p1", kind: .priceChange, vendor: .gemini, occurredAt: 400),
        ])

        let all = try await store.fetchEvents()
        #expect(all.map(\.id) == ["p1", "m1", "r2", "r1"])

        let claude = try await store.fetchEvents(vendor: .claude)
        #expect(claude.map(\.id) == ["m1", "r2"])

        let resets = try await store.fetchEvents(kinds: [.usageReset])
        #expect(resets.map(\.id) == ["r2", "r1"])

        let recent = try await store.fetchEvents(since: Date(timeIntervalSince1970: 250))
        #expect(recent.map(\.id) == ["p1", "m1"])

        let limited = try await store.fetchEvents(limit: 2)
        #expect(limited.map(\.id) == ["p1", "m1"])

        // An empty kind set is a filter that matches nothing, not "no filter".
        let none = try await store.fetchEvents(kinds: [])
        #expect(none.isEmpty)
    }

    @Test("pruneEvents removes only events older than the cutoff")
    func pruneRemovesOldEvents() async throws {
        let store = makeIsolatedStore()
        try await store.recordEvents([
            event("old", occurredAt: 100),
            event("new", occurredAt: 1_000),
        ])
        try await store.pruneEvents(before: Date(timeIntervalSince1970: 500))
        let remaining = try await store.fetchEvents()
        #expect(remaining.map(\.id) == ["new"])
    }

    @Test("catalog models upsert and round-trip exact decimal prices")
    func catalogModelsRoundTrip() async throws {
        let store = makeIsolatedStore()
        let first = CatalogModelRecord(
            modelId: "anthropic/claude-opus-5-5", vendorId: .claude, name: "Claude Opus 5.5",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            promptPrice: Decimal(string: "0.000003"), completionPrice: Decimal(string: "0.000015"),
            firstSeen: Date(timeIntervalSince1970: 1_700_000_100),
            lastSeen: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try await store.upsertCatalogModels([first])
        var stored = try await store.catalogModels()
        #expect(stored[first.modelId] == first)
        // Exact decimal text, not a binary float that would read as a change.
        #expect(stored[first.modelId]?.promptPrice == Decimal(string: "0.000003"))

        // Replace with a new last_seen and a nil price (vendor stopped publishing).
        let updated = CatalogModelRecord(
            modelId: first.modelId, vendorId: .claude, name: first.name,
            createdAt: nil, promptPrice: nil, completionPrice: first.completionPrice,
            firstSeen: first.firstSeen, lastSeen: Date(timeIntervalSince1970: 1_700_003_600)
        )
        try await store.upsertCatalogModels([updated])
        stored = try await store.catalogModels()
        #expect(stored.count == 1)
        #expect(stored[first.modelId] == updated)
        #expect(stored[first.modelId]?.promptPrice == nil)
        #expect(stored[first.modelId]?.createdAt == nil)
    }

    @Test("feed items are remembered once seen and never re-reported")
    func feedItemsRemembered() async throws {
        let store = makeIsolatedStore()
        let seenAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.markFeedItemsSeen(feed: "openai-news", ids: ["a", "b"], at: seenAt)
        try await store.markFeedItemsSeen(feed: "openai-news", ids: ["b", "c"], at: seenAt)
        try await store.markFeedItemsSeen(feed: "google-ai", ids: ["a"], at: seenAt)

        let openai = try await store.seenFeedItemIDs(feed: "openai-news")
        #expect(openai == ["a", "b", "c"])
        let google = try await store.seenFeedItemIDs(feed: "google-ai")
        #expect(google == ["a"])
        let unknown = try await store.seenFeedItemIDs(feed: "nothing")
        #expect(unknown.isEmpty)
    }

    @Test("removeAll clears the event tables too")
    func removeAllClearsEvents() async throws {
        let store = makeIsolatedStore()
        try await store.recordEvents([event("a")])
        try await store.markFeedItemsSeen(feed: "f", ids: ["x"], at: Date(timeIntervalSince1970: 1))
        try await store.removeAll()
        let events = try await store.fetchEvents()
        #expect(events.isEmpty)
        let seen = try await store.seenFeedItemIDs(feed: "f")
        #expect(seen.isEmpty)
    }
}
