import Foundation
import Testing
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

@Suite("ActivityIngest")
struct ActivityIngestTests {

    // MARK: - Helpers

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func claudeLine(id: String, session: String, input: Int, output: Int, iso: String) -> String {
        """
        {"message":{"id":"\(id)","usage":{"input_tokens":\(input),"output_tokens":\(output)}},"sessionId":"\(session)","cwd":"/repo/x","timestamp":"\(iso)"}
        """
    }

    private func append(_ text: String, to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + text).write(to: url, atomically: true, encoding: .utf8)
    }

    private func setMtime(_ date: Date, _ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Claude Code

    @Test("Claude Code adapter deduplicates records and parses the token breakdown")
    func claudeCodeDeduplicationTest() async throws {
        let tempDir = try makeTempDir("claude-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectDir = tempDir.appendingPathComponent("project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let jsonlURL = projectDir.appendingPathComponent("session1.jsonl")
        let lines = """
        {"message":{"id":"msg_001","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":15}},"sessionId":"s1","cwd":"/repo/a","timestamp":"2026-08-29T13:00:00Z"}
        {"message":{"id":"msg_001","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":15}},"sessionId":"s1","cwd":"/repo/a","timestamp":"2026-08-29T13:00:00Z"}
        {"message":{"id":"msg_002","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"sessionId":"s1","cwd":"/repo/a","timestamp":"2026-08-29T13:05:00Z"}
        """
        try lines.write(to: jsonlURL, atomically: true, encoding: .utf8)

        let result = try await ClaudeCodeAdapter(baseURL: tempDir).collectActivities(watermarks: [:])
        let records = result.records

        // Expect exactly 2 records, msg_001 must not be duplicated
        #expect(records.count == 2)
        let msg1 = records.first(where: { $0.recordId == "msg_001" })
        let msg2 = records.first(where: { $0.recordId == "msg_002" })

        #expect(msg1 != nil)
        #expect(msg1?.inputTokens == 10)
        #expect(msg1?.outputTokens == 20)
        #expect(msg1?.cacheReadTokens == 5)
        #expect(msg1?.cacheWriteTokens == 15)
        #expect(msg1?.totalTokens == 50)
        #expect(msg1?.projectPath == "/repo/a")

        #expect(msg2 != nil)
        #expect(msg2?.inputTokens == 100)
    }

    @Test("an append to a file that is not the most recently modified is still ingested")
    func appendToNonNewestFileIsIngested() async throws {
        let tempDir = try makeTempDir("watermark")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = QuotaHistoryStore(
            databaseURL: tempDir.appendingPathComponent("history.sqlite3"),
            isTestHost: true
        )

        let oldFile = tempDir.appendingPathComponent("session-old.jsonl")
        let newFile = tempDir.appendingPathComponent("session-new.jsonl")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        try claudeLine(id: "m1", session: "s-old", input: 10, output: 10, iso: "2026-01-01T00:00:00Z")
            .appending("\n")
            .write(to: oldFile, atomically: true, encoding: .utf8)
        try claudeLine(id: "m2", session: "s-new", input: 20, output: 20, iso: "2026-01-01T01:00:00Z")
            .appending("\n")
            .write(to: newFile, atomically: true, encoding: .utf8)
        try setMtime(t0, oldFile)
        try setMtime(t0.addingTimeInterval(3600), newFile)

        let engine = ActivityIngestionEngine(store: store, adapters: [ClaudeCodeAdapter(baseURL: tempDir)])
        #expect(try await engine.ingestAll() == 2)

        // The older session keeps working; its mtime stays below session-new's,
        // which is what the previous single high-water-mark watermark used to
        // treat as "already read".
        try append(claudeLine(id: "m3", session: "s-old", input: 99, output: 99, iso: "2026-01-01T00:30:00Z").appending("\n"), to: oldFile)
        try setMtime(t0.addingTimeInterval(60), oldFile)

        #expect(try await engine.ingestAll() == 1)

        let stored = try await store.fetchActivities()
        #expect(stored.contains { $0.recordId == "m3" })

        // A later write elsewhere must not disturb it either.
        try append(claudeLine(id: "m4", session: "s-new", input: 5, output: 5, iso: "2026-01-01T02:00:00Z").appending("\n"), to: newFile)
        try setMtime(t0.addingTimeInterval(7200), newFile)
        _ = try await engine.ingestAll()

        let after = try await store.fetchActivities()
        #expect(after.contains { $0.recordId == "m3" })
        #expect(after.contains { $0.recordId == "m4" })
    }

    @Test("an append within the same whole second is still ingested")
    func sameSecondAppendIsIngested() async throws {
        let tempDir = try makeTempDir("same-second")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = QuotaHistoryStore(
            databaseURL: tempDir.appendingPathComponent("history.sqlite3"),
            isTestHost: true
        )
        let file = tempDir.appendingPathComponent("session.jsonl")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        try claudeLine(id: "a1", session: "s", input: 1, output: 1, iso: "2026-01-01T00:00:00Z")
            .appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try setMtime(t0, file)

        let engine = ActivityIngestionEngine(store: store, adapters: [ClaudeCodeAdapter(baseURL: tempDir)])
        #expect(try await engine.ingestAll() == 1)

        // 0.4s later: the file grew, but the whole-second mtime is unchanged.
        try append(claudeLine(id: "a2", session: "s", input: 7, output: 7, iso: "2026-01-01T00:00:00Z").appending("\n"), to: file)
        try setMtime(t0.addingTimeInterval(0.4), file)

        #expect(try await engine.ingestAll() == 1)

        let stored = try await store.fetchActivities()
        #expect(stored.contains { $0.recordId == "a2" })
    }

    @Test("an unterminated final line is ingested, but a half-written one is not")
    func unterminatedFinalLineHandling() async throws {
        let tempDir = try makeTempDir("unterminated")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = QuotaHistoryStore(
            databaseURL: tempDir.appendingPathComponent("history.sqlite3"),
            isTestHost: true
        )
        let file = tempDir.appendingPathComponent("session.jsonl")

        // One terminated line, then a complete record with no trailing newline.
        let complete = claudeLine(id: "u1", session: "s", input: 3, output: 3, iso: "2026-01-01T00:00:00Z")
        let unterminated = claudeLine(id: "u2", session: "s", input: 4, output: 4, iso: "2026-01-01T00:01:00Z")
        try (complete + "\n" + unterminated).write(to: file, atomically: true, encoding: .utf8)

        let engine = ActivityIngestionEngine(store: store, adapters: [ClaudeCodeAdapter(baseURL: tempDir)])
        #expect(try await engine.ingestAll() == 2)

        // Now a genuinely partial record: it must not be consumed as if complete.
        let partial = #"{"message":{"id":"u3","usage":{"input_to"#
        try append("\n" + partial, to: file)
        #expect(try await engine.ingestAll() == 0)

        // Completing it makes it readable, and it is still found.
        try append(#"kens":9,"output_tokens":9}},"sessionId":"s","timestamp":"2026-01-01T00:02:00Z"}"# + "\n", to: file)
        #expect(try await engine.ingestAll() == 1)

        let stored = try await store.fetchActivities()
        #expect(stored.contains { $0.recordId == "u3" })
    }

    // MARK: - Codex

    @Test("Codex adapter takes the last cumulative usage per session and never sums turns")
    func codexCumulativeUsageTest() async throws {
        let tempDir = try makeTempDir("codex-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rolloutURL = tempDir.appendingPathComponent("rollout-session-x.jsonl")
        let lines = """
        {"type":"session_meta","payload":{"session_id":"sess_123","cwd":"/repo/codex","timestamp":"2026-09-03T10:00:00Z"}}
        {"type":"event_msg","timestamp":"2026-09-03T10:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":50,"cache_write_input_tokens":25,"output_tokens":20,"total_tokens":195}}}}
        {"type":"event_msg","timestamp":"2026-09-03T10:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":100,"cache_write_input_tokens":25,"output_tokens":75,"total_tokens":450}}}}
        """
        try lines.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let result = try await CodexAdapter(baseURL: tempDir).collectActivities(watermarks: [:])
        let records = result.records

        // Expect exactly 1 record for sess_123, with the LAST cumulative usage (250 input, 75 output), NOT 350 input
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.sessionId == "sess_123")
        #expect(record.projectPath == "/repo/codex")
        #expect(record.inputTokens == 250)
        #expect(record.outputTokens == 75)
        #expect(record.cacheReadTokens == 100)
        #expect(record.cacheWriteTokens == 25)
        #expect(record.totalTokens == 450)
    }

    // MARK: - OpenCode

    #if canImport(SQLite3)
    private func makeOpenCodeDatabase(at url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw HistoryDatabaseError.cannotOpen(path: url.path, code: -1)
        }
        sqlite3_exec(db, """
        CREATE TABLE message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        """, nil, nil, nil)
        return db
    }

    private func insertMessage(_ db: OpaquePointer, id: String, updatedMs: Int64) {
        let dataJSON = """
        {"tokens":{"input":42,"output":12,"cache":{"read":7,"write":3},"total":64},"cost":0.005,"path":{"cwd":"/repo/open"},"time":{"created":\(updatedMs)},"modelID":"gpt-5-test"}
        """
        let insert = "INSERT INTO message VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, insert, -1, &stmt, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, "sess_open_1", -1, transient)
        sqlite3_bind_int64(stmt, 3, updatedMs)
        sqlite3_bind_int64(stmt, 4, updatedMs)
        sqlite3_bind_text(stmt, 5, dataJSON, -1, transient)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
    #endif

    @Test("OpenCode adapter reads SQLite and then only new messages")
    func openCodeIncrementalTest() async throws {
        #if canImport(SQLite3)
        let tempDir = try makeTempDir("opencode-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("opencode.db")

        do {
            let db = try makeOpenCodeDatabase(at: dbURL)
            defer { sqlite3_close(db) }
            insertMessage(db, id: "msg_opencode_1", updatedMs: 1_700_000_000_000)
        }

        let adapter = OpenCodeAdapter(databaseURL: dbURL)
        let first = try await adapter.collectActivities(watermarks: [:])

        #expect(first.records.count == 1)
        let rec = try #require(first.records.first)
        #expect(rec.recordId == "msg_opencode_1")
        #expect(rec.sessionId == "sess_open_1")
        #expect(rec.inputTokens == 42)
        #expect(rec.outputTokens == 12)
        #expect(rec.cacheReadTokens == 7)
        #expect(rec.cacheWriteTokens == 3)
        #expect(rec.totalTokens == 64)
        #expect(rec.model == "gpt-5-test")
        #expect(rec.projectPath == "/repo/open")

        // The previous version rescanned every message on every poll. A second
        // pass must return only what is new.
        var writeDB: OpaquePointer?
        sqlite3_open(dbURL.path, &writeDB)
        if let writeDB {
            insertMessage(writeDB, id: "msg_opencode_2", updatedMs: 1_700_000_100_000)
            sqlite3_close(writeDB)
        }

        let watermarks = Dictionary(uniqueKeysWithValues: first.watermarks.map { ($0.filePath, $0) })
        let second = try await adapter.collectActivities(watermarks: watermarks)
        #expect(second.records.map(\.recordId) == ["msg_opencode_2"])
        #endif
    }

    // MARK: - Engine

    @Test("ActivityIngestionEngine tracks per-file watermarks and prevents re-ingestion")
    func watermarkTrackingTest() async throws {
        let tempDir = try makeTempDir("engine-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = QuotaHistoryStore(
            databaseURL: tempDir.appendingPathComponent("history.sqlite3"),
            isTestHost: true
        )

        let mockDir = tempDir.appendingPathComponent("claude-mock", isDirectory: true)
        try FileManager.default.createDirectory(at: mockDir, withIntermediateDirectories: true)

        let file1 = mockDir.appendingPathComponent("s1.jsonl")
        let line1 = "{\"message\":{\"id\":\"m1\",\"usage\":{\"input_tokens\":5,\"output_tokens\":5}},\"sessionId\":\"s1\",\"timestamp\":\"2026-09-01T00:00:00Z\"}\n"
        try line1.write(to: file1, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(baseURL: mockDir)
        let engine = ActivityIngestionEngine(store: store, adapters: [adapter])

        // First ingestion: should record 1 item
        #expect(try await engine.ingestAll() == 1)
        #expect(try await store.fetchActivities().count == 1)

        // Second ingestion: file has not changed, watermark prevents re-reading
        #expect(try await engine.ingestAll() == 0)

        // And a third, to be sure the watermark is stable rather than merely
        // toggling once.
        #expect(try await engine.ingestAll() == 0)
    }

    @Test("an adapter that cannot read its source fails the pass instead of reporting zero")
    func failingAdapterIsNotSilentSuccess() async throws {
        let tempDir = try makeTempDir("engine-failure")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = QuotaHistoryStore(
            databaseURL: tempDir.appendingPathComponent("history.sqlite3"),
            isTestHost: true
        )

        struct FailingAdapter: ActivityAdapter {
            let sourceIdentifier = "failing"
            func collectActivities(watermarks: [String: ActivityWatermark]) async throws -> ActivityIngestResult {
                throw ActivityAdapterError.sourceBusy(path: "/does/not/matter")
            }
        }

        let engine = ActivityIngestionEngine(store: store, adapters: [FailingAdapter()])
        await #expect(throws: ActivityAdapterError.self) {
            _ = try await engine.ingestAll()
        }
    }
}
