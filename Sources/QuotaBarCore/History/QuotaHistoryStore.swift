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
    let database: HistoryDatabase
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
    /// the connection is confined to. Internal (not private) so the event and
    /// catalog extensions in `QuotaHistoryStore+Events.swift` can share it.
    func ensureOpen() async throws {
        guard !isOpened else { return }
        #if canImport(SQLite3)
        try await database.perform { db in try db.open() }
        isOpened = true
        #else
        throw HistoryDatabaseError.unsupportedPlatform
        #endif
    }

    /// The label of the one row a poll writes when its snapshot carries no
    /// window: a read that failed, or an answer with no usage in it. It is the
    /// provider's poll, not any window's, so it speaks for every window of the
    /// same instance at that instant.
    public static let providerPollLabel = "DEFAULT"

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
            // The instance's stable id, not the vendor raw value: two OpenCode
            // Go workspaces of one vendor record separate series, and their
            // rows never collide on the (vendor, bar_label, measured_at)
            // primary key. For every single-instance provider the two are the
            // same string, so existing series are untouched.
            let key = snapshot.id
            let bars = snapshot.bars
            // A poll that could not read the provider recorded nothing,
            // however many figures the snapshot still carries: those were
            // measured earlier and are stamped with their own `lastUpdated`.
            // Writing them under `now` — which is what happened while retention
            // replaced the poll's own status — made a failed poll
            // indistinguishable from a fresh reading, so
            // `HistoryPresentation.failedLatestPoll` never fired, the charts
            // drew the carried-over figures straight across the outage as if
            // they were current, and the inspector kept presenting them as the
            // provider's state now. The failure is recorded exactly as the very
            // first failed poll of a provider is: one row, no fraction, so it
            // breaks every window of this instance at this instant.
            if snapshot.staleReading != nil {
                preparedRows.append(RowToWrite(
                    vendor: key,
                    barLabel: Self.providerPollLabel,
                    measuredAt: timestamp,
                    fraction: nil,
                    isBlocked: false,
                    confidence: .unavailable,
                    urgency: .none,
                    resetsAt: nil,
                    windowLength: nil,
                    elapsedOnly: false
                ))
                continue
            }
            if bars.isEmpty {
                preparedRows.append(RowToWrite(
                    vendor: key,
                    barLabel: Self.providerPollLabel,
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
                        vendor: key,
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
        // Balance figures ride the same poll and the same transaction. They are
        // not readings — they have no window and no fraction — so they go to
        // their own table rather than as `reading` rows with a nulled fraction.
        let balanceRows = Self.balanceRows(from: snapshots, at: timestamp)

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

            if !balanceRows.isEmpty {
                let balanceSQL = """
                INSERT OR REPLACE INTO balance_reading (
                  series_id, vendor, label, unit, measured_at, value
                ) VALUES (?, ?, ?, ?, ?, ?);
                """
                let balanceStmt = try db.prepare(sql: balanceSQL)
                defer { db.finalize(balanceStmt) }
                for row in balanceRows {
                    sqlite3_reset(balanceStmt)
                    sqlite3_clear_bindings(balanceStmt)
                    try db.bindText(balanceStmt, 1, row.seriesId)
                    try db.bindText(balanceStmt, 2, row.vendor)
                    try db.bindText(balanceStmt, 3, row.label)
                    try db.bindText(balanceStmt, 4, row.unit)
                    try db.bindInt64(balanceStmt, 5, row.measuredAt)
                    try db.bindText(balanceStmt, 6, row.value)
                    let step = sqlite3_step(balanceStmt)
                    guard step == SQLITE_DONE else {
                        throw HistoryDatabaseError.stepFailed(code: step, message: db.lastErrorMessage)
                    }
                }
            }

            let pruneBalancesSQL = "DELETE FROM balance_reading WHERE measured_at < ?;"
            let pruneBalancesStmt = try db.prepare(sql: pruneBalancesSQL)
            defer { db.finalize(pruneBalancesStmt) }
            try db.bindInt64(pruneBalancesStmt, 1, cutoff)
            let pruneBalancesStatus = sqlite3_step(pruneBalancesStmt)
            guard pruneBalancesStatus == SQLITE_DONE else {
                throw HistoryDatabaseError.stepFailed(code: pruneBalancesStatus, message: db.lastErrorMessage)
            }

            try db.commitTransaction()
            didCommit = true
            #endif
        }
    }

    /// The SQL condition and bind values that select one vendor's stored rows.
    ///
    /// One raw-value comparison for a single-instance vendor. OpenCode Go
    /// additionally matches every workspace instance key by prefix. The prefix
    /// is the same for a workspace added later or one already removed, so a
    /// vendor-scoped view sees every instance of the vendor without reading the
    /// current workspace list — and a removed workspace's history is still
    /// found rather than silently orphaned.
    static func vendorClause(for vendor: VendorIdentifier) -> (sql: String, values: [String]) {
        guard vendor == .opencode else { return ("vendor = ?", [vendor.rawValue]) }
        // The instance prefix (`opencode-go:`) carries no `%` or `_`, so a bare
        // LIKE cannot mis-match; a future prefix containing one needs ESCAPE.
        return (
            "(vendor = ? OR vendor LIKE ?)",
            [vendor.rawValue, OpenCodeGoWorkspaceStore.instancePrefix + "%"]
        )
    }

    /// Fetches persisted readings filtered by vendor, label, or time range.
    ///
    /// `vendor` matches every instance that belongs to that vendor — for
    /// OpenCode Go that is each workspace's own series plus the legacy rows a
    /// pre-workspace install recorded — so a vendor-scoped view (the History
    /// window, a workspace's detail modal) sees all of its readings.
    /// `instanceID` narrows to one provider instance when a caller already
    /// knows which one it wants.
    public func fetchReadings(
        vendor: VendorIdentifier? = nil,
        instanceID: String? = nil,
        barLabel: String? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> [ReadingRecord] {
        try await ensureOpen()

        let vendorClause: (sql: String, values: [String])? = if let instanceID {
            ("vendor = ?", [instanceID])
        } else if let vendor {
            Self.vendorClause(for: vendor)
        } else {
            nil
        }
        let sinceEpoch = since.map { Int64($0.timeIntervalSince1970) }
        let untilEpoch = until.map { Int64($0.timeIntervalSince1970) }

        return try await database.perform { db -> [ReadingRecord] in
            #if canImport(SQLite3)
            var conditions: [String] = []
            if let vendorClause {
                conditions.append(vendorClause.sql)
            }
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
            if let vendorClause {
                for value in vendorClause.values {
                    try db.bindText(stmt, bindIdx, value)
                    bindIdx += 1
                }
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
            while try db.step(stmt) {
                if let record = Self.readingRecord(from: stmt) { results.append(record) }
            }
            return results
            #else
            return []
            #endif
        }
    }

    #if canImport(SQLite3)
    /// Decodes one `reading` row selected as `vendor, bar_label, measured_at,
    /// fraction, is_blocked, confidence, urgency, resets_at, window_length,
    /// elapsed_only`, in that order. nil for a row with no vendor or label.
    static func readingRecord(from stmt: OpaquePointer?) -> ReadingRecord? {
        guard let vendorText = sqlite3_column_text(stmt, 0),
              let labelText = sqlite3_column_text(stmt, 1) else {
            return nil
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

        return ReadingRecord(
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
        )
    }
    #endif

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
            INSERT OR REPLACE INTO activity_request (
              source, record_id, session_id, project_path,
              git_branch, model, observed_at, input_tokens, output_tokens,
              cache_read_tokens, cache_write_tokens, reasoning_tokens,
              total_tokens, total_kind, semantics, granularity,
              billing_provider, account_id, workspace_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                try db.bindInt64(stmt, 12, row.reasoningTokens.map(Int64.init))
                // NULL when the source reported no total. Not 0 — an unknown
                // total must not be counted as a measured one.
                try db.bindInt64(stmt, 13, row.totalTokens.map(Int64.init))
                try db.bindText(stmt, 14, row.totalKind.rawValue)
                try db.bindText(stmt, 15, row.semantics.rawValue)
                try db.bindText(stmt, 16, row.granularity.rawValue)
                try db.bindText(stmt, 17, row.billingProvider)
                try db.bindText(stmt, 18, row.accountId)
                try db.bindText(stmt, 19, row.workspaceId)

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
                   cache_read_tokens, cache_write_tokens, reasoning_tokens,
                   total_tokens, total_kind, semantics, granularity,
                   billing_provider, account_id, workspace_id
            FROM activity_unified
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
            while try db.step(stmt) {
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
                let reasoningTokens: Int? = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 11))
                let totalTokens: Int? = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 12))
                let totalKind = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
                    .flatMap(TokenTotalKind.init(rawValue:)) ?? .legacy
                let semantics = sqlite3_column_text(stmt, 14).map { String(cString: $0) }
                    .flatMap(TokenComponentSemantics.init(rawValue:)) ?? .additive
                let granularity = sqlite3_column_text(stmt, 15).map { String(cString: $0) }
                    .flatMap(ActivityGranularity.init(rawValue:)) ?? .legacy
                let billingProvider: String? = sqlite3_column_text(stmt, 16).map { String(cString: $0) }
                let accountId: String? = sqlite3_column_text(stmt, 17).map { String(cString: $0) }
                let workspaceId: String? = sqlite3_column_text(stmt, 18).map { String(cString: $0) }

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
                    reasoningTokens: reasoningTokens,
                    totalTokens: totalTokens,
                    totalKind: totalKind,
                    semantics: semantics,
                    granularity: granularity,
                    billingProvider: billingProvider,
                    accountId: accountId,
                    workspaceId: workspaceId
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

    // MARK: - Source status

    /// Whether this source has any row in the request ledger. Codex uses this
    /// once after upgrade: an install whose only Codex rows predate the ledger
    /// must re-read its still-present rollouts, because their old watermarks
    /// would otherwise skip every unchanged file forever and leave only the
    /// session aggregate.
    public func hasActivityRequests(source: String) async throws -> Bool {
        try await ensureOpen()
        return try await database.perform { db -> Bool in
            #if canImport(SQLite3)
            let stmt = try db.prepare(sql: "SELECT 1 FROM activity_request WHERE source = ? LIMIT 1;")
            defer { db.finalize(stmt) }
            try db.bindText(stmt, 1, source)
            let status = sqlite3_step(stmt)
            if status == SQLITE_ROW { return true }
            guard status == SQLITE_DONE else {
                throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
            }
            return false
            #else
            return false
            #endif
        }
    }

    // MARK: - Input status

    /// Diagnostics retained for each input of one source.
    public func activityInputStatuses(source: String) async throws -> [ActivityInputStatus] {
        try await ensureOpen()
        return try await database.perform { db -> [ActivityInputStatus] in
            #if canImport(SQLite3)
            let sql = """
            SELECT source, file_path, malformed_records, inconsistent_records,
                   incomplete_records, records_observed, read_failure, last_scanned_at
            FROM activity_input_status
            WHERE source = ?
            ORDER BY file_path ASC;
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }
            try db.bindText(stmt, 1, source)

            var results: [ActivityInputStatus] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
                }
                guard let sourceText = sqlite3_column_text(stmt, 0),
                      let pathText = sqlite3_column_text(stmt, 1) else { continue }
                results.append(ActivityInputStatus(
                    source: String(cString: sourceText),
                    filePath: String(cString: pathText),
                    malformedRecords: Int(sqlite3_column_int64(stmt, 2)),
                    inconsistentRecords: Int(sqlite3_column_int64(stmt, 3)),
                    incompleteRecords: Int(sqlite3_column_int64(stmt, 4)),
                    recordsObserved: Int(sqlite3_column_int64(stmt, 5)),
                    readFailure: sqlite3_column_int64(stmt, 6) != 0,
                    lastScannedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
                ))
            }
            return results
            #else
            return []
            #endif
        }
    }

    /// Replaces one source's retained input rows transactionally.
    ///
    /// The caller has already merged any appended-region counts and kept the
    /// previous rows of unchanged inputs, so the set it passes is the whole
    /// account of that source's existing inputs.
    public func replaceActivityInputStatuses(
        source: String,
        inputs: [ActivityInputStatus]
    ) async throws {
        try await ensureOpen()
        try await database.perform { db in
            #if canImport(SQLite3)
            try db.beginTransaction()
            var didCommit = false
            defer {
                if !didCommit { try? db.rollbackTransaction() }
            }

            let delete = try db.prepare(sql: "DELETE FROM activity_input_status WHERE source = ?;")
            defer { db.finalize(delete) }
            try db.bindText(delete, 1, source)
            let deleted = sqlite3_step(delete)
            guard deleted == SQLITE_DONE else {
                throw HistoryDatabaseError.stepFailed(code: deleted, message: db.lastErrorMessage)
            }

            let sql = """
            INSERT OR REPLACE INTO activity_input_status (
              source, file_path, malformed_records, inconsistent_records,
              incomplete_records, records_observed, read_failure, last_scanned_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }
            for input in inputs {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try db.bindText(stmt, 1, input.source)
                try db.bindText(stmt, 2, input.filePath)
                try db.bindInt64(stmt, 3, Int64(input.malformedRecords))
                try db.bindInt64(stmt, 4, Int64(input.inconsistentRecords))
                try db.bindInt64(stmt, 5, Int64(input.incompleteRecords))
                try db.bindInt64(stmt, 6, Int64(input.recordsObserved))
                try db.bindInt64(stmt, 7, input.readFailure ? 1 : 0)
                try db.bindInt64(stmt, 8, Int64(input.lastScannedAt.timeIntervalSince1970))
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw HistoryDatabaseError.stepFailed(code: step, message: db.lastErrorMessage)
                }
            }

            try db.commitTransaction()
            didCommit = true
            #endif
        }
    }

    /// The retained per-source account of what the last scan could represent.
    public func activitySourceStatuses() async throws -> [ActivitySourceStatus] {        try await ensureOpen()
        return try await database.perform { db -> [ActivitySourceStatus] in
            #if canImport(SQLite3)
            let sql = """
            SELECT source, last_scan_at, last_successful_scan_at, read_failures,
                   malformed_records, inconsistent_records, incomplete_records,
                   records_observed, last_pass_complete
            FROM activity_source_status
            ORDER BY source ASC;
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            var results: [ActivitySourceStatus] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
                }
                guard let sourceText = sqlite3_column_text(stmt, 0) else { continue }
                let lastScan: Date? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
                let lastSuccess: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))
                results.append(ActivitySourceStatus(
                    source: String(cString: sourceText),
                    lastScanAt: lastScan,
                    lastSuccessfulScanAt: lastSuccess,
                    readFailures: Int(sqlite3_column_int64(stmt, 3)),
                    malformedRecords: Int(sqlite3_column_int64(stmt, 4)),
                    inconsistentRecords: Int(sqlite3_column_int64(stmt, 5)),
                    incompleteRecords: Int(sqlite3_column_int64(stmt, 6)),
                    recordsObserved: Int(sqlite3_column_int64(stmt, 7)),
                    lastPassComplete: sqlite3_column_int64(stmt, 8) != 0
                ))
            }
            return results
            #else
            return []
            #endif
        }
    }

    public func recordActivitySourceStatus(_ status: ActivitySourceStatus) async throws {
        try await ensureOpen()
        try await database.perform { db in
            #if canImport(SQLite3)
            let sql = """
            INSERT OR REPLACE INTO activity_source_status (
              source, last_scan_at, last_successful_scan_at, read_failures,
              malformed_records, inconsistent_records, incomplete_records,
              records_observed, last_pass_complete
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            try db.bindText(stmt, 1, status.source)
            try db.bindInt64(stmt, 2, status.lastScanAt.map { Int64($0.timeIntervalSince1970) })
            try db.bindInt64(stmt, 3, status.lastSuccessfulScanAt.map { Int64($0.timeIntervalSince1970) })
            try db.bindInt64(stmt, 4, Int64(status.readFailures))
            try db.bindInt64(stmt, 5, Int64(status.malformedRecords))
            try db.bindInt64(stmt, 6, Int64(status.inconsistentRecords))
            try db.bindInt64(stmt, 7, Int64(status.incompleteRecords))
            try db.bindInt64(stmt, 8, Int64(status.recordsObserved))
            try db.bindInt64(stmt, 9, status.lastPassComplete ? 1 : 0)

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
            for table in [
                HistorySchema.readingTable, HistorySchema.activityTable,
                HistorySchema.activityRequestTable, HistorySchema.activitySourceStatusTable,
                "activity_input_status",
                HistorySchema.ingestWatermarkTable,
                // Not the retired catalog/feed tables: a new database no
                // longer has them, and DELETE on a missing table throws.
                HistorySchema.eventTable, HistorySchema.accountModelTable,
            ] {
                try db.execute(sql: "DELETE FROM \(table);")
            }
            #endif
        }
    }
}

extension Notification.Name {
    /// Posted on the main thread after a poll's readings are written, so a
    /// window showing history reloads instead of drawing the history it had
    /// when it opened.
    public static let frugalbarHistoryDidRecord = Notification.Name("FrugalBarHistoryDidRecord")
}
