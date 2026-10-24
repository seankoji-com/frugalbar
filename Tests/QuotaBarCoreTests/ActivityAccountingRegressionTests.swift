import Foundation
import Testing
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

/// R1–R6 regressions for the activity ledger. These are written against the
/// observable adapter/store surface first, before the ledger change, so the
/// three reported defects can be reproduced red against the unchanged base.
@Suite("Activity accounting regressions")
struct ActivityAccountingRegressionTests {

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

    private let iso = ISO8601DateFormatter()

    private func date(_ text: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: text) { return parsed }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        // Fixtures are authored in this file; a malformed one is a test bug.
        return standard.date(from: text)!
    }

    // MARK: - F1: the real turn_context shape

    @Test("Codex reads the model from a top-level turn_context")
    func codexReadsTopLevelTurnContextModel() async throws {
        let dir = try makeTempDir("codex-turn-context")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-20T00:00:00.000Z","payload":{"session_id":"sess-turn","cwd":"/repo/codex","model_provider":"openai"}}
        {"type":"turn_context","timestamp":"2026-10-20T00:00:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/codex"}}
        {"type":"event_msg","timestamp":"2026-10-20T00:01:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":20,"total_tokens":120}}}}
        """, "rollout-session-turn.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let record = try #require(result.records.first)
        #expect(record.model == "gpt-6.1-sol")
    }

    // MARK: - F2: cached input is a subset, not an extra component

    @Test("Codex's derived total does not add cached input twice")
    func codexDerivedTotalDoesNotAddCachedInput() async throws {
        let dir = try makeTempDir("codex-cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-20T00:00:00.000Z","payload":{"session_id":"sess-cache","cwd":"/repo/codex"}}
        {"type":"turn_context","timestamp":"2026-10-20T00:00:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/codex"}}
        {"type":"event_msg","timestamp":"2026-10-20T00:01:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":20}}}}
        """, "rollout-session-cache.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let record = try #require(result.records.first)
        #expect(record.inputTokens == 100)
        #expect(record.cacheReadTokens == 60)
        #expect(record.totalTokens == 120, "input includes cached input; it must not be added again")
    }

    // MARK: - F3: request usage keeps its observed time

    @Test("Codex request usage stays in the day it was observed")
    func codexRequestUsageKeepsObservedDays() async throws {
        let dir = try makeTempDir("codex-resume")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-19T23:59:00.000Z","payload":{"session_id":"sess-resume","cwd":"/repo/codex"}}
        {"type":"turn_context","timestamp":"2026-10-19T23:59:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/codex"}}
        {"type":"token_usage_record","timestamp":"2026-10-19T23:59:30.000Z","payload":{"session_id":"sess-resume","thread_id":"sess-resume","response_id":"resp_monday","turn_id":"turn_monday","usage":{"input_tokens":700000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":300000,"reasoning_output_tokens":0,"total_tokens":1000000},"thread_token_usage":{"input_tokens":700000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":300000,"reasoning_output_tokens":0,"total_tokens":1000000}}}
        {"type":"token_usage_record","timestamp":"2026-10-20T00:00:30.000Z","payload":{"session_id":"sess-resume","thread_id":"sess-resume","response_id":"resp_tuesday","turn_id":"turn_tuesday","usage":{"input_tokens":70000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":30000,"reasoning_output_tokens":0,"total_tokens":100000},"thread_token_usage":{"input_tokens":770000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":330000,"reasoning_output_tokens":0,"total_tokens":1100000}}}
        """, "rollout-session-resume.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(result.records.count == 2)
        #expect(result.records.map(\.observedAt) == [
            date("2026-10-19T23:59:30Z"), date("2026-10-20T00:00:30Z")
        ])
        #expect(result.records.map(\.totalTokens) == [1_000_000, 100_000])
    }
}

// MARK: - R2/R3/R4/R5 regressions

extension ActivityAccountingRegressionTests {

    private func append(_ text: String, to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + text).write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeStore(_ dir: URL) -> QuotaHistoryStore {
        QuotaHistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite3"), isTestHost: true)
    }

    private func requestLine(
        _ response: String,
        session: String,
        timestamp: String,
        input: Int,
        cached: Int,
        output: Int,
        total: Int?,
        threadTotal: Int,
        model: String = "gpt-6.1-sol"
    ) -> String {
        let totalField = total.map { ",\"total_tokens\":\($0)" } ?? ""
        return """
        {"type":"token_usage_record","timestamp":"\(timestamp)","payload":{"session_id":"\(session)","thread_id":"\(session)","response_id":"\(response)","turn_id":"turn-\(response)","usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0\(totalField)},"thread_token_usage":{"input_tokens":\(input),"output_tokens":\(output),"total_tokens":\(threadTotal)}}}
        """
    }

    @Test("a duplicated response across two files is one request, at its original time")
    func codexDeduplicatesAcrossFiles() async throws {
        let dir = try makeTempDir("codex-fork")
        defer { try? FileManager.default.removeItem(at: dir) }
        let monday = "2026-10-19T10:00:00.000Z"
        let tuesday = "2026-10-20T10:00:00.000Z"
        let shared = """
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-fork","cwd":"/repo/fork"}}
        {"type":"turn_context","timestamp":"2026-10-19T09:59:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/fork"}}
        \(requestLine("resp_shared", session: "sess-fork", timestamp: monday, input: 900, cached: 800, output: 100, total: 1000, threadTotal: 1000))
        """
        _ = try write(shared, "rollout-parent.jsonl", in: dir)
        let fork = """
        {"type":"session_meta","timestamp":"2026-10-20T09:59:00.000Z","payload":{"session_id":"sess-fork-copy","cwd":"/repo/fork","parent_thread_id":"sess-fork"}}
        {"type":"turn_context","timestamp":"2026-10-20T09:59:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/fork"}}
        \(requestLine("resp_shared", session: "sess-fork-copy", timestamp: monday, input: 900, cached: 800, output: 100, total: 1000, threadTotal: 1000))
        \(requestLine("resp_new", session: "sess-fork-copy", timestamp: tuesday, input: 90, cached: 80, output: 10, total: 100, threadTotal: 1100))
        """
        _ = try write(fork, "rollout-fork.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(result.records.filter { $0.recordId == "response_resp_shared" }.count == 1)
        #expect(result.records.count == 2)
        let sharedRecord = try #require(result.records.first { $0.recordId == "response_resp_shared" })
        #expect(sharedRecord.observedAt == date(monday))
        #expect(result.diagnostics.inconsistentRecords == 0)
    }

    @Test("counter restart and compaction keep observations without inventing a gap")
    func codexCounterRestartDoesNotFabricateUsage() async throws {
        let dir = try makeTempDir("codex-restart")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-restart","cwd":"/repo/restart"}}
        {"type":"turn_context","timestamp":"2026-10-19T09:59:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/restart"}}
        \(requestLine("resp_before", session: "sess-restart", timestamp: "2026-10-19T10:00:00.000Z", input: 900, cached: 0, output: 100, total: 1000, threadTotal: 1000))
        {"type":"compacted","timestamp":"2026-10-19T10:01:00.000Z","payload":{"message":"summary"}}
        \(requestLine("resp_after", session: "sess-restart", timestamp: "2026-10-19T10:02:00.000Z", input: 25, cached: 0, output: 25, total: 50, threadTotal: 50))
        """, "rollout-restart.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(result.records.map(\.totalTokens) == [1_000, 50])
        #expect(result.records.allSatisfy { $0.totalKind == .published })
        #expect(result.diagnostics.inconsistentRecords == 0)
        // The gap between the pre-compaction counter and the reset one is not
        // usage: no record is synthesised for it.
        #expect(result.records.count == 2)
    }

    @Test("an inconsistent cumulative counter is reported, not turned into usage")
    func codexInconsistentCounterIsDiagnostic() async throws {
        let dir = try makeTempDir("codex-inconsistent")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-bad","cwd":"/repo/bad"}}
        \(requestLine("resp_ok", session: "sess-bad", timestamp: "2026-10-19T09:59:30.000Z", input: 90, cached: 0, output: 10, total: 100, threadTotal: 100))
        \(requestLine("resp_bad", session: "sess-bad", timestamp: "2026-10-19T10:00:00.000Z", input: 40, cached: 0, output: 10, total: 50, threadTotal: 250))
        """, "rollout-bad.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(result.records.map(\.totalTokens) == [100, 50])
        #expect(result.diagnostics.inconsistentRecords == 1)
    }

    @Test("malformed and partial usage stays unknown or partial, never zero")
    func codexMalformedAndPartial() async throws {
        let dir = try makeTempDir("codex-malformed")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-partial","cwd":"/repo/partial"}}
        not json at all
        {"type":"token_usage_record","timestamp":"2026-10-19T10:00:00.000Z","payload":{"session_id":"sess-partial","response_id":"resp_partial","usage":{"input_tokens":-5,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5}}}
        """, "rollout-partial.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let record = try #require(result.records.first)
        #expect(record.inputTokens == nil)
        #expect(record.outputTokens == 20)
        #expect(record.totalTokens == 20)
        #expect(record.totalKind == .partial)
        #expect(result.diagnostics.malformedRecords == 2) // the non-JSON line and the negative field
        #expect(result.diagnostics.incompleteRecords == 1)
    }

    @Test("re-ingestion and a later resumed day do not move earlier usage")
    func codexResumeAndReingestIdempotent() async throws {
        let dir = try makeTempDir("codex-resume-store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let file = try write("""
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-store","cwd":"/repo/store"}}
        {"type":"turn_context","timestamp":"2026-10-19T09:59:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/store"}}
        \(requestLine("resp_m", session: "sess-store", timestamp: "2026-10-19T23:59:30.000Z", input: 700000, cached: 0, output: 300000, total: 1000000, threadTotal: 1000000))
        \(requestLine("resp_t", session: "sess-store", timestamp: "2026-10-20T00:00:30.000Z", input: 70000, cached: 0, output: 30000, total: 100000, threadTotal: 1100000))
        """, "rollout-store.jsonl", in: dir)
        let adapter = CodexAdapter(baseURL: dir)
        let engine = ActivityIngestionEngine(store: store, adapters: [adapter])

        #expect(try await engine.ingestAll() == 2)
        #expect(try await engine.ingestAll() == 0)

        let day = ISO8601DateFormatter().date(from: "2026-10-19T00:00:00Z")!
        let usage = try await store.fetchTokenUsage(
            since: day, until: day.addingTimeInterval(2 * 86_400),
            bucketSeconds: 86_400, anchor: day)
        let codex = usage.buckets.filter { $0.source == "codex" }
        #expect(codex.map(\.tokens) == [1_000_000, 100_000])
        #expect(codex.map(\.start) == [day, day.addingTimeInterval(86_400)])
        #expect(usage.sessionTotalRecords["codex"] == nil)

        // A third day appended to the same file: only the new request is
        // ingested, and the first two keep their original times.
        let third = requestLine("resp_w", session: "sess-store", timestamp: "2026-10-21T12:00:00.000Z",
                                input: 7, cached: 0, output: 3, total: 10, threadTotal: 1100010)
        try append("\n" + third + "\n", to: file)
        // Codex re-reads a changed rollout from the start; storage replaces
        // each stable request id, so the count is three, not four or five.
        #expect(try await engine.ingestAll() == 3)
        let after = try await store.fetchActivities(source: "codex")
        #expect(after.count == 3)
        #expect(after.first { $0.recordId == "response_resp_m" }?.observedAt == date("2026-10-19T23:59:30Z"))
    }

    @Test("a partial request set keeps the legacy total until its tokens are fully reconstructed")
    func legacyCoexistenceAndPreservedHistory() async throws {
        let dir = try makeTempDir("legacy-migration")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        // Ensure every table exists before raw seeding.
        _ = try await store.fetchActivities()
        let aggregateObservedAt = Int64(date("2026-10-20T12:00:00Z").timeIntervalSince1970)

        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("history.sqlite3").path, &db) == SQLITE_OK)
        let raw = try #require(db)
        defer { sqlite3_close(raw) }
        let legacy = """
        INSERT INTO activity (source, record_id, session_id, project_path, git_branch, model,
            observed_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens)
        VALUES ('codex','codex_legacy-session','legacy-session','/repo/legacy','main','gpt-5',
            \(aggregateObservedAt), 500, 500, 0, 0, 1000);
        INSERT INTO reading (vendor, bar_label, measured_at, fraction, is_blocked, confidence, urgency,
            resets_at, window_length, elapsed_only)
        VALUES ('claude','5H',1700000000,0.4,0,'measured','none',NULL,NULL,0);
        INSERT INTO balance_reading (series_id, vendor, label, unit, measured_at, value)
        VALUES ('openrouter|currency:USD','openrouter','Balance','currency:USD',1700000000,'12.34');
        """
        #expect(sqlite3_exec(raw, legacy, nil, nil, nil) == SQLITE_OK)

        let before = try await store.fetchActivities()
        #expect(before.count == 1)
        #expect(before.first?.totalKind == .legacy)
        #expect(before.first?.granularity == .session)

        // One 100-token request inside a 1000-token session aggregate is not
        // proof that the other 900 were reconstructed. The aggregate stays
        // visible, the request is not added to it, and nothing is invented.
        func request(_ id: String, at: String, tokens: Int) -> ActivityRecord {
            ActivityRecord(
                source: "codex",
                recordId: id,
                sessionId: "legacy-session",
                projectPath: "/repo/legacy",
                model: "gpt-6.1-sol",
                observedAt: date(at),
                inputTokens: tokens, outputTokens: 0, totalTokens: tokens,
                semantics: .cacheIncludedInInput)
        }
        try await store.recordActivities([request("response_legacy_a", at: "2026-10-20T10:00:00Z", tokens: 100)])

        let partial = try await store.fetchActivities()
        #expect(partial.count == 1)
        #expect(partial.first?.recordId == "codex_legacy-session")
        #expect(partial.first?.totalTokens == 1_000)
        #expect(partial.first?.totalKind == .legacy)

        // Completing the reconstruction proves coverage: the aggregate is
        // superseded by its request rows, and the total is still 1000.
        try await store.recordActivities([request("response_legacy_b", at: "2026-10-20T11:00:00Z", tokens: 900)])

        let after = try await store.fetchActivities()
        #expect(after.map(\.recordId).sorted() == ["response_legacy_a", "response_legacy_b"])
        #expect(after.map { $0.totalTokens ?? 0 }.reduce(0, +) == 1_000)

        let tokenUsage = try await store.fetchTokenUsage(
            since: date("2023-01-01T00:00:00Z"), until: date("2027-01-01T00:00:00Z"),
            bucketSeconds: 30 * 86_400, anchor: date("2023-01-01T00:00:00Z"))
        #expect(tokenUsage.buckets.filter { $0.source == "codex" }.map(\.tokens).reduce(0, +) == 1_000)

        // The legacy row and both requests are retained, not rewritten or
        // deleted; the view is the only place coexistence is decided.
        var verify: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("history.sqlite3").path, &verify) == SQLITE_OK)
        let check = try #require(verify)
        defer { sqlite3_close(check) }
        func count(_ table: String) -> Int {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(check, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
        }
        #expect(count("activity") == 1)
        #expect(count("activity_request") == 2)
        #expect(HistorySchema.version == 1)

        // Quota and balance history is untouched by the activity ledger.
        let readings = try await store.fetchReadings(vendor: .claude, since: date("2023-11-14T00:00:00Z"))
        #expect(readings.contains { $0.barLabel == "5H" && $0.fraction == 0.4 })
        let balances = try await store.fetchBalanceSeries(
            since: date("2023-11-14T00:00:00Z"), until: date("2026-10-24T00:00:00Z"),
            bucketSeconds: 86_400, seriesIds: ["openrouter|currency:USD"])
        #expect(balances["openrouter|currency:USD"]?.last?.value == Decimal(string: "12.34"))

        // A restart reads the same reconciled answer.
        let reopened = QuotaHistoryStore(
            databaseURL: dir.appendingPathComponent("history.sqlite3"), isTestHost: true)
        let restarted = try await reopened.fetchActivities()
        #expect(restarted.map(\.recordId).sorted() == ["response_legacy_a", "response_legacy_b"])
    }

    @Test("per-source diagnostics survive an unchanged-file skip")
    func sourceStatusRetainedAcrossSkip() async throws {
        let dir = try makeTempDir("source-status")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-status","cwd":"/repo/status"}}
        not json
        \(requestLine("resp_status", session: "sess-status", timestamp: "2026-10-19T10:00:00.000Z", input: 90, cached: 0, output: 10, total: 100, threadTotal: 100))
        """, "rollout-status.jsonl", in: dir)
        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: dir)])

        _ = try await engine.ingestAll()
        let first = try #require(await engine.status().status(for: "codex"))
        #expect(first.malformedRecords == 1)
        #expect(first.lastSuccessfulScanAt != nil)
        #expect(first.lastPassComplete)

        // Nothing changed: the file is skipped, and the count must not vanish.
        #expect(try await engine.ingestAll() == 0)
        let second = try #require(await engine.status().status(for: "codex"))
        #expect(second.malformedRecords == 1)
        #expect(second.lastSuccessfulScanAt != nil)

        // A relaunch reads the retained status before running anything.
        let relaunched = ActivityIngestionEngine(store: makeStore(dir), adapters: [])
        let persisted = try #require(await relaunched.status().status(for: "codex"))
        #expect(persisted.malformedRecords == 1)
        #expect(await relaunched.status().hasCompletedCleanPass == false)
    }

    @Test("tool identity is not billing identity, and OpenCode is not assigned to a workspace")
    func openCodeProvenanceIsNotAWorkspace() async throws {
        let dir = try makeTempDir("opencode-provenance")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let raw = try #require(db)
        sqlite3_exec(raw, """
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
        """, nil, nil, nil)
        let data = #"{"providerID":"litellm","modelID":"gpt-5.6-luna","path":{"cwd":"/repo/alpha"},"tokens":{"input":100,"output":20,"cache":{"read":5,"write":2},"total":127},"time":{"created":1700000000000}}"#
        let insert = "INSERT INTO message VALUES ('msg_prov','sess_prov',1700000000000,1700000000000,?);"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(raw, insert, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, data, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        sqlite3_close(raw)

        let record = try #require(try await OpenCodeAdapter(databaseURL: dbURL)
            .collectActivities(watermarks: [:]).records.first)
        #expect(record.source == "opencode")
        #expect(record.billingProvider == "litellm")
        #expect(record.accountId == nil)
        #expect(record.workspaceId == nil)
        #expect(record.totalTokens == 127)
        #expect(record.totalKind == .published)

        let any = AttributionEngine.computeAttribution(
            windowStart: date("2023-01-01T00:00:00Z"), windowEnd: date("2026-01-01T00:00:00Z"),
            startConsumptionFraction: nil, endConsumptionFraction: nil,
            activities: [record])
        #expect(any.projectAttributions.map(\.projectPath) == ["/repo/alpha"])
        #expect(any.publishedBillingProviders == ["litellm"])

        let workspaceScoped = AttributionEngine.computeAttribution(
            windowStart: date("2023-01-01T00:00:00Z"), windowEnd: date("2026-01-01T00:00:00Z"),
            startConsumptionFraction: nil, endConsumptionFraction: nil,
            activities: [record],
            billingScope: .matchingPublishedIdentity(AttributionBillingTarget()))
        #expect(workspaceScoped.projectAttributions.isEmpty)
        #expect(workspaceScoped.totalObservedTokens == 0)
        #expect(workspaceScoped.recordsWithoutMatchingBillingIdentity == 1)
        #expect(workspaceScoped.caveats.contains(.unverifiedBillingIdentity))
    }
}

