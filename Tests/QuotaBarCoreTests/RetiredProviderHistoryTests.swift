import Foundation
import Testing
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

/// Older databases retain rows for providers that this build no longer offers.
@Suite("Retired provider history")
struct RetiredProviderHistoryTests {
    @Test("reopening preserves retired rows and reads another provider's history")
    func readsAcrossRetiredVendors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = QuotaHistoryStore(databaseURL: url, isTestHost: true)
        try await seed.ensureOpen()
        try await seed.database.perform { db in
            try db.execute(sql: """
                INSERT INTO reading VALUES
                  ('clinepass', 'WK', 1700000000, 0.1, 0, 'measured', 'none', NULL, NULL, 0),
                  ('devpass', 'MO', 1700000000, 0.2, 0, 'measured', 'none', NULL, NULL, 0),
                  ('kiro', 'MO', 1700000000, 0.3, 0, 'measured', 'none', NULL, NULL, 0),
                  ('claude', 'WK', 1700000000, 0.4, 0, 'measured', 'none', NULL, NULL, 0);
                INSERT INTO event (id, kind, vendor, title, occurred_at, observed_at, source) VALUES
                  ('current-newest', 'usage_reset', 'claude', 'Reset', 1700000004, 1700000004, 'quota-poll'),
                  ('old-cline', 'usage_reset', 'clinepass', 'Reset', 1700000005, 1700000005, 'quota-poll'),
                  ('old-devpass', 'usage_reset', 'devpass', 'Reset', 1700000002, 1700000002, 'quota-poll'),
                  ('old-kiro', 'usage_reset', 'kiro', 'Reset', 1700000001, 1700000001, 'quota-poll'),
                  ('future-kind', 'future_kind', 'claude', 'Future', 1700000003, 1700000003, 'quota-poll'),
                  ('current', 'usage_reset', 'claude', 'Reset', 1700000000, 1700000000, 'quota-poll');
                """)
        }

        let reopened = QuotaHistoryStore(databaseURL: url, isTestHost: true)
        let readings = try await reopened.fetchReadings(vendor: .claude)
        #expect(readings.map(\.fraction) == [0.4])
        let sampled = try await reopened.fetchSampledReadings(
            since: nil, until: Date(timeIntervalSince1970: 1_700_001_000), bucketSeconds: 3600)
        #expect(sampled.first { $0.vendor == "claude" }?.fraction == 0.4)
        #expect(Set(sampled.map(\.vendor)) == ["clinepass", "devpass", "kiro", "claude"])
        // The retired vendor is newest; an unknown kind lies between the
        // known events and must not stop the decoder from reading the older one.
        let events = try await reopened.fetchEvents()
        #expect(events.map(\.id) == ["current-newest", "current"])
        let mostRecent = try await reopened.fetchEvents(limit: 1)
        #expect(mostRecent.map(\.id) == ["current-newest"])
        #if canImport(SQLite3)
        // Skipping unknown events on read must not delete their stored rows.
        let counts = try await reopened.database.perform { db in
            let statement = try db.prepare(sql: """
                SELECT (SELECT COUNT(*) FROM reading WHERE vendor IN ('clinepass', 'devpass', 'kiro')),
                       (SELECT COUNT(*) FROM event WHERE vendor IN ('clinepass', 'devpass', 'kiro'));
                """)
            defer { db.finalize(statement) }
            guard try db.step(statement) else { throw HistoryDatabaseError.databaseNotOpen }
            return [sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1)]
        }
        #expect(counts == [3, 3])
        #endif
        #expect(HistorySchema.version == 1)
    }
}
