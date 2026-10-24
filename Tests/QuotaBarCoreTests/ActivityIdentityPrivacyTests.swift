import Foundation
import Testing
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

/// C11: a published account or workspace id is private, and the ledger must not
/// keep it in cleartext.
///
/// Every test here drives the production seam — an adapter, the ingestion
/// engine, the store and the attribution engine — because the defect is what
/// the *store* writes, not what a helper returns. Nothing here reads a real
/// transcript: the identity sentinels are synthetic strings, and the rollout and
/// OpenCode database are built inside a temporary directory.
///
/// The assertions are deliberately written against the pre-repair surface
/// (`fetchActivities`, `AttributionBillingTarget`, the SQLite file itself) so the
/// same file runs unchanged against the commit that still writes the values.
@Suite("Activity identity privacy regressions")
struct ActivityIdentityPrivacyTests {

    // Synthetic, high-entropy values. If one of these appears in the database
    // file the ledger persisted a published identity.
    private let accountA = "acct-fixture-sentinel-7f3c1d9a"
    private let accountB = "acct-fixture-other-b2e4"
    private let workspaceOne = "ws-fixture-sentinel-91ab"
    private let workspaceTwo = "ws-fixture-other-4c7d"

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(_ dir: URL) -> QuotaHistoryStore {
        QuotaHistoryStore(
            databaseURL: dir.appendingPathComponent("history.sqlite3"),
            isTestHost: true)
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private var window: (start: Date, end: Date) {
        (date("2026-10-01T00:00:00Z"), date("2026-10-31T00:00:00Z"))
    }

    // MARK: - Fixtures

    /// Two Codex sessions: one request-shaped file that publishes an account,
    /// and one cumulative-only file whose single row is a session aggregate.
    /// Both carry the same published account id.
    private func writeCodexFixtures(in dir: URL) throws -> URL {
        let sessions = dir.appendingPathComponent("codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let request = """
        {"type":"session_meta","timestamp":"2026-10-19T09:59:00.000Z","payload":{"session_id":"sess-privacy-request","cwd":"/repo/codex","git_branch":"main","model":"gpt-6.1-sol","model_provider":"openai","creator_account_id":"\(accountA)"}}
        {"type":"token_usage_record","timestamp":"2026-10-19T10:00:00.000Z","payload":{"session_id":"sess-privacy-request","thread_id":"sess-privacy-request","response_id":"resp_privacy_request","usage":{"input_tokens":700,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":300,"reasoning_output_tokens":0,"total_tokens":1000},"thread_token_usage":{"input_tokens":700,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":300,"reasoning_output_tokens":0,"total_tokens":1000}}}
        """
        try request.write(
            to: sessions.appendingPathComponent("rollout-privacy-request.jsonl"),
            atomically: true, encoding: .utf8)

        let aggregate = """
        {"type":"session_meta","timestamp":"2026-10-20T09:59:00.000Z","payload":{"session_id":"sess-privacy-aggregate","cwd":"/repo/codex-agg","git_branch":"main","model":"gpt-6.1-sol","model_provider":"openai","creator_account_id":"\(accountA)"}}
        {"type":"event_msg","timestamp":"2026-10-20T10:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":500}}}}
        """
        try aggregate.write(
            to: sessions.appendingPathComponent("rollout-privacy-aggregate.jsonl"),
            atomically: true, encoding: .utf8)
        return sessions
    }

    #if canImport(SQLite3)
    /// One OpenCode message that publishes a provider, an account and a
    /// workspace, as the real message payload does.
    private func writeOpenCodeFixture(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw HistoryDatabaseError.cannotOpen(path: url.path, code: -1)
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
        CREATE TABLE message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        """, nil, nil, nil)

        let data = """
        {"tokens":{"input":90,"output":10,"cache":{"read":0,"write":0},"total":100},\
        "path":{"cwd":"/repo/open"},"time":{"created":1792480800000},\
        "modelID":"gpt-5.6-luna","providerID":"litellm",\
        "accountID":"\(accountA)","workspaceID":"\(workspaceOne)"}
        """
        let insert = "INSERT INTO message VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, insert, -1, &stmt, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "msg_privacy_opencode", -1, transient)
        sqlite3_bind_text(stmt, 2, "sess-privacy-opencode", -1, transient)
        sqlite3_bind_int64(stmt, 3, 1_792_480_800_000)
        sqlite3_bind_int64(stmt, 4, 1_792_480_800_000)
        sqlite3_bind_text(stmt, 5, data, -1, transient)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return url
    }
    #endif

    /// Every byte the ledger wrote: the database and its WAL. The `-shm` file
    /// holds no cell text.
    private func ledgerBytes(_ databaseURL: URL) throws -> Data {
        var bytes = Data()
        for suffix in ["", "-wal"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            bytes.append(try Data(contentsOf: url))
        }
        return bytes
    }

    private func assertNoCleartextIdentity(_ databaseURL: URL) throws {
        let bytes = try ledgerBytes(databaseURL)
        #expect(!bytes.isEmpty)
        for (label, sentinel) in [
            ("account A", accountA), ("account B", accountB),
            ("workspace one", workspaceOne), ("workspace two", workspaceTwo),
        ] {
            #expect(
                bytes.range(of: Data(sentinel.utf8)) == nil,
                "\(label) was written to the ledger in cleartext")
        }
    }

    private func summary(
        _ records: [ActivityRecord],
        target: AttributionBillingTarget
    ) -> AttributionSummary {
        AttributionEngine.computeAttribution(
            windowStart: window.start,
            windowEnd: window.end,
            startConsumptionFraction: nil,
            endConsumptionFraction: nil,
            activities: records,
            billingScope: .matchingPublishedIdentity(target))
    }

    // MARK: - Tests

    @Test("C11: published account and workspace ids never reach the ledger files")
    func publishedIdentitiesAreNotPersistedInCleartext() async throws {
        #if canImport(SQLite3)
        let dir = try makeTempDir("identity-privacy-bytes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = try writeCodexFixtures(in: dir)
        let openCodeDB = try writeOpenCodeFixture(in: dir)

        let store = makeStore(dir)
        let engine = ActivityIngestionEngine(
            store: store,
            adapters: [CodexAdapter(baseURL: sessions), OpenCodeAdapter(databaseURL: openCodeDB)])
        let recorded = try await engine.ingestAll()
        #expect(recorded == 3)

        // The activity itself is stored — this is a privacy test, not an
        // "act as though nothing happened" test.
        let fetched = try await store.fetchActivities()
        #expect(fetched.count == 3)
        #expect(fetched.map(\.totalTokens).compactMap { $0 }.reduce(0, +) == 1_600)

        try assertNoCleartextIdentity(store.databaseURL)
        #endif
    }

    @Test("C11: identity matching survives a reopen and a re-ingestion, and stays per-identity")
    func identityMatchingSurvivesPersistence() async throws {
        #if canImport(SQLite3)
        let dir = try makeTempDir("identity-privacy-match")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = try writeCodexFixtures(in: dir)
        let openCodeDB = try writeOpenCodeFixture(in: dir)

        let store = makeStore(dir)
        let engine = ActivityIngestionEngine(
            store: store,
            adapters: [CodexAdapter(baseURL: sessions), OpenCodeAdapter(databaseURL: openCodeDB)])
        _ = try await engine.ingestAll()

        // Same account: the Codex request, the Codex session aggregate and the
        // OpenCode message all publish it.
        let fetched = try await store.fetchActivities()
        let matched = summary(fetched, target: AttributionBillingTarget(accountId: accountA))
        #expect(matched.projectAttributions.map(\.projectPath).sorted()
            == ["/repo/codex", "/repo/codex-agg", "/repo/open"])
        #expect(matched.recordsWithoutMatchingBillingIdentity == 0)

        // A different account under the same published provider is a different
        // identity: the tool name and the provider label are not the subject.
        let otherAccount = summary(
            fetched,
            target: AttributionBillingTarget(billingProvider: "litellm", accountId: accountB))
        #expect(otherAccount.projectAttributions.isEmpty)
        #expect(otherAccount.recordsWithoutMatchingBillingIdentity == 3)

        // Provider is part of the published identity when the target names it.
        let providerScoped = summary(
            fetched, target: AttributionBillingTarget(billingProvider: "litellm", accountId: accountA))
        #expect(providerScoped.projectAttributions.map(\.projectPath) == ["/repo/open"])

        // Workspaces are separate identities; one never matches the other.
        let workspaceOneOnly = summary(fetched, target: AttributionBillingTarget(workspaceId: workspaceOne))
        #expect(workspaceOneOnly.projectAttributions.map(\.projectPath) == ["/repo/open"])
        let workspaceTwoOnly = summary(fetched, target: AttributionBillingTarget(workspaceId: workspaceTwo))
        #expect(workspaceTwoOnly.projectAttributions.isEmpty)
        #expect(workspaceTwoOnly.recordsWithoutMatchingBillingIdentity == 3)

        // Reopen: a fresh store over the same file makes the same matches. The
        // identity read back must be the one that was written, not a value that
        // only compares equal inside one process.
        let reopened = makeStore(dir)
        let afterReopen = try await reopened.fetchActivities()
        #expect(afterReopen.count == 3)
        #expect(summary(afterReopen, target: AttributionBillingTarget(accountId: accountA))
            .projectAttributions.map(\.projectPath).sorted()
            == ["/repo/codex", "/repo/codex-agg", "/repo/open"])
        #expect(summary(afterReopen, target: AttributionBillingTarget(workspaceId: workspaceTwo))
            .projectAttributions.isEmpty)

        // Re-ingesting the same inputs replaces the same rows and changes no
        // identity.
        let again = ActivityIngestionEngine(
            store: reopened,
            adapters: [CodexAdapter(baseURL: sessions), OpenCodeAdapter(databaseURL: openCodeDB)])
        _ = try await again.ingestAll()
        let afterReingest = try await reopened.fetchActivities()
        #expect(afterReingest.count == 3)
        #expect(summary(afterReingest, target: AttributionBillingTarget(workspaceId: workspaceOne))
            .projectAttributions.map(\.projectPath) == ["/repo/open"])

        try assertNoCleartextIdentity(reopened.databaseURL)
        #endif
    }

    @Test("C11: public provider labels are preserved and no identity is invented")
    func providerLabelsSurviveWithoutInventedIdentity() async throws {
        #if canImport(SQLite3)
        let dir = try makeTempDir("identity-privacy-provider")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = try writeCodexFixtures(in: dir)
        let openCodeDB = try writeOpenCodeFixture(in: dir)

        let store = makeStore(dir)
        let engine = ActivityIngestionEngine(
            store: store,
            adapters: [CodexAdapter(baseURL: sessions), OpenCodeAdapter(databaseURL: openCodeDB)])
        _ = try await engine.ingestAll()

        let fetched = try await store.fetchActivities()
        let uncorrelated = summary(fetched, target: AttributionBillingTarget())
        #expect(uncorrelated.projectAttributions.isEmpty, "an uncorrelated target matches nothing")
        #expect(uncorrelated.recordsWithoutMatchingBillingIdentity == 3)

        // The provider labels are public metadata and are kept exactly as
        // published; they are not a subject on their own.
        let published = AttributionEngine.computeAttribution(
            windowStart: window.start,
            windowEnd: window.end,
            startConsumptionFraction: nil,
            endConsumptionFraction: nil,
            activities: fetched,
            billingScope: .any)
        #expect(published.publishedBillingProviders.sorted() == ["litellm", "openai"])
        #endif
    }
}

