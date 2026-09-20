import Testing
import Foundation
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

@Suite("QuotaHistoryStore")
struct QuotaHistoryStoreTests {

    private func makeIsolatedStore(retention: TimeInterval = QuotaHistoryStore.defaultRetentionInterval) -> (QuotaHistoryStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = tempDir.appendingPathComponent("test-history.sqlite3")
        let store = QuotaHistoryStore(databaseURL: dbURL, retentionInterval: retention, isTestHost: true)
        return (store, dbURL)
    }

    @Test("a nil fraction round-trips as NULL and never reads back as 0")
    func nilFractionRoundTripsAsNil() async throws {
        let (store, _) = makeIsolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Snapshot with a bar that has a nil fraction (e.g. rate-limited or blocked without percentage)
        var snapshot = QuotaSnapshot(
            id: "claude",
            vendorId: .claude,
            displayName: "Claude",
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.5, displayDetails: nil),
            status: .healthy,
            resetsAt: now.addingTimeInterval(3600),
            lastUpdated: now,
            auxiliaryInfo: nil
        )
        snapshot.row1 = DualBarMetrics(
            primaryFraction: nil,
            label: "5H",
            isBlocked: true,
            resetsAt: now.addingTimeInterval(3600),
            windowLength: 5 * 3600
        )

        try await store.record([snapshot], now: now)

        let readings = try await store.fetchReadings(vendor: .claude)
        #expect(readings.count == 1)
        let reading = try #require(readings.first)
        #expect(reading.barLabel == "5H")
        #expect(reading.fraction == nil)
        #expect(reading.isBlocked == true)
    }

    @Test("a batch that fails part-way through leaves the database untouched")
    func failedBatchRollsBack() async throws {
        #if canImport(SQLite3)
        let (store, dbURL) = makeIsolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        func snapshot(_ id: String, label: String, fraction: Double) -> QuotaSnapshot {
            var snapshot = QuotaSnapshot(
                id: id,
                vendorId: .claude,
                displayName: "Claude",
                category: .aiSubscriptions,
                metric: .percentage(usedFraction: fraction, displayDetails: nil),
                status: .healthy,
                resetsAt: nil,
                lastUpdated: now,
                auxiliaryInfo: nil
            )
            snapshot.row1 = DualBarMetrics(primaryFraction: fraction, label: label)
            return snapshot
        }

        // Seed so the schema exists before the trigger is installed.
        try await store.record([snapshot("seed", label: "5H", fraction: 0.1)], now: now)

        // Make exactly one row fail, part-way through a two-row batch.
        var rawDB: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &rawDB) == SQLITE_OK)
        let trigger = """
        CREATE TRIGGER reject_boom BEFORE INSERT ON reading
        WHEN NEW.bar_label = 'BOOM'
        BEGIN SELECT RAISE(ABORT, 'test-induced failure'); END;
        """
        #expect(sqlite3_exec(rawDB, trigger, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(rawDB)

        await #expect(throws: HistoryDatabaseError.self) {
            try await store.record(
                [snapshot("good", label: "GOOD", fraction: 0.42), snapshot("bad", label: "BOOM", fraction: 0.99)],
                now: now.addingTimeInterval(60)
            )
        }

        // The row written before the failure must not have been committed. The
        // old `defer { try? commitTransaction() }` committed it.
        let readings = try await store.fetchReadings(vendor: .claude)
        #expect(!readings.contains { $0.barLabel == "GOOD" })
        #expect(readings.map(\.barLabel) == ["5H"])
        #endif
    }

    @Test("an unavailable poll persists as confidence == .unavailable and never as a healthy reading")
    func unavailablePollPersistsAsUnavailable() async throws {
        let (store, _) = makeIsolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Snapshot reporting unavailable status
        let snapshot = QuotaSnapshot(
            id: "gemini",
            vendorId: .gemini,
            displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.0, displayDetails: nil),
            status: .unavailable(.offline),
            resetsAt: nil,
            lastUpdated: now,
            auxiliaryInfo: nil
        )

        try await store.record([snapshot], now: now)

        let readings = try await store.fetchReadings(vendor: .gemini)
        #expect(readings.count == 1)
        let reading = try #require(readings.first)
        #expect(reading.confidence == .unavailable)
        #expect(reading.confidence != .measured)
        #expect(reading.fraction == nil)
    }

    @Test("same-second double-record is idempotent")
    func sameSecondDoubleRecordIsIdempotent() async throws {
        let (store, _) = makeIsolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        var snapshot = QuotaSnapshot(
            id: "openai",
            vendorId: .openai,
            displayName: "OpenAI",
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.4, displayDetails: nil),
            status: .healthy,
            resetsAt: now.addingTimeInterval(7200),
            lastUpdated: now,
            auxiliaryInfo: nil
        )
        snapshot.row1 = DualBarMetrics(
            primaryFraction: 0.4,
            label: "3H",
            resetsAt: now.addingTimeInterval(7200),
            windowLength: 3 * 3600
        )

        // Record twice at the exact same timestamp
        try await store.record([snapshot], now: now)
        try await store.record([snapshot], now: now)

        let readings = try await store.fetchReadings(vendor: .openai)
        #expect(readings.count == 1)
        let reading = try #require(readings.first)
        #expect(reading.fraction == 0.4)
    }

    @Test("retention prunes only past the cap")
    func retentionPrunesOnlyPastCap() async throws {
        let retention: TimeInterval = 10 * 86_400 // 10 days
        let (store, _) = makeIsolatedStore(retention: retention)

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let oldDate = baseDate.addingTimeInterval(-15 * 86_400) // 15 days ago -> older than 10-day cap
        let recentDate = baseDate.addingTimeInterval(-5 * 86_400) // 5 days ago -> within 10-day cap

        var oldSnapshot = QuotaSnapshot(
            id: "claude-old",
            vendorId: .claude,
            displayName: "Claude",
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.2, displayDetails: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: oldDate,
            auxiliaryInfo: nil
        )
        oldSnapshot.row1 = DualBarMetrics(primaryFraction: 0.2, label: "5H")

        var recentSnapshot = QuotaSnapshot(
            id: "claude-recent",
            vendorId: .claude,
            displayName: "Claude",
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.6, displayDetails: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: recentDate,
            auxiliaryInfo: nil
        )
        recentSnapshot.row1 = DualBarMetrics(primaryFraction: 0.6, label: "5H")

        var newSnapshot = QuotaSnapshot(
            id: "claude-now",
            vendorId: .claude,
            displayName: "Claude",
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.8, displayDetails: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: baseDate,
            auxiliaryInfo: nil
        )
        newSnapshot.row1 = DualBarMetrics(primaryFraction: 0.8, label: "5H")

        // Record the old one at oldDate (not pruned yet because now was oldDate)
        try await store.record([oldSnapshot], now: oldDate)
        // Record the recent one at recentDate
        try await store.record([recentSnapshot], now: recentDate)

        // Now record new reading at baseDate -> pruning cutoff is baseDate - 10 days
        try await store.record([newSnapshot], now: baseDate)

        let readings = try await store.fetchReadings(vendor: .claude)
        // Old reading (15 days ago) must have been pruned; recent (5 days ago) and new must survive
        #expect(readings.count == 2)
        let fractions = readings.compactMap(\.fraction)
        #expect(fractions.contains(0.6))
        #expect(fractions.contains(0.8))
        #expect(!fractions.contains(0.2))
    }
}