extension ActivityAccountingRegressionTests {
    @Test("an upgrade re-reads unchanged Codex rollouts once to build the request ledger")
    func upgradeRebuildsUnchangedCodexRollouts() async throws {
        let dir = try makeTempDir("codex-upgrade")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-upgrade","cwd":"/repo/upgrade"}}
        {"type":"turn_context","timestamp":"2026-10-19T09:59:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/upgrade"}}
        \(requestLine("resp_upgrade_a", session: "sess-upgrade", timestamp: "2026-10-19T10:00:00.000Z", input: 90, cached: 0, output: 10, total: 100, threadTotal: 100))
        \(requestLine("resp_upgrade_b", session: "sess-upgrade", timestamp: "2026-10-19T10:01:00.000Z", input: 40, cached: 0, output: 10, total: 50, threadTotal: 150))
        """, "rollout-upgrade.jsonl", in: sessions)

        // The pre-ledger state: a session aggregate plus a watermark saying the
        // unchanged rollout was already read.
        _ = try await store.fetchActivities()
        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("history.sqlite3").path, &db) == SQLITE_OK)
        let raw = try #require(db)
        defer { sqlite3_close(raw) }
        // The aggregate's recorded turn is the session's last token count;
        // the two request rows reconstruct exactly that total.
        let aggregateObservedAt = Int64(date("2026-10-19T10:01:30Z").timeIntervalSince1970)
        #expect(sqlite3_exec(raw, """
        INSERT INTO activity (source, record_id, session_id, project_path, observed_at,
            input_tokens, output_tokens, total_tokens)
        VALUES ('codex','codex_sess-upgrade','sess-upgrade','/repo/upgrade',\(aggregateObservedAt),130,20,150);
        """, nil, nil, nil) == SQLITE_OK)
        // Use the exact path spelling the adapter's enumerator yields: on
        // macOS the temporary directory is reached through `/private/var`.
        let enumerated = try #require(
            FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil)?
                .nextObject() as? URL)
        let values = try enumerated.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try await store.setWatermark(
            source: "codex", filePath: enumerated.path,
            fileSize: Int64(values.fileSize ?? 0),
            modifiedAt: Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970),
            byteOffset: Int64(values.fileSize ?? 0))
        #expect(try await store.hasActivityRequests(source: "codex") == false)
        let storedWatermarks = try await store.watermarks(for: "codex")
        #expect(storedWatermarks.count == 1)
        #expect(try await CodexAdapter(baseURL: sessions)
            .collectActivities(watermarks: storedWatermarks).records.isEmpty)

        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: sessions)])
        #expect(try await engine.ingestAll() == 2)
        #expect(try await store.hasActivityRequests(source: "codex"))

        let rows = try await store.fetchActivities(source: "codex")
        #expect(rows.map(\.recordId).sorted() == ["response_resp_upgrade_a", "response_resp_upgrade_b"])
        #expect(rows.compactMap(\.totalTokens).reduce(0, +) == 150)
    }
}

extension ActivityAccountingRegressionTests {
    @Test("opening a version-1 database adds the ledger without dropping history")
    func additiveMigrationFromVersionOne() async throws {
        let dir = try makeTempDir("schema-v1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite3")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let raw = try #require(db)
        defer { sqlite3_close(raw) }
        #expect(sqlite3_exec(raw, """
        CREATE TABLE reading (
          vendor TEXT NOT NULL, bar_label TEXT NOT NULL, measured_at INTEGER NOT NULL,
          fraction REAL, is_blocked INTEGER NOT NULL, confidence TEXT NOT NULL,
          urgency TEXT NOT NULL, resets_at INTEGER, window_length INTEGER,
          elapsed_only INTEGER NOT NULL, PRIMARY KEY (vendor, bar_label, measured_at)
        ) WITHOUT ROWID;
        CREATE TABLE activity (
          source TEXT NOT NULL, record_id TEXT NOT NULL, session_id TEXT NOT NULL,
          project_path TEXT, git_branch TEXT, model TEXT, observed_at INTEGER NOT NULL,
          input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
          cache_write_tokens INTEGER, total_tokens INTEGER,
          PRIMARY KEY (source, record_id)
        ) WITHOUT ROWID;
        CREATE TABLE ingest_watermark (
          source TEXT NOT NULL, file_path TEXT NOT NULL, file_size INTEGER NOT NULL,
          modified_at INTEGER NOT NULL, byte_offset INTEGER NOT NULL,
          PRIMARY KEY (source, file_path)
        ) WITHOUT ROWID;
        INSERT INTO activity VALUES ('claude_code','old-msg','old-session','/repo/old','main','claude',
          1700000000,10,20,5,15,50);
        INSERT INTO reading VALUES ('claude','5H',1700000000,0.25,0,'measured','none',NULL,NULL,0);
        PRAGMA user_version = 1;
        """, nil, nil, nil) == SQLITE_OK)

        let store = QuotaHistoryStore(databaseURL: url, isTestHost: true)
        let migrated = try await store.fetchActivities()
        #expect(migrated.count == 1)
        #expect(migrated.first?.recordId == "old-msg")
        #expect(migrated.first?.totalTokens == 50)
        #expect(migrated.first?.totalKind == .legacy)
        #expect(try await store.fetchReadings(
            vendor: .claude, since: date("2023-11-14T00:00:00Z")).count == 1)
        #expect(HistorySchema.version == 1)

        // The new ledger is present and writable after the same open.
        try await store.recordActivities([ActivityRecord(
            source: "claude_code", recordId: "new-msg", sessionId: "new-session",
            projectPath: "/repo/new", observedAt: date("2026-10-20T00:00:00Z"),
            inputTokens: 1, outputTokens: 2)])
        #expect(try await store.fetchActivities().count == 2)
    }
}
