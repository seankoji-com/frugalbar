import Foundation
#if canImport(SQLite3)
import SQLite3

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

public enum HistoryDatabaseError: Error, LocalizedError, Sendable {
    case cannotOpen(path: String, code: Int32)
    case prepareFailed(sql: String, message: String)
    case stepFailed(code: Int32, message: String)
    case bindFailed(index: Int32, message: String)
    case executionFailed(sql: String, message: String)
    /// A row carried a column this reader cannot decode — a corrupt or
    /// foreign-written value. Distinct from a step failure: the query answered,
    /// the answer is unusable.
    case undecodableRow(column: String, value: String)
    case databaseNotOpen
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, code):
            "Failed to open database at \(path): error code \(code)"
        case let .prepareFailed(sql, message):
            "Failed to prepare statement '\(sql)': \(message)"
        case let .stepFailed(code, message):
            "Statement step failed with code \(code): \(message)"
        case let .bindFailed(index, message):
            "Failed to bind parameter at index \(index): \(message)"
        case let .executionFailed(sql, message):
            "Failed to execute '\(sql)': \(message)"
        case let .undecodableRow(column, value):
            "Row carried an undecodable \(column): \(value)"
        case .databaseNotOpen:
            "Database connection is not open"
        case .unsupportedPlatform:
            "SQLite3 is not supported on this platform"
        }
    }
}

