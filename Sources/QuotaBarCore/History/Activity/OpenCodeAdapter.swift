import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Ingests CLI activity from OpenCode SQLite database (`~/.local/share/opencode/opencode.db`).
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

    public func collectActivities(since watermarkMtime: Int64?) async throws -> (records: [ActivityRecord], maxMtime: Int64?) {
        #if canImport(SQLite3)
        guard let databaseURL, FileManager.default.fileExists(atPath: databaseURL.path) else {
            return ([], nil)
        }

        let resourceValues = try? databaseURL.resourceValues(forKeys: [.contentModificationDateKey])
        let dbMtime = resourceValues?.contentModificationDate.map { Int64($0.timeIntervalSince1970) }

        if let watermark = watermarkMtime, let mtime = dbMtime, mtime <= watermark {
            return ([], watermarkMtime)
        }

        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return ([], dbMtime)
        }
        defer { sqlite3_close(db) }

        let query = """
        SELECT id, session_id, time_created, time_updated, data
        FROM message
        WHERE data LIKE '%tokens%';
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return ([], dbMtime)
        }
        defer { sqlite3_finalize(stmt) }

        var records: [ActivityRecord] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let dataC = sqlite3_column_text(stmt, 4) else {
                continue
            }
            let recordId = String(cString: idC)
            let sessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "unknown"
            let dataStr = String(cString: dataC)

            guard let jsonData = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            guard let tokens = json["tokens"] as? [String: Any] else {
                continue
            }

            let inputTokens = (tokens["input"] as? Int) ?? 0
            let outputTokens = (tokens["output"] as? Int) ?? 0
            let cacheDict = tokens["cache"] as? [String: Any]
            let cacheRead = (cacheDict?["read"] as? Int) ?? 0
            let cacheWrite = (cacheDict?["write"] as? Int) ?? 0
            let totalTokens = (tokens["total"] as? Int) ?? (inputTokens + outputTokens + cacheRead + cacheWrite)
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
            } else {
                let updatedMs = sqlite3_column_int64(stmt, 3)
                let createdMs = sqlite3_column_int64(stmt, 2)
                if updatedMs > 0 {
                    observedAt = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
                } else if createdMs > 0 {
                    observedAt = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
                }
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
                totalTokens: totalTokens
            ))
        }

        return (records, dbMtime)
        #else
        return ([], nil)
        #endif
    }
}
