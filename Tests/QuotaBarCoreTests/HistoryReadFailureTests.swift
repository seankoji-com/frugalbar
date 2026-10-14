import Testing
import Foundation
@testable import QuotaBarCore

/// A read that fails part-way must throw, never come back short. The History
/// screen, the inspector and the activity breakdown all turn a thrown read
/// into "Could not read"; a short array becomes "No readings" or "No events",
/// which is a claim about the user's history nobody measured.
///
/// Each test swaps a table for a view whose row evaluation fails at step
/// time (`abs()` of the minimum integer overflows), so `prepare` succeeds and
/// only `sqlite3_step` reports the error.
@Suite("History reads throw on a failed step")
struct HistoryReadFailureTests {

    private static let overflow = "abs(-9223372036854775807 - 1)"
    private static let epoch = 1_791_848_000

    private func makeStore() async throws -> QuotaHistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("read-failure.sqlite3")
        let store = QuotaHistoryStore(databaseURL: url, isTestHost: true)
        try await store.ensureOpen()
        return store
    }

    private func replace(_ table: String, with select: String, in store: QuotaHistoryStore) async throws {
        try await store.database.perform { db in
            try db.execute(sql: "ALTER TABLE \(table) RENAME TO \(table)_original;")
            try db.execute(sql: "CREATE VIEW \(table) AS \(select);")
        }
    }

    @Test("fetchReadings throws instead of returning no readings")
    func readings() async throws {
        let store = try await makeStore()
        try await replace("reading", with: """
            SELECT 'claude' AS vendor, 'WK' AS bar_label, \(Self.epoch) AS measured_at,
                   \(Self.overflow) AS fraction, 0 AS is_blocked, 'measured' AS confidence,
                   'none' AS urgency, NULL AS resets_at, NULL AS window_length, 0 AS elapsed_only
            """, in: store)

        await #expect(throws: HistoryDatabaseError.self) {
            _ = try await store.fetchReadings(vendor: .claude)
        }
        await #expect(throws: HistoryDatabaseError.self) {
            _ = try await store.fetchReadings(since: Date(timeIntervalSince1970: 0))
        }
    }

    @Test("fetchActivities throws instead of returning no activity")
    func activities() async throws {
        let store = try await makeStore()
        try await replace("activity", with: """
            SELECT 'claude-code' AS source, 'r' AS record_id, 's' AS session_id,
                   NULL AS project_path, NULL AS git_branch, NULL AS model,
                   \(Self.epoch) AS observed_at, NULL AS input_tokens, NULL AS output_tokens,
                   NULL AS cache_read_tokens, NULL AS cache_write_tokens,
                   \(Self.overflow) AS total_tokens
            """, in: store)

        await #expect(throws: HistoryDatabaseError.self) {
            _ = try await store.fetchActivities()
        }
    }

    @Test("fetchEvents throws instead of returning no events")
    func events() async throws {
        let store = try await makeStore()
        try await replace("event", with: """
            SELECT 'e' AS id, 'usage-reset' AS kind, 'claude' AS vendor, NULL AS instance_id,
                   \(Self.overflow) AS title, NULL AS detail, \(Self.epoch) AS occurred_at,
                   \(Self.epoch) AS observed_at, 'quota-poll' AS source, NULL AS url
            """, in: store)

        await #expect(throws: HistoryDatabaseError.self) {
            _ = try await store.fetchEvents()
        }
    }

    @Test("fetchBalanceSeries throws instead of returning a short balance history")
    func balanceSeries() async throws {
        let store = try await makeStore()
        try await replace("balance_reading", with: """
            SELECT 'openai|credits:credits' AS series_id, 'openai' AS vendor,
                   'API credits' AS label, 'credits:credits' AS unit,
                   \(Self.epoch) AS measured_at, \(Self.overflow) AS value
            """, in: store)

        await #expect(throws: HistoryDatabaseError.self) {
            _ = try await store.fetchBalanceSeries(
                since: Date(timeIntervalSince1970: 0),
                until: Date(timeIntervalSince1970: 2_000_000_000), bucketSeconds: 3600)
        }
        // And through the narrowed read the inspector's own loader uses.
        await #expect(throws: HistoryDatabaseError.self) {
            _ = try await store.fetchBalanceSeries(
                since: Date(timeIntervalSince1970: 0),
                until: Date(timeIntervalSince1970: 2_000_000_000), bucketSeconds: 3600,
                seriesIds: ["openai|credits:credits"])
        }
    }

    /// A row whose *value* will not decode is a failure too, not a point
    /// quietly left out. Dropping it would make the series come back one
    /// reading short with nothing said, and the chart would draw that hole as
    /// fact — the same defect as a short step, reached from the other side.
    @Test("an undecodable stored value throws rather than dropping the point")
    func undecodableBalanceValue() async throws {
        let store = try await makeStore()
        try await replace("balance_reading", with: """
            SELECT 'openai|credits:credits' AS series_id, 'openai' AS vendor,
                   'API credits' AS label, 'credits:credits' AS unit,
                   \(Self.epoch) AS measured_at, 'not a number' AS value
            """, in: store)

        await #expect(throws: HistoryDatabaseError.self) {
            _ = try await store.fetchBalanceSeries(
                since: Date(timeIntervalSince1970: 0),
                until: Date(timeIntervalSince1970: 2_000_000_000), bucketSeconds: 3600)
        }
    }

    @Test("a healthy read still ends cleanly on SQLITE_DONE")
    func healthyReadStillReturns() async throws {
        let store = try await makeStore()
        #expect(try await store.fetchReadings(vendor: .claude).isEmpty)
        #expect(try await store.fetchActivities().isEmpty)
        #expect(try await store.fetchEvents().isEmpty)
        #expect(try await store.fetchBalanceSeries(
            since: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSince1970: 2_000_000_000), bucketSeconds: 3600).isEmpty)
    }
}
