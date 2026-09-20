import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Persistent history store for point-in-time quota readings and coding activity.
///
/// Ensures that `DualBarMetrics.primaryFraction`'s `Double?` representation is
/// preserved faithfully across disk round-trips: a `nil` fraction is written as
/// SQL `NULL` and read back as `nil`, never defaulting to 0.0 or 1.0.
public actor QuotaHistoryStore {

    /// Default retention cap for readings: 90 days.
    public static let defaultRetentionInterval: TimeInterval = 90 * 24 * 3600

    public struct ReadingRecord: Sendable, Equatable {
        public let vendor: String
        public let barLabel: String
        public let measuredAt: Date
        public let fraction: Double?
        public let isBlocked: Bool
        public let confidence: Confidence
        public let urgency: Urgency
        public let resetsAt: Date?
        public let windowLength: TimeInterval?
        public let elapsedOnly: Bool

        public init(
            vendor: String,
            barLabel: String,
            measuredAt: Date,
            fraction: Double?,
            isBlocked: Bool,
            confidence: Confidence,
            urgency: Urgency,
            resetsAt: Date?,
            windowLength: TimeInterval?,
            elapsedOnly: Bool
        ) {
            self.vendor = vendor
            self.barLabel = barLabel
            self.measuredAt = measuredAt
            self.fraction = fraction
            self.isBlocked = isBlocked
            self.confidence = confidence
            self.urgency = urgency
            self.resetsAt = resetsAt
            self.windowLength = windowLength
            self.elapsedOnly = elapsedOnly
        }
    }

    nonisolated public let databaseURL: URL
    private let database: HistoryDatabase
    public let retentionInterval: TimeInterval

    /// Returns the database URL. Under test runs (`isTestHost == true`), uses an
    /// isolated temporary folder to ensure tests never write to or read from the
    /// user's real `~/Library/Application Support` history database.
    public static func databaseURL(isTestHost: Bool, filename: String = "history.sqlite3") -> URL {
        if isTestHost {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("FrugalBar-tests", isDirectory: true)
                .appendingPathComponent(filename)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        return appSupport
            .appendingPathComponent("FrugalBar", isDirectory: true)
            .appendingPathComponent(filename)
    }

    public static func databaseURL(filename: String = "history.sqlite3") -> URL {
        databaseURL(isTestHost: TestHost.isActive, filename: filename)
    }

    public static func sampleDatabaseURL(isTestHost: Bool) -> URL {
        databaseURL(isTestHost: isTestHost, filename: "history-sample.sqlite3")
    }

    public static func sampleDatabaseURL() -> URL {
        sampleDatabaseURL(isTestHost: TestHost.isActive)
    }

    public init(
        databaseURL: URL? = nil,
        retentionInterval: TimeInterval = defaultRetentionInterval
    ) {
        let url = databaseURL ?? Self.databaseURL(isTestHost: TestHost.isActive)
        self.databaseURL = url
        self.database = HistoryDatabase(fileURL: url)
        self.retentionInterval = retentionInterval
    }

    public init(
        databaseURL: URL? = nil,
        retentionInterval: TimeInterval = defaultRetentionInterval,
        isTestHost: Bool
    ) {
        let url = databaseURL ?? Self.databaseURL(isTestHost: isTestHost)
        self.databaseURL = url
        self.database = HistoryDatabase(fileURL: url)
        self.retentionInterval = retentionInterval
    }

    private var isOpened = false

    /// Opens the database on its own serial queue rather than from the actor's
    /// executor, so every touch of the SQLite handle happens on the one thread
    /// the connection is confined to.
    private func ensureOpen() async throws {
        guard !isOpened else { return }
        #if canImport(SQLite3)
        try await database.perform { db in try db.open() }
        isOpened = true
        #else
        throw HistoryDatabaseError.unsupportedPlatform
        #endif
    }

    /// Records a snapshot batch and prunes readings older than `retentionInterval`.
    public func record(_ snapshots: [QuotaSnapshot], now: Date = Date()) async throws {
        try await ensureOpen()

        let timestamp = Int64(now.timeIntervalSince1970)
        let cutoff = Int64(now.timeIntervalSince1970 - retentionInterval)

        struct RowToWrite: Sendable {
            let vendor: String
            let barLabel: String
            let measuredAt: Int64
            let fraction: Double?
            let isBlocked: Bool
            let confidence: Confidence
            let urgency: Urgency
            let resetsAt: Int64?
            let windowLength: Int64?
            let elapsedOnly: Bool
        }

        var preparedRows: [RowToWrite] = []
        for snapshot in snapshots {
            let bars = snapshot.bars
            if bars.isEmpty {
                preparedRows.append(RowToWrite(
                    vendor: snapshot.vendorId.rawValue,
                    barLabel: "DEFAULT",
                    measuredAt: timestamp,
                    fraction: nil,
                    isBlocked: false,
                    confidence: snapshot.status.confidence,
                    urgency: snapshot.status.urgency,
                    resetsAt: snapshot.resetsAt.map { Int64($0.timeIntervalSince1970) },
                    windowLength: nil,
                    elapsedOnly: false
                ))
            } else {
                for bar in bars {
                    preparedRows.append(RowToWrite(
                        vendor: snapshot.vendorId.rawValue,
                        barLabel: bar.label,
                        measuredAt: timestamp,
                        fraction: bar.primaryFraction,
                        isBlocked: bar.isBlocked,
                        confidence: snapshot.status.confidence,
                        urgency: snapshot.status.urgency,
                        resetsAt: bar.resetsAt.map { Int64($0.timeIntervalSince1970) },
                        windowLength: bar.windowLength.map { Int64($0) },
                        elapsedOnly: bar.measuresElapsedTimeOnly
                    ))
                }
            }
        }
        let rows = preparedRows

        try await database.perform { db in
            #if canImport(SQLite3)
            try db.beginTransaction()
            var didCommit = false
            defer {
                // Commit only on the success path. `defer { try? commit() }` also
                // ran after a throw, so a batch that failed part-way through
                // persisted the rows it had already written — a partial poll
                // stored as if it were complete.
                if !didCommit { try? db.rollbackTransaction() }
            }

            let sql = """
            INSERT OR REPLACE INTO reading (
              vendor, bar_label, measured_at, fraction, is_blocked,
              confidence, urgency, resets_at, window_length, elapsed_only
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            for row in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                try db.bindText(stmt, 1, row.vendor)
                try db.bindText(stmt, 2, row.barLabel)
                try db.bindInt64(stmt, 3, row.measuredAt)
                try db.bindDouble(stmt, 4, row.fraction)
                try db.bindInt64(stmt, 5, row.isBlocked ? 1 : 0)
                try db.bindText(stmt, 6, row.confidence.historyName)
                try db.bindText(stmt, 7, row.urgency.historyName)
                try db.bindInt64(stmt, 8, row.resetsAt)
                try db.bindInt64(stmt, 9, row.windowLength)
                try db.bindInt64(stmt, 10, row.elapsedOnly ? 1 : 0)

                let stepStatus = sqlite3_step(stmt)
                guard stepStatus == SQLITE_DONE else {
                    throw HistoryDatabaseError.stepFailed(code: stepStatus, message: db.lastErrorMessage)
                }
            }

            // Prune records older than retention cap
            let pruneSQL = "DELETE FROM reading WHERE measured_at < ?;"
            let pruneStmt = try db.prepare(sql: pruneSQL)
            defer { db.finalize(pruneStmt) }
            try db.bindInt64(pruneStmt, 1, cutoff)
            let pruneStatus = sqlite3_step(pruneStmt)
            guard pruneStatus == SQLITE_DONE else {
                throw HistoryDatabaseError.stepFailed(code: pruneStatus, message: db.lastErrorMessage)
            }

            try db.commitTransaction()
            didCommit = true
            #endif
        }
    }

    /// Fetches persisted readings filtered by vendor, label, or time range.
    public func fetchReadings(
        vendor: VendorIdentifier? = nil,
        barLabel: String? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> [ReadingRecord] {
        try await ensureOpen()

        let vendorString = vendor?.rawValue
        let sinceEpoch = since.map { Int64($0.timeIntervalSince1970) }
        let untilEpoch = until.map { Int64($0.timeIntervalSince1970) }

        return try await database.perform { db -> [ReadingRecord] in
            #if canImport(SQLite3)
            var conditions: [String] = []
            if vendorString != nil { conditions.append("vendor = ?") }
            if barLabel != nil { conditions.append("bar_label = ?") }
            if sinceEpoch != nil { conditions.append("measured_at >= ?") }
            if untilEpoch != nil { conditions.append("measured_at <= ?") }

            var sql = """
            SELECT vendor, bar_label, measured_at, fraction, is_blocked,
                   confidence, urgency, resets_at, window_length, elapsed_only
            FROM reading
            """
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY measured_at ASC, vendor ASC, bar_label ASC;"

            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            var bindIdx: Int32 = 1
            if let vendorString {
                try db.bindText(stmt, bindIdx, vendorString)
                bindIdx += 1
            }
            if let barLabel {
                try db.bindText(stmt, bindIdx, barLabel)
                bindIdx += 1
            }
            if let sinceEpoch {
                try db.bindInt64(stmt, bindIdx, sinceEpoch)
                bindIdx += 1
            }
            if let untilEpoch {
                try db.bindInt64(stmt, bindIdx, untilEpoch)
                bindIdx += 1
            }

            var results: [ReadingRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let vendorText = sqlite3_column_text(stmt, 0),
                      let labelText = sqlite3_column_text(stmt, 1) else {
                    continue
                }
                let vendor = String(cString: vendorText)
                let label = String(cString: labelText)
                let measuredAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))

                let fraction: Double?
                if sqlite3_column_type(stmt, 3) == SQLITE_NULL {
                    fraction = nil
                } else {
                    fraction = sqlite3_column_double(stmt, 3)
                }

                let isBlocked = sqlite3_column_int64(stmt, 4) != 0

                // Read by name. An unrecognised name means this row was written
                // by a build with a case we do not have; it is treated as
                // unreadable rather than as a calm reading.
                let confidenceName = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let confidence = Confidence(historyName: confidenceName) ?? .unavailable

                let urgencyName = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                let urgency = Urgency(historyName: urgencyName) ?? .none

                let resetsAt: Date?
                if sqlite3_column_type(stmt, 7) == SQLITE_NULL {
                    resetsAt = nil
                } else {
                    resetsAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
                }

                let windowLength: TimeInterval?
                if sqlite3_column_type(stmt, 8) == SQLITE_NULL {
                    windowLength = nil
                } else {
                    windowLength = TimeInterval(sqlite3_column_int64(stmt, 8))
                }

                let elapsedOnly = sqlite3_column_int64(stmt, 9) != 0

                results.append(ReadingRecord(
                    vendor: vendor,
                    barLabel: label,
                    measuredAt: measuredAt,
                    fraction: fraction,
                    isBlocked: isBlocked,
                    confidence: confidence,
                    urgency: urgency,
                    resetsAt: resetsAt,
                    windowLength: windowLength,
                    elapsedOnly: elapsedOnly
                ))
            }
            return results
            #else
            return []
            #endif
        }
    }

    // MARK: - Activity Records

    /// Records activity slices into the store.
    public func recordActivities(_ records: [ActivityRecord]) async throws {
        try await ensureOpen()
        guard !records.isEmpty else { return }

        let rows = records

        try await database.perform { db in
            #if canImport(SQLite3)
            try db.beginTransaction()
            var didCommit = false
            defer {
                if !didCommit { try? db.rollbackTransaction() }
            }

            let sql = """
            INSERT OR REPLACE INTO activity (
              source, record_id, session_id, project_path,
              git_branch, model, observed_at, input_tokens, output_tokens,
              cache_read_tokens, cache_write_tokens, total_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            for row in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                try db.bindText(stmt, 1, row.source)
                try db.bindText(stmt, 2, row.recordId)
                try db.bindText(stmt, 3, row.sessionId)
                try db.bindText(stmt, 4, row.projectPath)
                try db.bindText(stmt, 5, row.gitBranch)
                try db.bindText(stmt, 6, row.model)
                try db.bindInt64(stmt, 7, Int64(row.observedAt.timeIntervalSince1970))
                try db.bindInt64(stmt, 8, row.inputTokens.map(Int64.init))
                try db.bindInt64(stmt, 9, row.outputTokens.map(Int64.init))
                try db.bindInt64(stmt, 10, row.cacheReadTokens.map(Int64.init))
                try db.bindInt64(stmt, 11, row.cacheWriteTokens.map(Int64.init))
                // NULL when the source reported no total. Not 0 — an unknown
                // total must not be counted as a measured one.
                try db.bindInt64(stmt, 12, row.totalTokens.map(Int64.init))

                let stepStatus = sqlite3_step(stmt)
                guard stepStatus == SQLITE_DONE else {
                    throw HistoryDatabaseError.stepFailed(code: stepStatus, message: db.lastErrorMessage)
                }
            }

            try db.commitTransaction()
            didCommit = true
            #endif
        }
    }

    /// Fetches persisted activity records.
    public func fetchActivities(
        source: String? = nil,
        projectPath: String? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> [ActivityRecord] {
        try await ensureOpen()

        let sinceEpoch = since.map { Int64($0.timeIntervalSince1970) }
        let untilEpoch = until.map { Int64($0.timeIntervalSince1970) }

        return try await database.perform { db -> [ActivityRecord] in
            #if canImport(SQLite3)
            var conditions: [String] = []
            if source != nil { conditions.append("source = ?") }
            if projectPath != nil { conditions.append("project_path = ?") }
            if sinceEpoch != nil { conditions.append("observed_at >= ?") }
            if untilEpoch != nil { conditions.append("observed_at <= ?") }

            var sql = """
            SELECT source, record_id, session_id, project_path,
                   git_branch, model, observed_at, input_tokens, output_tokens,
                   cache_read_tokens, cache_write_tokens, total_tokens
            FROM activity
            """
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY observed_at ASC, record_id ASC;"

            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            var bindIdx: Int32 = 1
            if let source {
                try db.bindText(stmt, bindIdx, source)
                bindIdx += 1
            }
            if let projectPath {
                try db.bindText(stmt, bindIdx, projectPath)
                bindIdx += 1
            }
            if let sinceEpoch {
                try db.bindInt64(stmt, bindIdx, sinceEpoch)
                bindIdx += 1
            }
            if let untilEpoch {
                try db.bindInt64(stmt, bindIdx, untilEpoch)
                bindIdx += 1
            }

            var results: [ActivityRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let sourceText = sqlite3_column_text(stmt, 0),
                      let recordIdText = sqlite3_column_text(stmt, 1),
                      let sessionIdText = sqlite3_column_text(stmt, 2) else {
                    continue
                }
                let sourceStr = String(cString: sourceText)
                let recordIdStr = String(cString: recordIdText)
                let sessionIdStr = String(cString: sessionIdText)

                let projectPath: String? = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let gitBranch: String? = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let model: String? = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let observedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))

                let inputTokens: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 7))
                let outputTokens: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 8))
                let cacheReadTokens: Int? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 9))
                let cacheWriteTokens: Int? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 10))
                let totalTokens: Int? = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 11))

                results.append(ActivityRecord(
                    source: sourceStr,
                    recordId: recordIdStr,
                    sessionId: sessionIdStr,
                    projectPath: projectPath,
                    gitBranch: gitBranch,
                    model: model,
                    observedAt: observedAt,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheWriteTokens: cacheWriteTokens,
                    totalTokens: totalTokens
                ))
            }
            return results
            #else
            return []
            #endif
        }
    }

    // MARK: - Ingestion Watermarks

    /// Every per-file watermark recorded for a source, keyed by file path.
    ///
    /// Per file, not per source: a single maximum mtime per source meant any
    /// append to a file that was not the most recently touched one fell below
    /// the high-water mark and was never read.
    public func watermarks(for source: String) async throws -> [String: ActivityWatermark] {
        try await ensureOpen()
        return try await database.perform { db -> [String: ActivityWatermark] in
            #if canImport(SQLite3)
            let sql = """
            SELECT file_path, file_size, modified_at, byte_offset
            FROM ingest_watermark WHERE source = ?;
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            try db.bindText(stmt, 1, source)

            var result: [String: ActivityWatermark] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let pathText = sqlite3_column_text(stmt, 0) else { continue }
                let filePath = String(cString: pathText)
                result[filePath] = ActivityWatermark(
                    filePath: filePath,
                    fileSize: sqlite3_column_int64(stmt, 1),
                    modifiedAt: sqlite3_column_int64(stmt, 2),
                    cursor: sqlite3_column_int64(stmt, 3)
                )
            }
            return result
            #else
            return [:]
            #endif
        }
    }

    public func setWatermark(
        source: String,
        filePath: String,
        fileSize: Int64 = 0,
        modifiedAt: Int64,
        byteOffset: Int64 = 0
    ) async throws {
        try await ensureOpen()
        try await database.perform { db in
            #if canImport(SQLite3)
            let sql = """
            INSERT OR REPLACE INTO ingest_watermark (source, file_path, file_size, modified_at, byte_offset)
            VALUES (?, ?, ?, ?, ?);
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            try db.bindText(stmt, 1, source)
            try db.bindText(stmt, 2, filePath)
            try db.bindInt64(stmt, 3, fileSize)
            try db.bindInt64(stmt, 4, modifiedAt)
            try db.bindInt64(stmt, 5, byteOffset)

            let step = sqlite3_step(stmt)
            guard step == SQLITE_DONE else {
                throw HistoryDatabaseError.stepFailed(code: step, message: db.lastErrorMessage)
            }
            #endif
        }
    }

    /// Removes every row, including watermarks.
    ///
    /// Exists for the sample-data store only, so regenerating the fixture cannot
    /// accumulate rows; it must never be pointed at the live history database.
    public func removeAll() async throws {
        try await ensureOpen()
        try await database.perform { db in
            #if canImport(SQLite3)
            for table in [HistorySchema.readingTable, HistorySchema.activityTable, HistorySchema.ingestWatermarkTable] {
                try db.execute(sql: "DELETE FROM \(table);")
            }
            #endif
        }
    }
}
