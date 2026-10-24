import Foundation
import Testing
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

/// C1–C5 regressions for the coordinator's source findings against
/// 75fff2eda9dfee326cdd104661676b0dd03eac65. Each test exercises the public
/// adapter, store or attribution seam the defect was observed through.
@Suite("Activity source repair regressions")
struct ActivitySourceRepairTests {

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

    private func date(_ text: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: text) { return parsed }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: text)!
    }

    private func makeStore(_ dir: URL) -> QuotaHistoryStore {
        QuotaHistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite3"), isTestHost: true)
    }

    private func tokenCountLine(
        at timestamp: String,
        cumulative: (input: Int, cached: Int, output: Int, total: Int),
        last: (input: Int, cached: Int, output: Int, total: Int)
    ) -> String {
        let cumulativeUsage = """
        {"input_tokens":\(cumulative.input),"cached_input_tokens":\(cumulative.cached),\
        "cache_write_input_tokens":0,"output_tokens":\(cumulative.output),\
        "reasoning_output_tokens":0,"total_tokens":\(cumulative.total)}
        """
        let lastUsage = """
        {"input_tokens":\(last.input),"cached_input_tokens":\(last.cached),\
        "cache_write_input_tokens":0,"output_tokens":\(last.output),\
        "reasoning_output_tokens":0,"total_tokens":\(last.total)}
        """
        return """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count",\
        "info":{"total_token_usage":\(cumulativeUsage),"last_token_usage":\(lastUsage)}}}
        """
    }
}

// MARK: - C1: exact integer parsing

extension ActivitySourceRepairTests {

    private func usageLine(_ input: String, _ output: String = "1") -> String {
        """
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-bounds","cwd":"/repo/bounds"}}
        {"type":"token_usage_record","timestamp":"2026-10-19T10:00:00.000Z","payload":{"session_id":"sess-bounds","response_id":"resp_bounds","usage":{"input_tokens":\(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0}}}
        """
    }

