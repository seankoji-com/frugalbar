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
        let sources: [AIEventSource] = [
            .quotaPoll, .openRouterCatalog, .vendorFeed(name: "openai-news"),
            .resetTracker(name: "claude-resets"), .statusPage(name: "claude"), .accountModels,
        ]
        for source in sources {
            #expect(AIEventSource(rawValue: source.rawValue) == source)
        }
        #expect(AIEventSource.resetTracker(name: "whenreset").rawValue == "tracker:whenreset")
        #expect(AIEventSource.statusPage(name: "openai").rawValue == "status:openai")
        #expect(AIEventSource.accountModels.rawValue == "account-models")
        #expect(AIEventSource(rawValue: "feed:") == nil)
        #expect(AIEventSource(rawValue: "tracker:") == nil)
        #expect(AIEventSource(rawValue: "status:") == nil)
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
        #expect(AIEventKind.resetCreditGranted.rawValue == "reset_credit_granted")
        #expect(AIEventKind.newModel.rawValue == "new_model")
        #expect(AIEventKind.priceChange.rawValue == "price_change")
        #expect(AIEventKind.vendorReset.rawValue == "vendor_reset")
        #expect(AIEventKind.outageStarted.rawValue == "outage_started")
        #expect(AIEventKind.outageResolved.rawValue == "outage_resolved")
    }

    /// Rows written by the retired catalog and news-feed watchers stay on
    /// disk; only a model from the account's own list is surfaced.
    @Test("only account-scoped new models and surfaced kinds are surfaced")
    func surfacedFilter() {
        func event(_ kind: AIEventKind, _ source: AIEventSource) -> AIEvent {
            AIEvent(id: "x", kind: kind, vendorId: .openai, title: "t", detail: nil,
                    occurredAt: Date(timeIntervalSince1970: 0), observedAt: Date(timeIntervalSince1970: 0),
                    source: source)
        }
        #expect(event(.newModel, .accountModels).isSurfaced)
        #expect(!event(.newModel, .openRouterCatalog).isSurfaced)
        #expect(!event(.newModel, .vendorFeed(name: "openai-news")).isSurfaced)
        #expect(!event(.priceChange, .openRouterCatalog).isSurfaced)
        #expect(!event(.usageReset, .quotaPoll).isSurfaced)
        #expect(event(.vendorReset, .resetTracker(name: "claude-resets")).isSurfaced)
        #expect(event(.outageStarted, .statusPage(name: "claude")).isSurfaced)
        #expect(event(.outageResolved, .statusPage(name: "claude")).isSurfaced)
        #expect(event(.usageRestored, .quotaPoll).isSurfaced)
        #expect(event(.resetCreditGranted, .quotaPoll).isSurfaced)
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

    @Test("account models upsert per vendor and keep firstSeen")
    func accountModelsRoundTrip() async throws {
        let store = makeIsolatedStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_003_600)
        let first = AccountModelRecord(vendorId: .openai, modelId: "gpt-6.1-sol", name: "GPT-6.1 Sol",
                                       firstSeen: t0, lastSeen: t0)
        // The same id on another vendor is a different row.
        let other = AccountModelRecord(vendorId: .copilot, modelId: "gpt-6.1-sol", name: nil,
                                       firstSeen: t0, lastSeen: t0)
        try await store.upsertAccountModels([first, other])
        #expect(try await store.accountModels(vendor: .openai) == ["gpt-6.1-sol": first])
        #expect(try await store.accountModels(vendor: .copilot)["gpt-6.1-sol"]?.name == nil)

        let updated = AccountModelRecord(vendorId: .openai, modelId: "gpt-6.1-sol", name: "GPT-6.1 Sol",
                                         firstSeen: t0, lastSeen: t1)
        try await store.upsertAccountModels([updated])
        let stored = try await store.accountModels(vendor: .openai)
        #expect(stored.count == 1)
        #expect(stored["gpt-6.1-sol"] == updated)
        #expect(try await store.accountModels(vendor: .claude).isEmpty)
    }

    @Test("removeAll clears the event tables too")
    func removeAllClearsEvents() async throws {
        let store = makeIsolatedStore()
        try await store.recordEvents([event("a")])
        try await store.upsertAccountModels([AccountModelRecord(
            vendorId: .claude, modelId: "m", name: nil,
            firstSeen: Date(timeIntervalSince1970: 1), lastSeen: Date(timeIntervalSince1970: 1))])
        try await store.removeAll()
        let events = try await store.fetchEvents()
        #expect(events.isEmpty)
        #expect(try await store.accountModels(vendor: .claude).isEmpty)
    }
}
