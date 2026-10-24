import Foundation
import Testing
@testable import QuotaBarCore

/// C6 regressions: a Codex request's identity is its published provenance, not
/// the second and total it happened to share with another request.
@Suite("Activity request identity regressions")
struct ActivityRequestIdentityTests {

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeStore(_ dir: URL) -> QuotaHistoryStore {
        QuotaHistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite3"), isTestHost: true)
    }

    private var header: String {
        """
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-identity","cwd":"/repo/identity"}}
        {"type":"turn_context","timestamp":"2026-10-19T09:59:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/identity"}}
        """
    }

    /// `event_msg` `token_count` with both the cumulative counter and the
    /// per-request figure. `lastTotal` is omitted for the missing-total case.
    private func eventLine(
        at timestamp: String,
        cumulativeTotal: Int,
        lastInput: Int = 400,
        lastOutput: Int = 100,
        lastTotal: Int?
    ) -> String {
        let total = lastTotal.map { ",\"total_tokens\":\($0)" } ?? ""
        return """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":\
        {"total_token_usage":{"input_tokens":\(cumulativeTotal - 100),"cached_input_tokens":0,\
        "cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,\
        "total_tokens":\(cumulativeTotal)},\
        "last_token_usage":{"input_tokens":\(lastInput),"cached_input_tokens":0,\
        "cache_write_input_tokens":0,"output_tokens":\(lastOutput),"reasoning_output_tokens":0\(total)}}}}
        """
    }

    private func requestLine(
        at timestamp: String,
        responseId: String,
        cumulativeTotal: Int,
        total: Int
    ) -> String {
        """
        {"type":"token_usage_record","timestamp":"\(timestamp)","payload":{"session_id":"sess-identity",\
        "thread_id":"sess-identity","response_id":"\(responseId)","usage":{"input_tokens":400,\
        "cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,\
        "reasoning_output_tokens":0,"total_tokens":\(total)},\
        "thread_token_usage":{"total_tokens":\(cumulativeTotal)}}}
        """
    }

    private func requestRecords(_ result: ActivityIngestResult) -> [ActivityRecord] {
        result.records.filter { $0.granularity == .request }
    }