    @Test("C1: the largest valid integer is read exactly, never through Double")
    func codexReadsIntMaxExactly() async throws {
        let dir = try makeTempDir("codex-int-max")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write(usageLine("9223372036854775807", "0"), "rollout-bounds.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let record = try #require(result.records.first)
        // Int.max is a representable non-negative count and must survive as
        // itself. `Int(Double(Int.max))` traps, which is the defect.
        #expect(record.inputTokens == Int.max)
        #expect(result.diagnostics.malformedRecords == 0)
    }

    @Test("C1: values above Int.max are unknown, not a trap or a wrapped figure")
    func codexRejectsAboveIntMax() async throws {
        let dir = try makeTempDir("codex-int-over")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write(usageLine("9223372036854775808", "0"), "rollout-over.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let record = try #require(result.records.first)
        #expect(record.inputTokens == nil)
        #expect(record.totalTokens == 0)
        #expect(result.diagnostics.malformedRecords == 1)
    }

    @Test("C1: values below Int.min are unknown, not a wrapped count")
    func codexRejectsBelowIntMin() async throws {
        let dir = try makeTempDir("codex-int-under")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write(usageLine("-9223372036854775809", "0"), "rollout-under.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let record = try #require(result.records.first)
        #expect(record.inputTokens == nil)
        #expect(result.diagnostics.malformedRecords == 1)
    }

    @Test("C1: integers above 2^53 keep every digit")
    func codexKeepsPrecisionAboveTwoTo53() async throws {
        let dir = try makeTempDir("codex-int-precision")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write(usageLine("9007199254740993", "0"), "rollout-precision.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let record = try #require(result.records.first)
        // Double(9007199254740993) is 9007199254740992: a silent loss.
        #expect(record.inputTokens == 9_007_199_254_740_993)
        #expect(record.totalTokens == 9_007_199_254_740_993)
        #expect(result.diagnostics.malformedRecords == 0)
    }

    @Test("C1: fractional counts remain malformed, not truncated")
    func codexRejectsFractionalCounts() async throws {
        let dir = try makeTempDir("codex-int-fractional")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write(usageLine("1.5", "0"), "rollout-fractional.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        let record = try #require(result.records.first)
        #expect(record.inputTokens == nil)
        #expect(result.diagnostics.malformedRecords == 1)
    }
}

// MARK: - C2: per-request last_token_usage

extension ActivitySourceRepairTests {

    private var lastUsageSessionHeader: String {
        """
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-last","cwd":"/repo/last"}}
        {"type":"turn_context","timestamp":"2026-10-19T09:59:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/last"}}
        """
    }

    private func twoDayLastUsageFile() -> String {
        """
        \(lastUsageSessionHeader)
        \(tokenCountLine(at: "2026-10-19T10:00:00.000Z",
                         cumulative: (900, 800, 100, 1000), last: (900, 800, 100, 1000)))
        {"type":"turn_context","timestamp":"2026-10-20T09:59:01.000Z","payload":{"model":"gpt-5.6-luna","cwd":"/repo/last"}}
        \(tokenCountLine(at: "2026-10-20T10:00:00.000Z",
                         cumulative: (990, 890, 110, 1100), last: (90, 10, 10, 100)))
        """
    }

    @Test("C2: event_msg last_token_usage is stored as its own request on its own day")
    func codexReadsLastTokenUsagePerRequest() async throws {
        let dir = try makeTempDir("codex-last-usage")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write(twoDayLastUsageFile(), "rollout-last.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(result.records.count == 2)
        #expect(result.records.allSatisfy { $0.granularity == .request })
        #expect(result.records.map(\.totalTokens) == [1_000, 100])
        #expect(result.records.map(\.observedAt) == [
            date("2026-10-19T10:00:00Z"), date("2026-10-20T10:00:00Z")
        ])
        #expect(result.records.map(\.model) == ["gpt-6.1-sol", "gpt-5.6-luna"])
        #expect(result.diagnostics.inconsistentRecords == 0)
    }

    @Test("C2: mixed token_usage_record and event_msg forms do not double count")
    func codexDeduplicatesMixedFormats() async throws {
        let dir = try makeTempDir("codex-last-mixed")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        \(lastUsageSessionHeader)
        {"type":"token_usage_record","timestamp":"2026-10-19T10:00:00.000Z","payload":{"session_id":"sess-last","thread_id":"sess-last","response_id":"resp_first","usage":{"input_tokens":900,"cached_input_tokens":800,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1000},"thread_token_usage":{"total_tokens":1000}}}
        \(tokenCountLine(at: "2026-10-19T10:00:00.000Z",
                         cumulative: (900, 800, 100, 1000), last: (900, 800, 100, 1000)))
        {"type":"turn_context","timestamp":"2026-10-20T09:59:01.000Z","payload":{"model":"gpt-5.6-luna","cwd":"/repo/last"}}
        \(tokenCountLine(at: "2026-10-20T10:00:00.000Z",
                         cumulative: (990, 890, 110, 1100), last: (90, 10, 10, 100)))
        """, "rollout-mixed.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(result.records.count == 2)
        #expect(result.records.map(\.totalTokens) == [1_000, 100])
        #expect(result.records.map(\.model) == ["gpt-6.1-sol", "gpt-5.6-luna"])
    }

    @Test("C2: event_msg request rows keep their own days in the store")
    func lastUsageKeepsStoreDayBuckets() async throws {
        let dir = try makeTempDir("codex-last-store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        _ = try write(twoDayLastUsageFile(), "rollout-last.jsonl", in: sessions)

        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: sessions)])
        #expect(try await engine.ingestAll() == 2)
        #expect(try await engine.ingestAll() == 0)

        let day = ISO8601DateFormatter().date(from: "2026-10-19T00:00:00Z")!
        let usage = try await store.fetchTokenUsage(
            since: day, until: day.addingTimeInterval(2 * 86_400),
            bucketSeconds: 86_400, anchor: day)
        #expect(usage.buckets.filter { $0.source == "codex" }.map(\.tokens) == [1_000, 100])
        #expect(usage.sessionTotalRecords["codex"] == nil)
    }

    @Test("C2: a forked rollout copying event_msg usage is one request, not two")
    func codexDeduplicatesLastUsageAcrossForks() async throws {
        let dir = try makeTempDir("codex-last-fork")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write(twoDayLastUsageFile(), "rollout-parent.jsonl", in: dir)
        _ = try write(twoDayLastUsageFile(), "rollout-copy.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(result.records.count == 2)
        #expect(result.records.allSatisfy { $0.granularity == .request })
        #expect(result.records.map(\.totalTokens) == [1_000, 100])
        #expect(result.diagnostics.inconsistentRecords == 0)
    }

    @Test("C2: a counter restart or compaction keeps last usage without inventing a gap")
    func codexLastUsageAcrossRestart() async throws {
        let dir = try makeTempDir("codex-last-restart")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("""
        \(lastUsageSessionHeader)
        \(tokenCountLine(at: "2026-10-19T10:00:00.000Z",
                         cumulative: (900, 800, 100, 1000), last: (900, 800, 100, 1000)))
        {"type":"compacted","timestamp":"2026-10-19T10:01:00.000Z","payload":{"message":"summary"}}
        \(tokenCountLine(at: "2026-10-19T10:02:00.000Z",
                         cumulative: (25, 0, 25, 50), last: (25, 0, 25, 50)))
        """, "rollout-restart.jsonl", in: dir)

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        // The request's own published figures are already exact; a counter
        // restart is not usage. Only two observations exist.
        #expect(result.records.count == 2)
        #expect(result.records.map(\.totalTokens) == [1_000, 50])
        #expect(result.records.map(\.observedAt) == [
            date("2026-10-19T10:00:00Z"), date("2026-10-19T10:02:00Z")
        ])
        #expect(result.diagnostics.inconsistentRecords == 0)
    }
}

// MARK: - C3: proven reconciliation before superseding legacy totals

extension ActivitySourceRepairTests {

    private func seedLegacyAggregate(
        in dir: URL,
        session: String = "sess-partial",
        observedAt: Int64,
        total: Int64
    ) async throws {
        let store = makeStore(dir)
        _ = try await store.fetchActivities()
        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("history.sqlite3").path, &db) == SQLITE_OK)
        let raw = try #require(db)
        defer { sqlite3_close(raw) }
        let sql = """
        INSERT INTO activity (source, record_id, session_id, project_path, git_branch, model,
            observed_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens)
        VALUES ('codex','codex_\(session)','\(session)','/repo/partial','main','gpt-6.1-sol',
            \(observedAt), 500, 500, 0, 0, \(total));
        """
        #expect(sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func partialRollout(requests: [(id: String, at: String, total: Int)]) -> String {
        var lines = [
            """
            {"type":"session_meta","timestamp":"2026-10-20T08:00:00.000Z","payload":{"session_id":"sess-partial","cwd":"/repo/partial"}}
            """,
            """
            {"type":"turn_context","timestamp":"2026-10-20T08:00:01.000Z","payload":{"model":"gpt-6.1-sol","cwd":"/repo/partial"}}
            """
        ]
        for request in requests {
            lines.append("""
            {"type":"token_usage_record","timestamp":"\(request.at)","payload":{"session_id":"sess-partial","thread_id":"sess-partial","response_id":"\(request.id)","usage":{"input_tokens":\(request.total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\(request.total)}}}
            """)
        }
        return lines.joined(separator: "\n")
    }

    @Test("C3: one surviving 100-token request does not erase a 1000-token legacy aggregate")
    func partialReconstructionDoesNotSuppressLegacyTotal() async throws {
        let dir = try makeTempDir("legacy-partial")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        // The aggregate's last observed turn is after the one request that
        // survived, so that request is provably inside it.
        try await seedLegacyAggregate(
            in: dir, observedAt: Int64(date("2026-10-20T10:00:00Z").timeIntervalSince1970), total: 1_000)
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        _ = try write(partialRollout(requests: [("resp_known", "2026-10-20T09:00:00.000Z", 100)]),
                      "rollout-partial.jsonl", in: sessions)

        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: sessions)])
        _ = try await engine.ingestAll()

        // The aggregate still covers the request that could not be
        // reconstructed; the known request is a subset, not a replacement.
        let visible = try await store.fetchActivities()
        #expect(visible.count == 1)
        #expect(visible.first?.recordId == "codex_sess-partial")
        #expect(visible.first?.totalTokens == 1_000)
        #expect(visible.first?.totalKind == .legacy)
        #expect(visible.map { $0.totalTokens ?? 0 }.reduce(0, +) == 1_000)

        // The observation is preserved, not deleted; it is simply not added to
        // the aggregate it is already inside.
        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("history.sqlite3").path, &db) == SQLITE_OK)
        let raw = try #require(db)
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM activity_request;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int64(stmt, 0) == 1)

        // Re-ingestion and a restart read the same answer.
        _ = try await engine.ingestAll()
        let reopened = QuotaHistoryStore(
            databaseURL: dir.appendingPathComponent("history.sqlite3"), isTestHost: true)
        let restarted = try await reopened.fetchActivities()
        #expect(restarted.count == 1)
        #expect(restarted.first?.totalTokens == 1_000)
    }

    @Test("C3: a fully reconstructed session supersedes its aggregate without double counting")
    func completeReconstructionSupersedesAggregate() async throws {
        let dir = try makeTempDir("legacy-complete")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        try await seedLegacyAggregate(
            in: dir, observedAt: Int64(date("2026-10-20T10:00:00Z").timeIntervalSince1970), total: 1_000)
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        _ = try write(partialRollout(requests: [
            ("resp_a", "2026-10-20T09:00:00.000Z", 600),
            ("resp_b", "2026-10-20T09:05:00.000Z", 400)
        ]), "rollout-complete.jsonl", in: sessions)

        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: sessions)])
        _ = try await engine.ingestAll()

        let visible = try await store.fetchActivities()
        #expect(visible.map(\.recordId).sorted() == ["response_resp_a", "response_resp_b"])
        #expect(visible.map { $0.totalTokens ?? 0 }.reduce(0, +) == 1_000)
        #expect(visible.allSatisfy { $0.totalKind == .published })
    }

    @Test("C3: a missing original keeps the legacy total, and requests after it add once")
    func missingOriginalKeepsLegacyAndLaterUsageAdds() async throws {
        let dir = try makeTempDir("legacy-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        try await seedLegacyAggregate(
            in: dir, observedAt: Int64(date("2026-10-20T10:00:00Z").timeIntervalSince1970), total: 1_000)
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        // The rollout only survives from after the aggregate's last turn.
        _ = try write(partialRollout(requests: [
            ("resp_later", "2026-10-20T12:00:00.000Z", 100)
        ]), "rollout-later.jsonl", in: sessions)

        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: sessions)])
        _ = try await engine.ingestAll()

        let visible = try await store.fetchActivities()
        #expect(visible.count == 2)
        #expect(visible.map { $0.totalTokens ?? 0 }.reduce(0, +) == 1_100)
        #expect(visible.contains { $0.recordId == "codex_sess-partial" && $0.totalTokens == 1_000 })
        #expect(visible.contains { $0.recordId == "response_resp_later" && $0.totalTokens == 100 })
    }
}

// MARK: - C5: billing identity must match the reported subject

extension ActivitySourceRepairTests {

    private func billingRecord(
        _ id: String,
        project: String,
        provider: String?,
        account: String?,
        workspace: String?
    ) -> ActivityRecord {
        ActivityRecord(
            source: "opencode",
            recordId: id,
            sessionId: "session-\(id)",
            projectPath: project,
            gitBranch: "main",
            model: "gpt-5.6-luna",
            observedAt: date("2026-10-20T10:00:00Z"),
            inputTokens: 90,
            outputTokens: 10,
            totalTokens: 100,
            publishedProvider: provider,
            accountHash: IdentityFingerprint.published(account, in: .account),
            workspaceHash: IdentityFingerprint.published(workspace, in: .workspace))
    }

    @Test("C5: a workspace target excludes another workspace's published usage")
    func workspaceTargetMatchesOnlyItsOwnIdentity() throws {
        let workspaceA = billingRecord(
            "a", project: "/repo/alpha", provider: "opencode-go",
            account: "account-a", workspace: "workspace-a")
        let workspaceB = billingRecord(
            "b", project: "/repo/beta", provider: "opencode-go",
            account: "account-b", workspace: "workspace-b")

        let summary = AttributionEngine.computeAttribution(
            windowStart: date("2026-10-01T00:00:00Z"),
            windowEnd: date("2026-10-31T00:00:00Z"),
            startConsumptionFraction: nil,
            endConsumptionFraction: nil,
            activities: [workspaceA, workspaceB],
            billingScope: .matchingPublishedIdentity(
                AttributionBillingTarget(
                    billingProvider: "opencode-go",
                    accountId: "account-a",
                    workspaceId: "workspace-a")))

        #expect(summary.projectAttributions.map(\.projectPath) == ["/repo/alpha"])
        #expect(summary.totalObservedTokens == 100)
        #expect(summary.recordsWithoutMatchingBillingIdentity == 1,
                "workspace B is published, but not for this subject")
        #expect(summary.caveats.contains(.unverifiedBillingIdentity))
    }

    @Test("C5: no correlation means no attribution, even when provider matches")
    func uncorrelatedTargetLeavesRecordsUnattributed() throws {
        let identified = billingRecord(
            "a", project: "/repo/alpha", provider: "litellm",
            account: "account-a", workspace: nil)
        let unpublished = billingRecord(
            "u", project: "/repo/unknown", provider: "litellm",
            account: nil, workspace: nil)

        for target in [
            AttributionBillingTarget(),
            AttributionBillingTarget(billingProvider: "litellm")
        ] {
            let summary = AttributionEngine.computeAttribution(
                windowStart: date("2026-10-01T00:00:00Z"),
                windowEnd: date("2026-10-31T00:00:00Z"),
                startConsumptionFraction: nil,
                endConsumptionFraction: nil,
                activities: [identified, unpublished],
                billingScope: .matchingPublishedIdentity(target))
            #expect(summary.projectAttributions.isEmpty)
            #expect(summary.totalObservedTokens == 0)
            #expect(summary.recordsWithoutMatchingBillingIdentity == 2)
        }
    }

    @Test("C5: a provider mismatch excludes an account that merely shares a name")
    func providerMismatchExcludesRecord() throws {
        let record = billingRecord(
            "a", project: "/repo/alpha", provider: "litellm",
            account: "account-a", workspace: nil)

        let summary = AttributionEngine.computeAttribution(
            windowStart: date("2026-10-01T00:00:00Z"),
            windowEnd: date("2026-10-31T00:00:00Z"),
            startConsumptionFraction: nil,
            endConsumptionFraction: nil,
            activities: [record],
            billingScope: .matchingPublishedIdentity(
                AttributionBillingTarget(
                    billingProvider: "opencode-go", accountId: "account-a")))

        #expect(summary.projectAttributions.isEmpty)
        #expect(summary.recordsWithoutMatchingBillingIdentity == 1)
    }

    @Test("C5: a matching identity keeps project, session and branch provenance")
    func matchingIdentityKeepsProvenance() async throws {
        let dir = try makeTempDir("attribution-provenance")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let record = billingRecord(
            "b", project: "/repo/beta", provider: "litellm",
            account: nil, workspace: "workspace-b")
        try await store.recordActivities([record])

        let fetched = try #require(try await store.fetchActivities(source: "opencode").first)
        #expect(fetched.projectPath == "/repo/beta")
        #expect(fetched.gitBranch == "main")
        #expect(fetched.workspaceHash == IdentityFingerprint.published("workspace-b", in: .workspace))

        let summary = AttributionEngine.computeAttribution(
            windowStart: date("2026-10-01T00:00:00Z"),
            windowEnd: date("2026-10-31T00:00:00Z"),
            startConsumptionFraction: nil,
            endConsumptionFraction: nil,
            activities: [fetched],
            billingScope: .matchingPublishedIdentity(
                AttributionBillingTarget(workspaceId: "workspace-b")))
        #expect(summary.projectAttributions.map(\.projectPath) == ["/repo/beta"])
        #expect(summary.projectAttributions.first?.sessionCount == 1)
        #expect(summary.recordsWithoutMatchingBillingIdentity == 0)
    }
}


extension ActivitySourceRepairTests {

    private func validRequest(_ id: String, at: String) -> String {
        """
        {"type":"token_usage_record","timestamp":"\(at)","payload":{"session_id":"sess-two","thread_id":"sess-two","response_id":"\(id)","usage":{"input_tokens":90,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":100}}}
        """
    }

    private func twoInputDirectory(_ dir: URL) throws -> URL {
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-two","cwd":"/repo/two"}}
        not json at all
        \(validRequest("resp_malformed_file", at: "2026-10-19T10:00:00.000Z"))
        """, "rollout-a.jsonl", in: sessions)
        _ = try write("""
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-two","cwd":"/repo/two"}}
        \(validRequest("resp_clean_file", at: "2026-10-19T10:00:00.000Z"))
        """, "rollout-b.jsonl", in: sessions)
        return sessions
    }

    @Test("C3: a partially reconstructed event_msg file keeps its published session total")
    func partialEventMsgKeepsSessionTotal() async throws {
        let dir = try makeTempDir("legacy-event-partial")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        _ = try write("""
        \(lastUsageSessionHeader.replacingOccurrences(of: "sess-last", with: "sess-event-partial"))
        \(tokenCountLine(at: "2026-10-20T10:00:00.000Z",
                         cumulative: (900, 0, 100, 1000), last: (90, 0, 10, 100)))
        """, "rollout-event-partial.jsonl", in: sessions)

        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: sessions)])
        _ = try await engine.ingestAll()

        let visible = try await store.fetchActivities()
        #expect(visible.count == 1)
        #expect(visible.first?.granularity == .session)
        #expect(visible.first?.totalTokens == 1_000)
        #expect(visible.first?.totalKind == .published)
        #expect(visible.map { $0.totalTokens ?? 0 }.reduce(0, +) == 1_000)

        // Both observations are retained: the request (inside the aggregate)
        // and the aggregate that still states the session's published total.
        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("history.sqlite3").path, &db) == SQLITE_OK)
        let raw = try #require(db)
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM activity_request;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int64(stmt, 0) == 2)
    }

    @Test("C4: a clean change in one input must not erase another input's malformed count")
    func diagnosticsSurviveMixedChangedAndUnchangedInputs() async throws {
        let dir = try makeTempDir("diagnostics-mixed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let sessions = try twoInputDirectory(dir)
        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: sessions)])

