import Testing
import Foundation
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

/// An adapter that cannot read an input must say so. Returning success with it
/// missing makes every total quietly short, and for the Claude adapter it also
/// stored the file's new size and mtime, so the next pass saw it as unchanged
/// and never tried again.
@Suite("Activity adapters report what they could not read")
struct ActivityAdapterSkipTests {

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    private func unlock(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    private func claudeLine(id: String, tokens: Int) -> String {
        """
        {"message":{"id":"\(id)","usage":{"input_tokens":\(tokens),"output_tokens":1}},"sessionId":"s","cwd":"/repo/x","timestamp":"2026-08-29T13:00:00Z"}
        """
    }

    private func codexSession(id: String, total: Int) -> String {
        """
        {"type":"session_meta","payload":{"session_id":"\(id)","cwd":"/repo/codex","timestamp":"2026-09-03T10:00:00Z"}}
        {"type":"event_msg","timestamp":"2026-09-03T10:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(total),"output_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"total_tokens":\(total)}}}}
        """
    }

    // MARK: Claude Code

    /// Not run as root, which can read a mode-000 file.
    @Test("Claude: an unreadable transcript is skipped, has no watermark, and is read once it can be", .enabled(if: getuid() != 0))
    func claudeUnreadableFileIsRetried() async throws {
        let dir = try makeTempDir("claude-skip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let good = project.appendingPathComponent("good.jsonl")
        let bad = project.appendingPathComponent("bad.jsonl")
        try (claudeLine(id: "g1", tokens: 10) + "\n").write(to: good, atomically: true, encoding: .utf8)
        try (claudeLine(id: "b1", tokens: 20) + "\n").write(to: bad, atomically: true, encoding: .utf8)
        try lock(bad)
        defer { unlock(bad) }

        let adapter = ClaudeCodeAdapter(baseURL: dir)
        let first = try await adapter.collectActivities(watermarks: [:])
        #expect(first.records.map(\.recordId) == ["g1"])
        #expect(first.skipped == 1)
        // No watermark for the file that was not read: that is what lets it be retried.
        #expect(first.watermarks.contains { $0.filePath.hasSuffix("bad.jsonl") } == false)
        #expect(first.watermarks.contains { $0.filePath.hasSuffix("good.jsonl") })

        // The next pass, with what the engine stored, once the file can be read.
        unlock(bad)
        var stored: [String: ActivityWatermark] = [:]
        for w in first.watermarks { stored[w.filePath] = w }
        let second = try await adapter.collectActivities(watermarks: stored)
        #expect(second.records.map(\.recordId) == ["b1"])
        #expect(second.skipped == 0)
    }

    @Test("Claude: nothing to read is not a skipped input")
    func claudeAbsentIsNotSkipped() async throws {
        let dir = try makeTempDir("claude-none")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await ClaudeCodeAdapter(baseURL: dir.appendingPathComponent("missing")).collectActivities(watermarks: [:]).skipped == 0)
        #expect(try await ClaudeCodeAdapter(baseURL: dir).collectActivities(watermarks: [:]).skipped == 0)
    }

    // MARK: Codex

    @Test("Codex: an unreadable session is skipped and left without a watermark", .enabled(if: getuid() != 0))
    func codexUnreadableFile() async throws {
        let dir = try makeTempDir("codex-skip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.jsonl")
        let bad = dir.appendingPathComponent("bad.jsonl")
        try codexSession(id: "g", total: 100).write(to: good, atomically: true, encoding: .utf8)
        try codexSession(id: "b", total: 900).write(to: bad, atomically: true, encoding: .utf8)
        try lock(bad)
        defer { unlock(bad) }

        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(result.records.map(\.sessionId) == ["g"])
        #expect(result.skipped == 1)
        #expect(result.watermarks.contains { $0.filePath.hasSuffix("bad.jsonl") } == false)
    }

    @Test("Codex: a session that is not text is skipped, not read as empty")
    func codexNotText() async throws {
        let dir = try makeTempDir("codex-binary")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: dir.appendingPathComponent("binary.jsonl"))
        let result = try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:])
        #expect(result.records.isEmpty)
        #expect(result.skipped == 1)
    }

    @Test("Codex: nothing to read is not a skipped input")
    func codexAbsentIsNotSkipped() async throws {
        let dir = try makeTempDir("codex-none")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await CodexAdapter(baseURL: dir.appendingPathComponent("missing")).collectActivities(watermarks: [:]).skipped == 0)
        #expect(try await CodexAdapter(baseURL: dir).collectActivities(watermarks: [:]).skipped == 0)
    }

    // MARK: OpenCode

    #if canImport(SQLite3)
    private func makeDatabase(at url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw HistoryDatabaseError.cannotOpen(path: url.path, code: -1)
        }
        defer { sqlite3_close(db) }
        // A statement that does not run would leave an empty database, and
        // an adapter test over an empty database passes for the wrong reason.
        var message: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(message) }
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            throw HistoryDatabaseError.executionFailed(
                sql: sql, message: message.map { String(cString: $0) } ?? "unknown")
        }
    }

    /// The failure this guards: OpenCode reshapes its database, the query no
    /// longer runs, the adapter returns "nothing new", and OpenCode silently
    /// never counts again while the pass looks clean.
    @Test("OpenCode: a database whose message table is gone is skipped, not idle")
    func openCodeSchemaChange() async throws {
        let dir = try makeTempDir("opencode-schema")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opencode.db")
        try makeDatabase(at: url, sql: "CREATE TABLE something_else (x INTEGER);")
        let result = try await OpenCodeAdapter(databaseURL: url).collectActivities(watermarks: [:])
        #expect(result.records.isEmpty)
        #expect(result.skipped == 1)
        #expect(result.watermarks.isEmpty)       // nothing is marked as read
    }

    /// The failure this guards: the query prepares and then fails on a step
    /// (corruption, an I/O error). Ending the loop as if it had finished marked
    /// the database read and reported a clean pass.
    ///
    /// A view named `message` whose column overflows when evaluated makes
    /// `sqlite3_step` fail without damaging a file; it prepares fine, so this
    /// is not the missing-table case above.
    @Test("OpenCode: a query that fails on its first step is skipped, with no watermark")
    func openCodeStepFailure() async throws {
        let dir = try makeTempDir("opencode-step")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opencode.db")
        try makeDatabase(at: url, sql: """
        CREATE VIEW message AS
        SELECT 'm1' AS id, 's' AS session_id, 1 AS time_created, 1 AS time_updated,
               abs(-9223372036854775807 - 1) AS data;
        """)
        let result = try await OpenCodeAdapter(databaseURL: url).collectActivities(watermarks: [:])
        #expect(result.skipped == 1)
        #expect(result.watermarks.isEmpty)
    }

    /// Rows read before the failure are real observations and storing them
    /// again next pass is harmless (the primary key replaces), so they are
    /// kept; the database still gets no watermark, so it is read again from
    /// the old cursor, and the pass is incomplete.
    @Test("OpenCode: rows read before a mid-query failure are kept, and the database is not marked read")
    func openCodePartialStepFailure() async throws {
        let dir = try makeTempDir("opencode-partial")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opencode.db")
        // The index lets the rows stream in `time_updated` order, so `good`
        // is delivered before `bad` is evaluated and fails. The failure sits
        // in a view because a generated column is evaluated on insert.
        try makeDatabase(at: url, sql: """
        CREATE TABLE base (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
          time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
          raw TEXT NOT NULL
        );
        CREATE INDEX base_updated ON base(time_updated);
        INSERT INTO base (id, session_id, time_created, time_updated, raw) VALUES
          ('good', 's', 1000, 1000, '{"tokens":{"input":1,"output":2,"total":3}}'),
          ('bad',  's', 2000, 2000, 'x');
        CREATE VIEW message AS
        SELECT id, session_id, time_created, time_updated,
               CASE WHEN id = 'bad' THEN abs(-9223372036854775807 - 1) ELSE raw END AS data
        FROM base;
        """)
        let result = try await OpenCodeAdapter(databaseURL: url).collectActivities(watermarks: [:])
        #expect(result.records.map(\.recordId) == ["good"])
        #expect(result.records.first?.totalTokens == 3)
        #expect(result.skipped == 1)
        #expect(result.watermarks.isEmpty)
    }

    @Test("OpenCode: a file that is not a database is skipped")
    func openCodeNotADatabase() async throws {
        let dir = try makeTempDir("opencode-garbage")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opencode.db")
        try Data("this is not a sqlite database at all".utf8).write(to: url)
        let result = try await OpenCodeAdapter(databaseURL: url).collectActivities(watermarks: [:])
        #expect(result.skipped == 1)
    }

    @Test("OpenCode: a database that exists but cannot be opened is skipped", .enabled(if: getuid() != 0))
    func openCodeUnopenable() async throws {
        let dir = try makeTempDir("opencode-locked")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opencode.db")
        try makeDatabase(at: url, sql: "CREATE TABLE message (id TEXT);")
        try lock(url)
        defer { unlock(url) }
        let result = try await OpenCodeAdapter(databaseURL: url).collectActivities(watermarks: [:])
        #expect(result.skipped == 1)
        #expect(result.watermarks.isEmpty)
    }

    @Test("OpenCode: a missing database, or a healthy empty one, is not a skipped input")
    func openCodeAbsentOrHealthy() async throws {
        let dir = try makeTempDir("opencode-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await OpenCodeAdapter(databaseURL: dir.appendingPathComponent("missing.db")).collectActivities(watermarks: [:]).skipped == 0)
        let url = dir.appendingPathComponent("opencode.db")
        try makeDatabase(at: url, sql: """
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
        """)
        let result = try await OpenCodeAdapter(databaseURL: url).collectActivities(watermarks: [:])
        #expect(result.skipped == 0)
        #expect(result.records.isEmpty)
    }
    #endif
}