    @Test("C6: equal total and second with different cumulative counters are two requests")
    func sameSecondEqualTotalDistinctCountersAreTwoRequests() async throws {
        let dir = try makeTempDir("c6-equal-total")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        \(header)
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 500, lastTotal: 500))
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 1_000, lastTotal: 500))
        """, "rollout-equal-total.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let requests = requestRecords(result)
        // Equal time and equal total do not prove one request; the cumulative
        // counter distinguishes them.
        #expect(requests.count == 2)
        #expect(requests.map(\.totalTokens) == [500, 500])
        #expect(Set(requests.map(\.recordId)).count == 2)
        #expect(result.diagnostics.inconsistentRecords == 0)
    }

    @Test("C6: the same request in both shapes is one row whichever shape comes first")
    func mixedShapeOrderDoesNotChangeTheRequestCount() async throws {
        let sameSecondToken = requestLine(
            at: "2026-10-19T10:00:00.000Z", responseId: "resp_order", cumulativeTotal: 1_000, total: 1_000)
        let sameSecondEvent = eventLine(
            at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 1_000,
            lastInput: 400, lastOutput: 100, lastTotal: 1_000)

        for (label, body) in [
            ("token-first", "\(sameSecondToken)\n\(sameSecondEvent)"),
            ("event-first", "\(sameSecondEvent)\n\(sameSecondToken)"),
        ] {
            let dir = try makeTempDir("c6-order-\(label)")
            defer { try? FileManager.default.removeItem(at: dir) }
            _ = try write("\(header)\n\(body)\n", "rollout-order.jsonl", in: dir)

            let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
            let requests = requestRecords(result)
            #expect(requests.count == 1, "\(label): one request must be one row")
            #expect(requests.first?.totalTokens == 1_000)
            #expect(requests.first?.recordId == "response_resp_order")
        }
    }

    @Test("C6: cross-shape matching pairs each event with one distinct token request")
    func crossShapeMatchingPairsEachEventWithOneTokenRequest() async throws {
        let dir = try makeTempDir("c6-one-to-one")
        defer { try? FileManager.default.removeItem(at: dir) }
        // The events come first, so an order-dependent dedupe sees both token
        // rows as new. Both requests share second and total; only the
        // cumulative counter tells them apart.
        _ = try write("""
        \(header)
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 500, lastTotal: 500))
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 1_000, lastTotal: 500))
        \(requestLine(at: "2026-10-19T10:00:00.000Z", responseId: "resp_first", cumulativeTotal: 500, total: 500))
        \(requestLine(at: "2026-10-19T10:00:00.000Z", responseId: "resp_second", cumulativeTotal: 1_000, total: 500))
        """, "rollout-one-to-one.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let requests = requestRecords(result)
        #expect(requests.count == 2)
        #expect(Set(requests.map(\.recordId)) == ["response_resp_first", "response_resp_second"])
        #expect(requests.map(\.totalTokens) == [500, 500])
    }

    @Test("C6: same-second equal totals with distinct counters both reach the store")
    func sameSecondEqualTotalsReachStore() async throws {
        let dir = try makeTempDir("c6-store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        _ = try write("""
        \(header)
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 500, lastTotal: 500))
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 1_000, lastTotal: 500))
        """, "rollout-store.jsonl", in: sessions)

        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: sessions)])
        #expect(try await engine.ingestAll() == 2)

        let day = ISO8601DateFormatter().date(from: "2026-10-19T00:00:00Z")!
        let usage = try await store.fetchTokenUsage(
            since: day, until: day.addingTimeInterval(86_400), bucketSeconds: 86_400, anchor: day)
        #expect(usage.buckets.filter { $0.source == "codex" }.map(\.tokens) == [1_000])
        #expect(usage.sessionTotalRecords["codex"] == nil)
    }

    @Test("C6: a missing total cannot collapse a distinct same-second observation")
    func sameSecondMissingTotalsKeepTwoObservations() async throws {
        let dir = try makeTempDir("c6-missing-total")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        \(header)
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 500, lastTotal: nil))
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 1_000, lastTotal: nil))
        """, "rollout-missing-total.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let requests = requestRecords(result)
        #expect(requests.count == 2)
        // No published total was received, so neither row claims one: the
        // total is derived from the components actually reported.
        #expect(requests.map(\.totalKind) == [.derived, .derived])
        #expect(result.diagnostics.inconsistentRecords == 0)
    }

    @Test("C6: a counter-reset epoch distinguishes repeated values at one instant")
    func counterResetEpochDistinguishesRepeatedReading() async throws {
        let dir = try makeTempDir("c6-epoch")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        \(header)
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 1_000, lastTotal: 1_000))
        {"type":"compacted","timestamp":"2026-10-19T10:00:01.000Z","payload":{"message":"summary"}}
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 1_000, lastTotal: 1_000))
        """, "rollout-epoch.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let requests = requestRecords(result)
        // The compacted marker starts a new counter segment. The same figures
        // in a later segment are a new observation, not a duplicate.
        #expect(requests.count == 2)
        #expect(Set(requests.map(\.recordId)).count == 2)
    }

    @Test("C6: a duplicated notification stays one observation")
    func duplicatedNotificationStaysOne() async throws {
        let dir = try makeTempDir("c6-duplicate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 1_000, lastTotal: 1_000)
        _ = try write("\(header)\n\(line)\n\(line)\n", "rollout-duplicate.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(requestRecords(result).count == 1)
        #expect(result.diagnostics.inconsistentRecords == 0)
    }

    @Test("C6: a fork copying both shapes is still two requests")
    func forkCopyingBothShapesStaysTwoRequests() async throws {
        let dir = try makeTempDir("c6-fork")
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = """
        \(header)
        \(requestLine(at: "2026-10-19T10:00:00.000Z", responseId: "resp_fork_one", cumulativeTotal: 500, total: 500))
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 500, lastTotal: 500))
        \(requestLine(at: "2026-10-19T10:00:00.000Z", responseId: "resp_fork_two", cumulativeTotal: 1_000, total: 500))
        \(eventLine(at: "2026-10-19T10:00:00.000Z", cumulativeTotal: 1_000, lastTotal: 500))
        """
        _ = try write(body, "rollout-fork-parent.jsonl", in: dir)
        _ = try write(body, "rollout-fork-copy.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let requests = requestRecords(result)
        #expect(requests.count == 2)
        #expect(requests.map(\.totalTokens) == [500, 500])
        #expect(Set(requests.map(\.recordId)) == ["response_resp_fork_one", "response_resp_fork_two"])
    }
}
