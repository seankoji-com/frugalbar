import Testing
import Foundation
@testable import QuotaBarCore

@Suite("Token usage store query")
struct TokenUsageStoreTests {

    /// Local midnight stand-in: any epoch multiple of the bucket size works.
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)
    private let half: TimeInterval = 1800

    private func makeStore() throws -> (QuotaHistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (QuotaHistoryStore(databaseURL: dir.appendingPathComponent("h.sqlite3"), isTestHost: true), dir)
    }

    private func record(
        _ source: String, _ id: String, at seconds: TimeInterval, total: Int?
    ) -> ActivityRecord {
        ActivityRecord(
            source: source, recordId: id, sessionId: "s",
            observedAt: anchor.addingTimeInterval(seconds), totalTokens: total)
    }

    private func usage(
        _ store: QuotaHistoryStore, from: TimeInterval = 0, to: TimeInterval = 86_400, bucket: Int = 1800
    ) async throws -> QuotaHistoryStore.TokenUsage {
        try await store.fetchTokenUsage(
            since: anchor.addingTimeInterval(from), until: anchor.addingTimeInterval(to),
            bucketSeconds: bucket, anchor: anchor)
    }

    @Test("tokens are summed per source per bucket, and buckets start on the anchor grid")
    func sumsPerBucket() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.recordActivities([
            record("claude_code", "a", at: 10, total: 100),
            record("claude_code", "b", at: 20, total: 200),      // same bucket as a
            record("claude_code", "c", at: 1900, total: 50),     // next bucket
            record("codex", "d", at: 15, total: 7),
        ])
        let result = try await usage(store)
        let claude = result.buckets.filter { $0.source == "claude_code" }
        #expect(claude.map(\.tokens) == [300, 50])
        #expect(claude.map(\.records) == [2, 1])
        #expect(claude.map(\.start) == [anchor, anchor.addingTimeInterval(half)])
        #expect(result.buckets.filter { $0.source == "codex" }.map(\.tokens) == [7])
        #expect(result.uncountedRecords.isEmpty)
    }

    /// The defect this guards: a turn whose source reported no token figure
    /// being summed as zero, which reads as "this turn cost nothing".
    @Test("a record with no total is uncounted, never summed as zero")
    func nilTotalIsUncounted() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.recordActivities([
            record("opencode", "a", at: 5, total: nil),           // bucket 0: nothing reported
            record("opencode", "b", at: 1900, total: 40),         // bucket 1
            record("opencode", "c", at: 1950, total: nil),        // bucket 1: one of two reported
        ])
        let result = try await usage(store)
        #expect(result.buckets.map(\.tokens) == [40])
        #expect(result.buckets.map(\.records) == [1])
        #expect(result.uncountedRecords == ["opencode": 2])
    }

    @Test("both ends of the range are inclusive and anything outside is excluded")
    func rangeEdges() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.recordActivities([
            record("claude_code", "before", at: 999, total: 1),
            record("claude_code", "first", at: 1000, total: 10),
            record("claude_code", "last", at: 5000, total: 20),
            record("claude_code", "after", at: 5001, total: 4),
        ])
        let result = try await usage(store, from: 1000, to: 5000)
        #expect(result.buckets.map(\.tokens).reduce(0, +) == 30)
    }

    @Test("an anchor after the start is pulled back, so nothing falls into bucket zero by truncation")
    func lateAnchorIsClamped() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.recordActivities([record("claude_code", "a", at: 100, total: 9)])
        let result = try await store.fetchTokenUsage(
            since: anchor, until: anchor.addingTimeInterval(3600),
            bucketSeconds: 1800, anchor: anchor.addingTimeInterval(900))
        #expect(result.buckets.map(\.start) == [anchor])
    }

    @Test("the bucketed sum equals the sum of the individual records")
    func totalsAgreeWithRecords() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let records = (0..<50).map { i in
            record(i % 2 == 0 ? "claude_code" : "codex", "r\(i)", at: TimeInterval(i * 997), total: i % 7 == 0 ? nil : i * 13)
        }
        try await store.recordActivities(records)
        let bucketed = try await usage(store, to: 86_400).buckets.map(\.tokens).reduce(0, +)
        let direct = try await store.fetchActivities(since: anchor, until: anchor.addingTimeInterval(86_400))
            .compactMap(\.totalTokens).reduce(0, +)
        #expect(bucketed == direct)
        #expect(bucketed > 0)
    }

    /// The defect this guards: a query that stops part-way (BUSY, a corrupt
    /// page, an I/O error) ended the row loop like a normal finish, so the
    /// widget drew a short or empty chart, even "No token activity", for a
    /// history it could not read.
    ///
    /// SUM over integers raises "integer overflow" from `sqlite3_step`, after
    /// the statement has prepared and bound, which is a real step failure
    /// without damaging a file.
    @Test("a query that fails part-way throws instead of returning what it had")
    func midQueryFailureThrows() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.recordActivities([
            record("claude_code", "a", at: 10, total: Int.max),
            record("claude_code", "b", at: 20, total: Int.max),    // same bucket: the sum overflows
            record("codex", "c", at: 15, total: 7),                // a source that would read fine
        ])
        await #expect(performing: { _ = try await usage(store) }, throws: { error in
            if case HistoryDatabaseError.stepFailed = error { return true }
            return false
        })
    }

    @Test("an empty store, an empty range and a zero-width bucket all yield nothing")
    func empties() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await usage(store) == .empty)
        try await store.recordActivities([record("claude_code", "a", at: 10, total: 5)])
        #expect(try await usage(store, bucket: 0) == .empty)
        #expect(try await store.fetchTokenUsage(
            since: anchor.addingTimeInterval(10), until: anchor, bucketSeconds: 60, anchor: anchor) == .empty)
    }
}
