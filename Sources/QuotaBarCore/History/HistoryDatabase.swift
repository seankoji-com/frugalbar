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
        try execute(sql: HistorySchema.createTablesSQL)
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