// MARK: - Legacy ledger migration

/// A database written before the privacy repair still holds the published
/// account and workspace ids in `activity_request.account_id` /
/// `workspace_id`. Opening it must move those values to their fingerprints,
/// leave every token, time and model figure in place, and do it once.
@Suite("Activity identity migration")
struct ActivityIdentityMigrationTests {

    private let account = "acct-legacy-sentinel-3c81"
    private let workspace = "ws-legacy-sentinel-8a02"

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    #if canImport(SQLite3)
    /// The pre-repair `activity_request` shape: raw identity columns, no
    /// fingerprints. Written with the same SQLite the app uses, not through the
    /// store, because the store would write today's shape.
    private func makeLegacyDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw HistoryDatabaseError.cannotOpen(path: url.path, code: -1)
        }
        defer { sqlite3_close(db) }
        let schema = """
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
        CREATE TABLE activity_request (
          source TEXT NOT NULL, record_id TEXT NOT NULL, session_id TEXT NOT NULL,
          project_path TEXT, git_branch TEXT, model TEXT, observed_at INTEGER NOT NULL,
          input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
          cache_write_tokens INTEGER, reasoning_tokens INTEGER, total_tokens INTEGER,
          total_kind TEXT NOT NULL, semantics TEXT NOT NULL, granularity TEXT NOT NULL,
          billing_provider TEXT, account_id TEXT, workspace_id TEXT,
          PRIMARY KEY (source, record_id)
        ) WITHOUT ROWID;
        PRAGMA user_version = 1;
        """
        sqlite3_exec(db, schema, nil, nil, nil)

        sqlite3_exec(db, """
        INSERT INTO reading (vendor, bar_label, measured_at, fraction, is_blocked,
          confidence, urgency, resets_at, window_length, elapsed_only)
        VALUES ('claude', '5H', 1792480000, 0.5, 0, 'measured', 'warning', NULL, 18000, 0);
        INSERT INTO activity (source, record_id, session_id, project_path, git_branch,
          model, observed_at, input_tokens, output_tokens, cache_read_tokens,
          cache_write_tokens, total_tokens)
        VALUES ('claude_code', 'legacy-msg', 'legacy-sess', '/repo/legacy', 'main',
          'claude-sonnet', 1792480100, 10, 20, 0, 0, 30);
        INSERT INTO activity_request (source, record_id, session_id, project_path,
          git_branch, model, observed_at, input_tokens, output_tokens,
          cache_read_tokens, cache_write_tokens, reasoning_tokens, total_tokens,
          total_kind, semantics, granularity, billing_provider, account_id, workspace_id)
        VALUES ('opencode', 'legacy-request', 'legacy-request-sess', '/repo/legacy-request',
          'main', 'gpt-5.6-luna', 1792480200, 90, 10, 0, 0, 0, 100,
          'published', 'additive', 'request', 'litellm', '\(account)', '\(workspace)');
        """, nil, nil, nil)
    }

    private func columnValues(_ url: URL, sql: String) throws -> [String?] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw HistoryDatabaseError.cannotOpen(path: url.path, code: -1)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HistoryDatabaseError.prepareFailed(sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var values: [String?] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            values.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) })
        }
        return values
    }
    #endif

    @Test("C11: legacy raw identities are fingerprinted once, and usage is untouched")
    func legacyIdentitiesAreFingerprintedWithoutLosingUsage() async throws {
        #if canImport(SQLite3)
        let dir = try makeTempDir("identity-migration")
        defer { try? FileManager.default.removeItem(at: dir) }
        let databaseURL = dir.appendingPathComponent("history.sqlite3")
        try makeLegacyDatabase(at: databaseURL)

        let store = QuotaHistoryStore(databaseURL: databaseURL, isTestHost: true)
        let fetched = try await store.fetchActivities()
        #expect(fetched.count == 2)

        let request = try #require(fetched.first { $0.recordId == "legacy-request" })
        #expect(request.totalTokens == 100)
        #expect(request.inputTokens == 90)
        #expect(request.outputTokens == 10)
        #expect(request.model == "gpt-5.6-luna")
        #expect(request.projectPath == "/repo/legacy-request")
        #expect(request.gitBranch == "main")
        #expect(request.observedAt == Date(timeIntervalSince1970: 1_792_480_200))

        // The published identity still matches exactly after migration.
        let summary = AttributionEngine.computeAttribution(
            windowStart: Date(timeIntervalSince1970: 1_792_400_000),
            windowEnd: Date(timeIntervalSince1970: 1_792_600_000),
            startConsumptionFraction: nil,
            endConsumptionFraction: nil,
            activities: fetched,
            billingScope: .matchingPublishedIdentity(
                AttributionBillingTarget(accountId: account, workspaceId: workspace)))
        #expect(summary.projectAttributions.map(\.projectPath) == ["/repo/legacy-request"])
        #expect(summary.publishedBillingProviders == ["litellm"])

        // The retired columns are empty, and no raw value survives in the file.
        #expect(try columnValues(databaseURL,
            sql: "SELECT account_id FROM activity_request;") == [nil])
        #expect(try columnValues(databaseURL,
            sql: "SELECT workspace_id FROM activity_request;") == [nil])
        let storedHashes = try columnValues(databaseURL,
            sql: "SELECT account_hash FROM activity_request;")
        let accountHash = try #require(storedHashes.first ?? nil)
        #expect(accountHash.hasPrefix("fbfp1.account."))
        #expect(!accountHash.contains(account))
        let storedWorkspaceHashes = try columnValues(databaseURL,
            sql: "SELECT workspace_hash FROM activity_request;")
        let workspaceHash = try #require(storedWorkspaceHashes.first ?? nil)
        #expect(workspaceHash.hasPrefix("fbfp1.workspace."))

        let bytes = try Data(contentsOf: databaseURL)
        #expect(bytes.range(of: Data(account.utf8)) == nil,
                "the account id survived in the database file")
        #expect(bytes.range(of: Data(workspace.utf8)) == nil,
                "the workspace id survived in the database file")

        // Quota and legacy activity history are still there, unchanged.
        let readings = try await store.fetchReadings()
        #expect(readings.count == 1)
        #expect(readings.first?.fraction == 0.5)

        // Reopening runs no second migration and changes nothing.
        let reopened = QuotaHistoryStore(databaseURL: databaseURL, isTestHost: true)
        let afterReopen = try await reopened.fetchActivities()
        #expect(afterReopen.count == 2)
        #expect(try columnValues(databaseURL,
            sql: "SELECT account_hash FROM activity_request;") == storedHashes)
        #expect(try columnValues(databaseURL,
            sql: "SELECT account_id FROM activity_request;") == [nil])
        #endif
    }
}
