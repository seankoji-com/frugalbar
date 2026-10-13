import Testing
import Foundation
@testable import QuotaBarCore

/// The thinned read behind the History overview. Every row it returns must be
/// a reading some poll actually recorded — never an average, never a figure
/// borrowed from a neighbouring poll.
@Suite("QuotaHistoryStore sampled readings")
struct QuotaHistorySampledTests {

    private func makeStore() -> QuotaHistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sampled.sqlite3")
        return QuotaHistoryStore(databaseURL: url, isTestHost: true)
    }

    private func snapshot(_ id: String, used: Double?, at now: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id, vendorId: .claude, displayName: id, category: .aiSubscriptions,
            metric: .percentage(usedFraction: used ?? 0, displayDetails: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: used, label: "WK", windowLength: 7 * 86_400))
    }

    @Test("one row per instance, window and bucket: the bucket's latest, unchanged")
    func keepsLatestPerBucket() async throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_791_849_600)   // a multiple of 3600
        // Three polls in the first hour, two in the second.
        for (offset, used) in [(60.0, 0.10), (1_200.0, 0.20), (3_000.0, 0.30), (3_700.0, 0.40), (5_000.0, 0.50)] {
            try await store.record([snapshot("claude", used: used, at: base)], now: base.addingTimeInterval(offset))
        }

        let rows = try await store.fetchSampledReadings(
            since: base, until: base.addingTimeInterval(7_200), bucketSeconds: 3_600)

        #expect(rows.map(\.fraction) == [0.30, 0.50])
        #expect(rows.map(\.measuredAt) == [base.addingTimeInterval(3_000), base.addingTimeInterval(5_000)])
        #expect(rows.allSatisfy { $0.vendor == "claude" && $0.barLabel == "WK" && $0.windowLength == 7 * 86_400 })
    }

    @Test("a bucket whose latest poll had no figure keeps nil, not an earlier figure")
    func latestNilStaysNil() async throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_791_849_600)
        try await store.record([snapshot("claude", used: 0.4, at: base)], now: base.addingTimeInterval(60))
        try await store.record([snapshot("claude", used: nil, at: base)], now: base.addingTimeInterval(600))

        let rows = try await store.fetchSampledReadings(
            since: base, until: base.addingTimeInterval(3_599), bucketSeconds: 3_600)
        #expect(rows.count == 1)
        #expect(rows.first?.fraction == nil)
    }

    @Test("instances are sampled separately, and the range bounds hold")
    func instancesAndRange() async throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_791_849_600)
        try await store.record([
            snapshot("opencode-go:alpha", used: 0.1, at: base),
            snapshot("opencode-go:beta", used: 0.9, at: base),
        ], now: base.addingTimeInterval(100))
        try await store.record([snapshot("opencode-go:alpha", used: 0.2, at: base)],
                               now: base.addingTimeInterval(-10_000))

        let rows = try await store.fetchSampledReadings(
            since: base, until: base.addingTimeInterval(3_600), bucketSeconds: 3_600)
        #expect(Set(rows.map(\.vendor)) == ["opencode-go:alpha", "opencode-go:beta"])
        #expect(rows.first { $0.vendor == "opencode-go:alpha" }?.fraction == 0.1)
        #expect(rows.first { $0.vendor == "opencode-go:beta" }?.fraction == 0.9)
    }
}