        _ = try await engine.ingestAll()
        #expect(await engine.status().status(for: "codex")?.malformedRecords == 1)

        // File B changes cleanly; file A (malformed) is unchanged.
        let fileB = sessions.appendingPathComponent("rollout-b.jsonl")
        let existing = try String(contentsOf: fileB, encoding: .utf8)
        try (existing + "\n" + validRequest("resp_clean_file_2", at: "2026-10-19T10:01:00.000Z"))
            .write(to: fileB, atomically: true, encoding: .utf8)

        _ = try await engine.ingestAll()
        let afterMixed = try #require(await engine.status().status(for: "codex"))
        #expect(afterMixed.malformedRecords == 1,
                "the unchanged malformed input is still part of this source's accounting")

        // A relaunch reads the retained per-input accounting rather than a
        // clean pass that never looked at A.
        let relaunched = ActivityIngestionEngine(store: makeStore(dir), adapters: [])
        #expect(await relaunched.status().status(for: "codex")?.malformedRecords == 1)

        // Fixing the malformed input is reflected: the count is replaced, not
        // accumulated forever.
        let fileA = sessions.appendingPathComponent("rollout-a.jsonl")
        let repaired = try String(contentsOf: fileA, encoding: .utf8)
            .replacingOccurrences(of: "not json at all\n", with: "")
        try repaired.write(to: fileA, atomically: true, encoding: .utf8)
        _ = try await engine.ingestAll()
        #expect(await engine.status().status(for: "codex")?.malformedRecords == 0)
    }

    @Test("C4: an unreadable input stays counted while another input changes")
    func readFailureSurvivesCleanInputChange() async throws {
        let dir = try makeTempDir("diagnostics-read-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let sessions = try twoInputDirectory(dir)
        let unreadable = sessions.appendingPathComponent("rollout-locked.jsonl")
        _ = try write(validRequest("resp_locked", at: "2026-10-19T11:00:00.000Z"),
                      "rollout-locked.jsonl", in: sessions)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
        }
        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: sessions)])

        _ = try await engine.ingestAll()
        let first = try #require(await engine.status().status(for: "codex"))
        #expect(first.readFailures >= 1)

        let fileB = sessions.appendingPathComponent("rollout-b.jsonl")
        let existing = try String(contentsOf: fileB, encoding: .utf8)
        try (existing + "\n" + validRequest("resp_clean_file_3", at: "2026-10-19T10:02:00.000Z"))
            .write(to: fileB, atomically: true, encoding: .utf8)

        _ = try await engine.ingestAll()
        #expect((await engine.status().status(for: "codex")?.readFailures ?? 0) >= 1)
    }
}
