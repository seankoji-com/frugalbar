import Foundation
import Testing
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

@Suite("ActivityIngest")
struct ActivityIngestTests {

    @Test("Claude Code adapter deduplicates records and parses token breakdown")
    func claudeCodeDeduplicationTest() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

        let adapter = ClaudeCodeAdapter(baseURL: tempDir)
        let (records, _) = try await adapter.collectActivities(since: nil)

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

    @Test("Codex adapter takes the last cumulative usage per session and never sums turns")
    func codexCumulativeUsageTest() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rolloutURL = tempDir.appendingPathComponent("rollout-session-x.jsonl")
        let lines = """
        {"type":"session_meta","payload":{"session_id":"sess_123","cwd":"/repo/codex","timestamp":"2026-09-03T10:00:00Z"}}
        {"type":"event_msg","timestamp":"2026-09-03T10:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":50,"cache_write_input_tokens":25,"output_tokens":20,"total_tokens":195}}}}
        {"type":"event_msg","timestamp":"2026-09-03T10:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":100,"cache_write_input_tokens":25,"output_tokens":75,"total_tokens":450}}}}
        """
        try lines.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(baseURL: tempDir)
        let (records, _) = try await adapter.collectActivities(since: nil)

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

    @Test("OpenCode adapter reads SQLite database correctly")
    func openCodeSQLiteTest() async throws {
        #if canImport(SQLite3)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("opencode.db")

        // Scope database creation so it is fully flushed and closed before reading
        do {
            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
                Issue.record("Failed to create test opencode db")
                return
            }
            defer { sqlite3_close(db) }

            let schema = """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """
            sqlite3_exec(db, schema, nil, nil, nil)

            let dataJSON = """
            {"tokens":{"input":42,"output":12,"cache":{"read":7,"write":3},"total":64},"cost":0.005,"path":{"cwd":"/repo/open"},"time":{"created":1700000000000,"completed":1700000005000},"modelID":"gpt-5-test"}
            """

            let insert = "INSERT INTO message VALUES (?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, insert, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, "msg_opencode_1", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, "sess_open_1", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(stmt, 3, 1700000000000)
            sqlite3_bind_int64(stmt, 4, 1700000005000)
            sqlite3_bind_text(stmt, 5, dataJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        let adapter = OpenCodeAdapter(databaseURL: dbURL)
        let (records, _) = try await adapter.collectActivities(since: nil)

        #expect(records.count == 1)
        let rec = try #require(records.first)
        #expect(rec.recordId == "msg_opencode_1")
        #expect(rec.sessionId == "sess_open_1")
        #expect(rec.inputTokens == 42)
        #expect(rec.outputTokens == 12)
        #expect(rec.cacheReadTokens == 7)
        #expect(rec.cacheWriteTokens == 3)
        #expect(rec.totalTokens == 64)
        #expect(rec.model == "gpt-5-test")
        #expect(rec.projectPath == "/repo/open")
        #endif
    }

    @Test("ActivityIngestionEngine tracks watermarks and prevents re-ingestion")
    func watermarkTrackingTest() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("history.sqlite3")
        let store = QuotaHistoryStore(databaseURL: storeURL, isTestHost: true)

        let mockDir = tempDir.appendingPathComponent("claude-mock", isDirectory: true)
        try FileManager.default.createDirectory(at: mockDir, withIntermediateDirectories: true)

        let file1 = mockDir.appendingPathComponent("s1.jsonl")
        let line1 = "{\"message\":{\"id\":\"m1\",\"usage\":{\"input_tokens\":5,\"output_tokens\":5}},\"sessionId\":\"s1\",\"timestamp\":\"2026-09-01T00:00:00Z\"}\n"
        try line1.write(to: file1, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(baseURL: mockDir)
        let engine = ActivityIngestionEngine(store: store, adapters: [adapter])

        // First ingestion: should record 1 item
        let count1 = try await engine.ingestAll()
        #expect(count1 == 1)

        let activities1 = try await store.fetchActivities()
        #expect(activities1.count == 1)

        // Second ingestion: file has not changed, watermark prevents re-reading
        let count2 = try await engine.ingestAll()
        #expect(count2 == 0)
    }
}
