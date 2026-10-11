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

    private func makeIsolatedURL(_ filename: String = "test-events.sqlite3") -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarTests-\(UUID().uuidString)", isDirectory: true)
        return tempDir.appendingPathComponent(filename)
    }

    private func makeIsolatedStore() -> QuotaHistoryStore {
        QuotaHistoryStore(databaseURL: makeIsolatedURL(), isTestHost: true)
    }

    /// One OpenCode Go workspace's own poll event, carrying its instance key.
    private func scoped(
        _ id: String,
        instanceId: String,
        occurredAt: TimeInterval = 1_700_000_000
    ) -> AIEvent {
        AIEvent(
            id: id, kind: .usageReset, vendorId: .opencode, instanceId: instanceId,
            title: "title \(id)", detail: nil,
            occurredAt: Date(timeIntervalSince1970: occurredAt),
            observedAt: Date(timeIntervalSince1970: occurredAt + 5),
            source: .quotaPoll
        )
    }

    private func event(
        _ id: String,
        kind: AIEventKind = .usageReset,
        vendor: VendorIdentifier = .openai,
        occurredAt: TimeInterval = 1_700_000_000,
        source: AIEventSource = .quotaPoll,
        url: URL? = nil
    ) -> AIEvent {
        AIEvent(
            id: id, kind: kind, vendorId: vendor,
            title: "title \(id)", detail: "detail \(id)",
            occurredAt: Date(timeIntervalSince1970: occurredAt),
            observedAt: Date(timeIntervalSince1970: occurredAt + 5),
            source: source, url: url
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
            id: "vendor_reset|claude|x", kind: .vendorReset, vendorId: .claude,
            title: "Claude reset", detail: nil,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            observedAt: Date(timeIntervalSince1970: 1_700_000_050),
            source: .resetTracker(name: "claude-resets"),
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
            event("m1", kind: .newModel, vendor: .claude, occurredAt: 300, source: .accountModels),
            event("p1", kind: .outageStarted, vendor: .gemini, occurredAt: 400, source: .statusPage(name: "x")),
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

    /// One workspace's events must never be returned to another's query, while
    /// the vendor's *own* events (no instance) reach every workspace.
    @Test("an instance-scoped query returns its own events and the vendor's, never a sibling's")
    func fetchScopesToInstance() async throws {
        let store = makeIsolatedStore()
        let alpha = "opencode-go:alpha"
        let beta = "opencode-go:beta"
        try await store.recordEvents([
            scoped("reset-alpha", instanceId: alpha),
            scoped("reset-beta", instanceId: beta, occurredAt: 1_700_000_100),
            // The vendor's own: a status-page incident concerns OpenCode, not
            // one subscription of it.
            event("incident", kind: .outageStarted, vendor: .opencode,
                  source: .statusPage(name: "opencode")),
        ])

        let alphaEvents = try await store.fetchEvents(vendor: .opencode, instanceID: alpha)
        #expect(Set(alphaEvents.map(\.id)) == ["reset-alpha", "incident"])
        let betaEvents = try await store.fetchEvents(vendor: .opencode, instanceID: beta)
        #expect(Set(betaEvents.map(\.id)) == ["reset-beta", "incident"])

        // With no instance the query is the vendor-wide view it always was.
        let vendorWide = try await store.fetchEvents(vendor: .opencode)
        #expect(Set(vendorWide.map(\.id)) == ["reset-alpha", "reset-beta", "incident"])

        // And the instance itself round-trips, so a caller can tell them apart.
        #expect(alphaEvents.first { $0.id == "reset-alpha" }?.instanceId == alpha)
        #expect(alphaEvents.first { $0.id == "incident" }?.instanceId == nil)
    }

    /// The sibling's events must not merely be filtered out of the result: the
    /// limit has to apply to what this workspace has, or five of the other
    /// workspace's events would take all five inspector slots and hide its own.
    @Test("the instance filter bounds the limit, so a sibling cannot take the slots")
    func instanceScopingBoundsLimit() async throws {
        let store = makeIsolatedStore()
        var rows = (0..<5).map {
            scoped("beta-\($0)", instanceId: "opencode-go:beta", occurredAt: 1_700_050_000 + Double($0))
        }
        rows.append(scoped("alpha-only", instanceId: "opencode-go:alpha", occurredAt: 1_700_000_000))
        try await store.recordEvents(rows)

        let alphaRecent = try await store.fetchEvents(
            vendor: .opencode, instanceID: "opencode-go:alpha", limit: 5)
        #expect(alphaRecent.map(\.id) == ["alpha-only"])
    }

    /// The `instance_id` column arrived after the schema shipped. An installed
    /// database must gain it by an additive `ALTER TABLE` that keeps every
    /// row — a version bump would drop the table, and with it the user's whole
    /// event history.
    @Test("an event table without the instance column gains it, keeping its rows")
    func instanceColumnIsAddedToAnOlderTable() async throws {
        let url = makeIsolatedURL("old-events.sqlite3")

        // A database as the build before this column wrote it: the modern file
        // with the event table put back the way it was.
        let older = HistoryDatabase(fileURL: url)
        try older.open()
        try older.execute(sql: """
        DROP TABLE event;
        CREATE TABLE event (
          id          TEXT    NOT NULL,
          kind        TEXT    NOT NULL,
          vendor      TEXT    NOT NULL,
          title       TEXT    NOT NULL,
          detail      TEXT,
          occurred_at INTEGER NOT NULL,
          observed_at INTEGER NOT NULL,
          source      TEXT    NOT NULL,
          url         TEXT,
          PRIMARY KEY (id)
        ) WITHOUT ROWID;
        INSERT INTO event (id, kind, vendor, title, detail, occurred_at, observed_at, source, url)
        VALUES ('usage_reset|opencode|5H|1700000000', 'usage_reset', 'opencode',
                'OpenCode 5H window reset', NULL, 1700000000, 1700000000, 'quota-poll', NULL);
        """)

        // Opening it through the store is the upgrade path.
        let store = QuotaHistoryStore(databaseURL: url, isTestHost: true)
        let legacyKey = OpenCodeGoWorkspaceStore.instancePrefix + OpenCodeGoWorkspaceStore.legacyID

        // The pre-workspace row survived and now belongs to the legacy
        // workspace, the only subscription that existed when it was written.
        let legacy = try await store.fetchEvents(vendor: .opencode, instanceID: legacyKey)
        #expect(legacy.map(\.id) == ["usage_reset|opencode|5H|1700000000"])
        #expect(legacy.first?.instanceId == legacyKey)
        #expect(try await store.fetchEvents(vendor: .opencode).count == 1)

        // A second workspace does not inherit it.
        let alpha = try await store.fetchEvents(vendor: .opencode, instanceID: "opencode-go:alpha")
        #expect(alpha.isEmpty)
    }

    /// Regression guard: a backlog of retired catalog and news-feed rows must
    /// not take the slots of a limited query (the popover asks for 20, the
    /// inspector for 5) and hide real resets and outages behind them.
    @Test("retired catalog and news-feed rows are never returned, so they cannot fill a limit")
    func retiredRowsExcluded() async throws {
        let store = makeIsolatedStore()
        var rows = (0..<5).map { event("feed\($0)", kind: .newModel, occurredAt: 1_000 + Double($0),
                                         source: .vendorFeed(name: "openai-news")) }
        rows += (0..<5).map { event("cat\($0)", kind: .newModel, occurredAt: 2_000 + Double($0),
                                    source: .openRouterCatalog) }
        rows.append(event("price", kind: .priceChange, occurredAt: 3_000, source: .openRouterCatalog))
        rows.append(event("outage", kind: .outageStarted, occurredAt: 10, source: .statusPage(name: "claude")))
        rows.append(event("model", kind: .newModel, occurredAt: 20, source: .accountModels))
        try await store.recordEvents(rows)

        let limited = try await store.fetchEvents(limit: 2)
        #expect(limited.map(\.id) == ["model", "outage"])
        let models = try await store.fetchEvents(kinds: [.newModel, .priceChange])
        #expect(models.map(\.id) == ["model"])
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
