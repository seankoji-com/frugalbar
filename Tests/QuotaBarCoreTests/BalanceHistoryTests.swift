import Testing
import Foundation
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

/// Balance-over-time history: the figures that are *not* quotas — an account
/// credit, a key's remaining cap, a credit pool, a count of credits a vendor
/// meters — recorded and read back.
@Suite("Balance history")
struct BalanceHistoryTests {

    private func makeStore(retention: TimeInterval = QuotaHistoryStore.defaultRetentionInterval) -> QuotaHistoryStore {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarBalanceTests-\(UUID().uuidString)", isDirectory: true)
        return QuotaHistoryStore(
            databaseURL: tempDir.appendingPathComponent("balance.sqlite3"),
            retentionInterval: retention, isTestHost: true)
    }

    /// One series' recorded points, through the one read API the popover's
    /// strip and the inspector both use. There is deliberately one: two reads
    /// for one job would have to keep their bucketing and their step-failure
    /// handling in step with each other.
    private func recorded(
        _ store: QuotaHistoryStore, _ seriesId: String, until: Date,
        since: Date = .distantPast, bucketSeconds: Int = 3600
    ) async throws -> [BalancePoint] {
        let all = try await store.fetchBalanceSeries(
            since: since, until: until, bucketSeconds: bucketSeconds, seriesIds: [seriesId])
        return all[seriesId] ?? []
    }

