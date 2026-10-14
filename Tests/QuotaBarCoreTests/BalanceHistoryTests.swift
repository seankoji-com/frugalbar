import Testing
import Foundation
@testable import QuotaBarCore

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

        let series = try await store.fetchBalancePoints(
            seriesId: BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD")),
            since: nil, until: now, bucketSeconds: 3600)
        #expect(series.count == 1)
        #expect(series.first?.value == Decimal(string: "179.50"))
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
        let balances = try await store.fetchBalancePoints(
            seriesId: BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD")),
            since: nil, until: now, bucketSeconds: 3600)
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
        let points = try await store.fetchBalancePoints(
            seriesId: BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD")),
            since: nil, until: base.addingTimeInterval(3600), bucketSeconds: 3600)
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

        let points = try await store.fetchBalancePoints(
            seriesId: BalanceSeries.id(source: "openrouter", unit: .currency(code: "USD")),
            since: nil, until: now, bucketSeconds: 3600)
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

        let usd = try await store.fetchBalancePoints(
            seriesId: BalanceSeries.id(source: "deepseek", unit: .currency(code: "USD")),
            since: nil, until: now.addingTimeInterval(7200), bucketSeconds: 3600)
        let cny = try await store.fetchBalancePoints(
            seriesId: BalanceSeries.id(source: "deepseek", unit: .currency(code: "CNY")),
            since: nil, until: now.addingTimeInterval(7200), bucketSeconds: 3600)
        #expect(usd.map(\.value) == [Decimal(string: "42.00")!])
        #expect(cny.map(\.value) == [Decimal(string: "300.00")!])
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
