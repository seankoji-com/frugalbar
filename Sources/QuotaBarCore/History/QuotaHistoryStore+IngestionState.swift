import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Whether the local-activity ingestion has ever finished a full pass.
///
/// The Tokens widget reads the activity table, which is empty until the first
/// ingestion has walked every CLI transcript. Without this fact an empty table
/// cannot be told apart from a quiet week, and "still reading" would render as
/// "no activity". It lives in the history database, beside the data it
/// describes, so a wiped database does not keep claiming it is complete.
extension QuotaHistoryStore {

    static let activityFullPassKey = "activity_full_pass"

    /// When a pass in which every adapter succeeded last finished, or nil if
    /// none ever has in this database.
    public func activityFullPassCompletedAt() async throws -> Date? {
        try await ensureOpen()
        return try await database.perform { db -> Date? in
            #if canImport(SQLite3)
            let stmt = try db.prepare(sql: "SELECT value FROM ingestion_state WHERE key = ?;")
            defer { db.finalize(stmt) }
            try db.bindText(stmt, 1, Self.activityFullPassKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
            #else
            return nil
            #endif
        }
    }

    /// Records that a full pass finished. Replaces any earlier time: callers
    /// ask only whether one ever has.
    public func markActivityFullPassCompleted(at date: Date = Date()) async throws {
        try await ensureOpen()
        let epoch = Int64(date.timeIntervalSince1970)
        try await database.perform { db in
            #if canImport(SQLite3)
            let stmt = try db.prepare(sql: "INSERT OR REPLACE INTO ingestion_state (key, value) VALUES (?, ?);")
            defer { db.finalize(stmt) }
            try db.bindText(stmt, 1, Self.activityFullPassKey)
            try db.bindInt64(stmt, 2, epoch)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
            }
            #endif
        }
    }
}