    private func money(
        _ id: String, balance: String, code: String = "USD",
        basis: CurrencyBasis? = .accountCredit, status: ProviderStatus = .measured(.none)
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id, vendorId: .openrouter, displayName: "OpenRouter",
            category: .apiSpendAndCredits,
            metric: .currency(balance: Decimal(string: balance)!, limit: nil, spent: nil, currencyCode: code),
            status: status, resetsAt: nil, lastUpdated: Date(timeIntervalSince1970: 0),
            auxiliaryInfo: nil, currencyBasis: basis)
    }

    @Test("a money balance records and round-trips exactly, without binary rounding")
    func moneyRoundTripsExactly() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([money("openrouter", balance: "179.50")], now: now)

        let series = try await recorded(
            store, BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD")), until: now)
        #expect(series.count == 1)
        #expect(series.first?.value == Decimal(string: "179.50"))
    }

    /// Stored as exact decimal text, not as a `REAL`. Three-decimal currencies
    /// exist (the dinar, the rial) and Anthropic's `spend` declares its own
    /// exponent, so a money figure can carry more than two places. Through a
    /// binary double, 1.005 comes back as 1.0050000000000001.
    @Test("a money figure with more than two decimals survives the round-trip")
    func threeDecimalMoneyRoundTrips() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([money("openrouter", balance: "1.005", code: "BHD")], now: now)

        let points = try await recorded(
            store, BalanceSeries.id(source: "openrouter", unit: .currency(code: "BHD")), until: now)
        #expect(points.first?.value == Decimal(string: "1.005"))
    }

    /// The text form is the exact decimal, so no reader's locale and no binary
    /// approximation can change what a figure is.
    @Test("the stored text is the exact decimal, locale-independent")
    func storedTextIsExact() {
        #expect(QuotaHistoryStore.decimalText(Decimal(string: "1.005")!) == "1.005")
        #expect(QuotaHistoryStore.decimalText(Decimal(string: "300.00")!) == "300")
        #expect(QuotaHistoryStore.decimal(fromText: "179.5") == Decimal(string: "179.50"))
        #expect(QuotaHistoryStore.decimal(fromText: "not a number") == nil)
    }

    /// A poll that failed leaves the previous figures in place, marked with
    /// `StaleReading` — and keeps `confidence == .measured`, because the last
    /// known pressure must still drive the menu bar icon. Recording those
    /// carried-over figures under the current timestamp would be a reading from
    /// silence: an outage would look like a fresh balance in history.
    @Test("a stale snapshot records no balance, and no carried-over credit either")
    func staleSnapshotRecordsNothing() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var snap = money("openrouter", balance: "179.50")
        snap.apiCredits = [APICreditEntry(
            id: "openrouter.promo", vendorId: .openrouter, label: "Promo credit",
            metric: .currency(balance: 25, limit: nil, spent: nil, currencyCode: "USD"),
            currencyBasis: .prepaidCredit)]
        snap.staleReading = StaleReading(reason: .offline, at: now)
        try await store.record([snap], now: now)

        let all = try await store.fetchBalanceSeries(
            since: now.addingTimeInterval(-1), until: now, bucketSeconds: 3600)
        #expect(all.isEmpty)
    }

    /// The freshness test gates *writing*, not reading: during an outage the row
    /// must keep drawing the trend it already had, so the series is still named
    /// for the visible row and its history is still read.
    @Test("a stale snapshot still names its series, so its history is still read")
    func staleSnapshotKeepsItsSeriesIdentity() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([money("openrouter", balance: "179.50")], now: now)

        var stale = money("openrouter", balance: "179.50")
        stale.staleReading = StaleReading(reason: .offline, at: now.addingTimeInterval(3600))
        try await store.record([stale], now: now.addingTimeInterval(3600))

        let seriesID = BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD"))
        #expect(BalanceSeries.seriesIDs(in: [stale]) == [seriesID])
        let points = try await recorded(store, seriesID, until: now.addingTimeInterval(7200))
        // The one real reading, and no invented second point for the failed poll.
        #expect(points.count == 1)
        #expect(points.first?.value == Decimal(string: "179.50"))
    }

    /// A balance and a reading come from one poll and one call, so the two
    /// tables never disagree about which poll they hold.
    @Test("one record call writes both the poll's reading and its balance")
    func oneCallWritesBoth() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([money("openrouter", balance: "12.00")], now: now)

        let readings = try await store.fetchReadings(vendor: .openrouter)
        #expect(readings.contains { $0.barLabel == QuotaHistoryStore.providerPollLabel })
        let balances = try await recorded(
            store, BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD")), until: now)
        #expect(balances.count == 1)
    }

    /// A cumulative spend total is spend, not a balance. Charting it on a
    /// balance axis would draw an ever-rising line under a balance heading.
    @Test("a lifetime-spend figure records no balance")
    func lifetimeSpendIsNotABalance() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([money("openrouter", balance: "300.00", basis: .lifetimeSpend)], now: now)

        let all = try await store.fetchBalanceSeries(since: now.addingTimeInterval(-1), until: now, bucketSeconds: 3600)
        #expect(all.isEmpty)
    }

    /// A poll that did not measure published no figure. Recording one would be
    /// a synthesised zero, and a zero balance is a real and frightening fact.
    @Test("an unmeasured poll records no balance")
    func unmeasuredPollRecordsNothing() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record(
            [money("openrouter", balance: "179.50", status: .unavailable(.offline))], now: now)

        let all = try await store.fetchBalanceSeries(since: now.addingTimeInterval(-1), until: now, bucketSeconds: 3600)
        #expect(all.isEmpty)
    }

    /// Unlimited is a statement, not a figure: there is nothing to chart.
    @Test("an unlimited credit pool records no balance")
    func unlimitedCreditsRecordNothing() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = QuotaSnapshot(
            id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .apiSpendAndCredits,
            metric: .credits(remaining: nil, unitName: "credits"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        try await store.record([snap], now: now)

        let all = try await store.fetchBalanceSeries(since: now.addingTimeInterval(-1), until: now, bucketSeconds: 3600)
        #expect(all.isEmpty)
    }

    /// The prepaid credit entries a quota-only provider (Claude, OpenAI) carries
    /// are recorded under their own series — the entry's id, not the snapshot's.
    @Test("prepaid credit entries get a series each, keyed by the entry")
    func creditEntriesGetTheirOwnSeries() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var snap = QuotaSnapshot(
            id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Plus", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        snap.apiCredits = [
            APICreditEntry(id: "openai.api-credits", vendorId: .openai, label: "API credits",
                           metric: .credits(remaining: 62_500, unitName: "credits")),
            APICreditEntry(id: "claude.extra-usage", vendorId: .claude, label: "API credits",
                           metric: .currency(balance: Decimal(string: "179.50")!, limit: Decimal(string: "200")!,
                                             spent: nil, currencyCode: "USD"),
                           currencyBasis: .prepaidCredit),
        ]
        try await store.record([snap], now: now)

        let all = try await store.fetchBalanceSeries(since: now.addingTimeInterval(-1), until: now, bucketSeconds: 3600)
        #expect(all.keys.contains(BalanceSeries.id(source: "openai.api-credits", unit: .credits(name: "credits"))))
        #expect(all.keys.contains(BalanceSeries.id(source: "claude.extra-usage", unit: .currency(code: "USD"))))
        #expect(all[BalanceSeries.id(source: "openai.api-credits", unit: .credits(name: "credits"))]?.first?.value == 62_500)
    }

    @Test("several readings in one bucket keep the latest, and nothing is interpolated")
    func thinningKeepsTheLatest() async throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, amount) in [(0, "10.00"), (600, "8.00"), (1_500, "6.00")] {
            try await store.record([money("openrouter", balance: amount)],
                                   now: base.addingTimeInterval(TimeInterval(offset)))
        }
        let points = try await recorded(
            store, BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD")),
            until: base.addingTimeInterval(3600))
        #expect(points.count == 1)
        #expect(points.first?.value == Decimal(string: "6.00"))
    }

    @Test("readings older than retention are pruned from the balance table too")
    func pruningDropsOldBalances() async throws {
        let store = makeStore(retention: 3600)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([money("openrouter", balance: "10.00")],
                               now: now.addingTimeInterval(-7200))
        try await store.record([money("openrouter", balance: "5.00")], now: now)

        let points = try await recorded(
            store, BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD")), until: now)
        #expect(points.count == 1)
        #expect(points.first?.value == Decimal(string: "5.00"))
    }

    @Test("a read narrowed to given series ids returns only those")
    func readNarrowedToSeriesIds() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([money("openrouter", balance: "10.00"),
                                money("deepseek", balance: "42.00")], now: now)

        let wanted = BalanceSeries.id(source: "deepseek", unit: .currency(code: "USD"))
        let all = try await store.fetchBalanceSeries(
            since: now.addingTimeInterval(-1), until: now, bucketSeconds: 3600, seriesIds: [wanted])
        #expect(all.keys.sorted() == [wanted])
    }

    /// Two currencies of one account are different money: they must not be
    /// summed into, or drawn as, one line.
    @Test("a currency change starts a separate series rather than joining the old one")
    func currencyChangeStartsANewSeries() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([money("deepseek", balance: "42.00", code: "USD")], now: now)
        try await store.record([money("deepseek", balance: "300.00", code: "CNY")],
                               now: now.addingTimeInterval(3600))

        let usd = try await recorded(
            store, BalanceSeries.id(source: "deepseek", unit: .currency(code: "USD")),
            until: now.addingTimeInterval(7200))
        let cny = try await recorded(
            store, BalanceSeries.id(source: "deepseek", unit: .currency(code: "CNY")),
            until: now.addingTimeInterval(7200))
        #expect(usd.map(\.value) == [Decimal(string: "42.00")!])
        #expect(cny.map(\.value) == [Decimal(string: "300.00")!])
    }

    /// The `WITHOUT ROWID` table's primary key *is* its clustering b-tree on
    /// `(series_id, measured_at)`, so a secondary index on those same columns
    /// is a second copy of the same keys: dead storage, and one more b-tree
    /// write on every poll — for a read that could not use it anyway.
    /// Asserted against the database the schema actually built, not the SQL
    /// text that asked for it.
    @Test("the balance table carries no secondary index")
    func noSecondaryIndexOnTheBalanceTable() async throws {
        #if canImport(SQLite3)
        let store = makeStore()
        try await store.record([money("openrouter", balance: "10.00")],
                               now: Date(timeIntervalSince1970: 1_700_000_000))
        let indexes = try await store.database.perform { db -> [String] in
            let stmt = try db.prepare(
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?;")
            defer { db.finalize(stmt) }
            try db.bindText(stmt, 1, HistorySchema.balanceReadingTable)
            var names: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { names.append(String(cString: c)) }
            }
            return names
        }
        #expect(indexes.isEmpty)
        #endif
    }

    /// An empty list asks for no series, which is not the same request as
    /// asking for every series. Collapsing the two handed a caller that had
    /// built its list dynamically and ended up with nothing the points of
    /// unrelated series — and a full-table scan to be handed them.
    @Test("asking for no series reads none, and is not the unfiltered read")
    func emptySeriesIdsReadsNothing() async throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([money("openrouter", balance: "10.00"),
                                money("deepseek", balance: "42.00")], now: now)

        let none = try await store.fetchBalanceSeries(
            since: now.addingTimeInterval(-1), until: now, bucketSeconds: 3600, seriesIds: [])
        #expect(none.isEmpty)
        // The unfiltered read still sees both, so the empty list is a real
        // filter rather than a broken query.
        let all = try await store.fetchBalanceSeries(
            since: now.addingTimeInterval(-1), until: now, bucketSeconds: 3600)
        #expect(all.count == 2)
    }

    /// The table is additive under the shipped schema generation; a version
    /// bump would delete the user's readings.
    @Test("the balance table is additive: version is unchanged and the table is created and dropped")
    func schemaIsAdditive() {
        #expect(HistorySchema.version == 1)
        #expect(HistorySchema.createTablesSQL.contains("CREATE TABLE IF NOT EXISTS balance_reading"))
        #expect(HistorySchema.dropTablesSQL.contains(HistorySchema.balanceReadingTable))
    }
}