/// Thread-confined minimal SQLite wrapper running on a dedicated serial queue.
///
/// Follows the pattern proven in `Providers/KiroQuotaProvider.swift`:
/// `#if canImport(SQLite3)`, `sqlite3_open_v2`, `sqlite3_busy_timeout`,
/// prepare/bind/step/finalize, `transientDestructor`, and a dedicated
/// `DispatchQueue` so that blocking disk work never parks on the Swift
/// cooperative thread pool.
public final class HistoryDatabase: @unchecked Sendable {
    public let fileURL: URL
    private let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<UInt8>()
    #if canImport(SQLite3)
    private var db: OpaquePointer?
    /// The open connection, for extensions in this module that need a raw
    /// SQLite call the wrapper does not expose (e.g. `sqlite3_changes`).
    /// Only valid from a `perform` block.
    var rawHandle: OpaquePointer? { db }
    #endif

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.queue = DispatchQueue(
            label: "com.quotabar.history-sqlite.\(fileURL.lastPathComponent)",
            qos: .utility
        )
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    /// True when the calling thread is already executing on this connection's
    /// serial queue. Closing the connection with a synchronous hop in that case
    /// would deadlock on itself.
    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) != nil
    }

    deinit {
        #if canImport(SQLite3)
        guard let connection = db else { return }
        // Closed on the same serial queue the connection was used from, so it
        // cannot race a queued statement. Skipped when we are already on that
        // queue — which happens when a queued block held the last reference.
        if isOnQueue {
            _ = sqlite3_close(connection)
        } else {
            queue.sync { _ = sqlite3_close(connection) }
        }
        #endif
    }

    /// Runs a closure synchronously on the database's dedicated serial queue.
    public func perform<T: Sendable>(_ block: @escaping @Sendable (HistoryDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try block(self)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    #if canImport(SQLite3)
    public func open() throws {
        guard db == nil else { return }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let status = sqlite3_open_v2(fileURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let code = status
            if let handle { sqlite3_close(handle) }
            throw HistoryDatabaseError.cannotOpen(path: fileURL.path, code: code)
        }
        self.db = handle

        sqlite3_busy_timeout(handle, 1000)

        // Use WAL mode for concurrent reader/writer safety and durability.
        try execute(sql: "PRAGMA journal_mode=WAL;")
        try execute(sql: "PRAGMA synchronous=NORMAL;")

        // `CREATE TABLE IF NOT EXISTS` cannot alter an existing table, and the
        // stored shape has changed (enum ordinals became names, `total_tokens`
        // became nullable). Reset rather than migrate — see
        // `HistorySchema.version` for why that is safe here and when it stops
        // being safe.
        let existingVersion = try userVersion()
        if existingVersion != HistorySchema.version {
            try execute(sql: HistorySchema.dropTablesSQL)
        }
        // Additive columns go in *before* `createTablesSQL`. The read views it
        // (re)creates name these columns, and `CREATE VIEW` on a database whose
        // table predates them fails outright — so a database written before the
        // identity fingerprint change, or before `event.instance_id`, must be
        // altered first. `addColumnIfMissing` is a no-op when the table does not
        // exist yet (a first run creates it whole).
        try addColumnIfMissing(
            table: HistorySchema.activityRequestTable, column: "published_provider", type: "TEXT")
        try addColumnIfMissing(
            table: HistorySchema.activityRequestTable, column: "account_hash", type: "TEXT")
        try addColumnIfMissing(
            table: HistorySchema.activityRequestTable, column: "workspace_hash", type: "TEXT")
        try addColumnIfMissing(
            table: HistorySchema.eventTable, column: "instance_id", type: "TEXT")
        try execute(sql: HistorySchema.createTablesSQL)
        // Idempotent in-place renames of stored values (see
        // `HistorySchema.dataMigrationsSQL`). They touch no row's meaning.
        try execute(sql: HistorySchema.dataMigrationsSQL)
        // Values first, then the columns that held them. Idempotent: it runs
        // only for rows that still carry a pre-repair raw identity.
        try HistoryIdentityMigration.run(in: self)
        try execute(sql: "PRAGMA user_version = \(HistorySchema.version);")

        if existingVersion != 0 && existingVersion != HistorySchema.version {
            NSLog("frugalbar: history database schema \(existingVersion) replaced by \(HistorySchema.version)")
        }
    }

    public func userVersion() throws -> Int32 {
        let stmt = try prepare(sql: "PRAGMA user_version;")
        defer { finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    /// Adds a column to an existing table when it is not already there.
    ///
    /// SQLite has no `ADD COLUMN IF NOT EXISTS`, and `CREATE TABLE IF NOT
    /// EXISTS` is a no-op on a table that already exists, so the shape is read
    /// back before altering. Used for the additive shape changes that must
    /// reach an installed database without the version bump that would drop
    /// the user's readings. A table that does not exist yet is left to
    /// `createTablesSQL`, which creates it with the column already in place.
    func addColumnIfMissing(table: String, column: String, type: String) throws {
        guard db != nil else { throw HistoryDatabaseError.databaseNotOpen }
        guard try tableExists(table) else { return }
        let stmt = try prepare(sql: "PRAGMA table_info(\(table));")
        defer { finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == column { return }
        }
        try execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(type);")
    }

    /// Whether `table` exists in this database.
    func tableExists(_ table: String) throws -> Bool {
        let stmt = try prepare(sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;")
        defer { finalize(stmt) }
        try bindText(stmt, 1, table)
        return try step(stmt)
    }

    public func execute(sql: String) throws {
        guard let db else { throw HistoryDatabaseError.databaseNotOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if status != SQLITE_OK {
            let msg = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw HistoryDatabaseError.executionFailed(sql: sql, message: msg)
        }
    }

    public func beginTransaction() throws {
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
    }

    public func commitTransaction() throws {
        try execute(sql: "COMMIT TRANSACTION;")
    }

    public func rollbackTransaction() throws {
        try execute(sql: "ROLLBACK TRANSACTION;")
    }

    public func prepare(sql: String) throws -> OpaquePointer {
        guard let db else { throw HistoryDatabaseError.databaseNotOpen }
        var stmt: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard status == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw HistoryDatabaseError.prepareFailed(sql: sql, message: msg)
        }
        return stmt
    }

    public func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) throws {
        if let value {
            let status = sqlite3_bind_text(stmt, index, value, -1, transientDestructor)
            guard status == SQLITE_OK else {
                throw HistoryDatabaseError.bindFailed(index: index, message: lastErrorMessage)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    public func bindInt64(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64?) throws {
        if let value {
            let status = sqlite3_bind_int64(stmt, index, value)
            guard status == SQLITE_OK else {
                throw HistoryDatabaseError.bindFailed(index: index, message: lastErrorMessage)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    public func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) throws {
        if let value {
            let status = sqlite3_bind_double(stmt, index, value)
            guard status == SQLITE_OK else {
                throw HistoryDatabaseError.bindFailed(index: index, message: lastErrorMessage)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Steps a row loop: true for a row, false once the statement is done.
    ///
    /// Anything else throws. Ending a loop on any result but `SQLITE_ROW`
    /// turned a read that failed part-way into a short or empty result that
    /// the screens then reported as "no readings" or "no events".
    public func step(_ stmt: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(stmt)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw HistoryDatabaseError.stepFailed(code: status, message: lastErrorMessage)
    }

    public func finalize(_ stmt: OpaquePointer) {
        sqlite3_finalize(stmt)
    }

    public var lastErrorMessage: String {
        guard let db else { return "Database not open" }
        return String(cString: sqlite3_errmsg(db))
    }
    #else
    public func open() throws {
        throw HistoryDatabaseError.unsupportedPlatform
    }
    #endif
}
