import Foundation
import Testing
@testable import QuotaBarCore

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
                  ('old-cline', 'usage_reset', 'clinepass', 'Reset', 1700000000, 1700000000, 'quota-poll'),
                  ('old-devpass', 'usage_reset', 'devpass', 'Reset', 1700000000, 1700000000, 'quota-poll'),
                  ('old-kiro', 'usage_reset', 'kiro', 'Reset', 1700000000, 1700000000, 'quota-poll'),
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
        let events = try await reopened.fetchEvents()
        #expect(events.map(\.id) == ["current"])
        #expect(HistorySchema.version == 1)
    }
}
