import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Ingests CLI activity from OpenCode SQLite database (`~/.local/share/opencode/opencode.db`).
///
/// The message table is read incrementally on `time_updated`: this database is
/// gigabytes on a real installation, and an unfiltered `data LIKE '%tokens%'`
/// scan plus a full re-insert of every matching row was costing a second and
/// ~170 MB of transient memory on every poll.
public struct OpenCodeAdapter: ActivityAdapter, Sendable {
    public let sourceIdentifier: String = "opencode"
    public let databaseURL: URL?

    public init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else if TestHost.isActive {
            self.databaseURL = nil
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.databaseURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
        }
    }

    public func collectActivities(watermarks: [String: ActivityWatermark]) async throws -> ActivityIngestResult {
        #if canImport(SQLite3)
        guard let databaseURL, FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .empty
        }

        let path = databaseURL.path
        let resourceValues = try? databaseURL.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = Int64((resourceValues?.contentModificationDate ?? .distantPast).timeIntervalSince1970)

        // `cursor` is the last `time_updated` already ingested (milliseconds).
        // A cursor ahead of the file's own mtime means the database was replaced
        // or reset underneath us, so start over rather than reading nothing.
        var cursor: Int64 = 0
        if let prior = watermarks[path], prior.cursor <= mtime * 1000 {
            cursor = prior.cursor
        }

        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return .empty
        }
        defer { sqlite3_close(db) }

        // OpenCode is a live writer to this file. Without a busy timeout a
        // concurrent write fails immediately, and a locked database must not be
        // mistaken for an idle one.
        sqlite3_busy_timeout(db, 1000)

        let query = """
        SELECT id, session_id, time_created, time_updated, data
        FROM message
        WHERE data LIKE '%tokens%' AND time_updated > ?
        ORDER BY time_updated ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .empty
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, cursor)

        var records: [ActivityRecord] = []
        var highWaterMark = cursor

        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_BUSY {
                throw ActivityAdapterError.sourceBusy(path: path)
            }
            guard step == SQLITE_ROW else { break }

            guard let idC = sqlite3_column_text(stmt, 0),
                  let dataC = sqlite3_column_text(stmt, 4) else {
                continue
            }
            let recordId = String(cString: idC)
            let sessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "unknown"
            let updatedMs = sqlite3_column_int64(stmt, 3)
            let createdMs = sqlite3_column_int64(stmt, 2)
            if updatedMs > highWaterMark { highWaterMark = updatedMs }

            let dataStr = String(cString: dataC)

            guard let jsonData = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            guard let tokens = json["tokens"] as? [String: Any] else {
                continue
            }

            let inputTokens = tokens["input"] as? Int
            let outputTokens = tokens["output"] as? Int
            let cacheDict = tokens["cache"] as? [String: Any]
            let cacheRead = cacheDict?["read"] as? Int
            let cacheWrite = cacheDict?["write"] as? Int
            let model = json["modelID"] as? String

            var projectPath: String?
            if let pathObj = json["path"] as? [String: Any] {
                projectPath = pathObj["cwd"] as? String
            }

            var observedAt = Date()
            if let timeObj = json["time"] as? [String: Any] {
                if let completedMs = timeObj["completed"] as? Double {
                    observedAt = Date(timeIntervalSince1970: completedMs / 1000.0)
                } else if let createdMs = timeObj["created"] as? Double {
                    observedAt = Date(timeIntervalSince1970: createdMs / 1000.0)
                }
            } else if updatedMs > 0 {
                observedAt = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
            } else if createdMs > 0 {
                observedAt = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
            }

            records.append(ActivityRecord(
                source: sourceIdentifier,
                recordId: recordId,
                sessionId: sessionId,
                projectPath: projectPath,
                gitBranch: nil,
                model: model,
                observedAt: observedAt,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                totalTokens: tokens["total"] as? Int
            ))
        }

        // Only advance the cursor on a pass that actually ran to completion; the
        // busy case above throws and leaves it where it was.
        let watermark = ActivityWatermark(
            filePath: path,
            fileSize: 0,
            modifiedAt: mtime,
            cursor: max(highWaterMark, cursor)
        )

        return ActivityIngestResult(records: records, watermarks: [watermark])
        #else
        return .empty
        #endif
    }
}
