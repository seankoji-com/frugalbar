import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Persistence for AI-platform events and the watcher state behind them.
///
/// Two tables, both additive to the schema that shipped (see
/// `HistorySchema.createTablesSQL`):
///
/// - `event`: every `AIEvent` ever recorded, keyed by its deterministic id.
///   `recordEvents` is the deduplication point — the engine hands it every
///   candidate and acts only on the ones that were actually new.
/// - `account_model`: every model each account's own model list has carried,
///   so the next poll can be diffed against it for newly selectable models.
extension QuotaHistoryStore {

    // MARK: - Events

    /// Inserts the events whose id is not already stored and returns exactly
    /// those, in the order given.
    ///
    /// The return value is the notification contract: a caller that fires a
    /// banner for every element of the returned array fires each event once,
    /// however many polls re-derive it and however often the app restarts.
    /// An event already on disk is left untouched — including its `observedAt`
    /// — so the record keeps when the fact was *first* seen.
    @discardableResult
    public func recordEvents(_ events: [AIEvent]) async throws -> [AIEvent] {
        try await ensureOpen()
        guard !events.isEmpty else { return [] }
        let rows = events

        return try await database.perform { db -> [AIEvent] in
            #if canImport(SQLite3)
            try db.beginTransaction()
            var didCommit = false
            defer { if !didCommit { try? db.rollbackTransaction() } }

            let sql = """
            INSERT OR IGNORE INTO event (
              id, kind, vendor, title, detail, occurred_at, observed_at, source, url
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            var inserted: [AIEvent] = []
            // Within one batch two candidates can share an id (two bars of
            // one vendor resetting at the same instant with the same label is
            // ruled out upstream, but a feed can carry a duplicate guid).
            // `sqlite3_changes` reports the second as ignored, as it should.
            for event in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try db.bindText(stmt, 1, event.id)
                try db.bindText(stmt, 2, event.kind.rawValue)
                try db.bindText(stmt, 3, event.vendorId.rawValue)
                try db.bindText(stmt, 4, event.title)
                try db.bindText(stmt, 5, event.detail)
                try db.bindInt64(stmt, 6, Int64(event.occurredAt.timeIntervalSince1970))
                try db.bindInt64(stmt, 7, Int64(event.observedAt.timeIntervalSince1970))
                try db.bindText(stmt, 8, event.source.rawValue)
                try db.bindText(stmt, 9, event.url?.absoluteString)

                let status = sqlite3_step(stmt)
                guard status == SQLITE_DONE else {
                    throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
                }
                if db.changesInLastStatement() > 0 {
                    inserted.append(event)
                }
            }

            try db.commitTransaction()
            didCommit = true
            return inserted
            #else
            return []
            #endif
        }
    }

    /// Events newest first, optionally narrowed by vendor, kind, and time.
    ///
    /// `since` applies to `occurredAt`, so a feed item published last week but
    /// fetched today is found by the week it belongs to, not by the day
    /// FrugalBar first read the feed.
    public func fetchEvents(
        vendor: VendorIdentifier? = nil,
        kinds: Set<AIEventKind>? = nil,
        since: Date? = nil,
        limit: Int? = nil
    ) async throws -> [AIEvent] {
        try await ensureOpen()

        let vendorString = vendor?.rawValue
        let kindStrings = kinds.map { $0.map(\.rawValue).sorted() }
        let sinceEpoch = since.map { Int64($0.timeIntervalSince1970) }

        return try await database.perform { db -> [AIEvent] in
            #if canImport(SQLite3)
            var conditions: [String] = []
            if vendorString != nil { conditions.append("vendor = ?") }
            if let kindStrings {
                // An empty kind set is a real filter that matches nothing,
                // not "no filter": a UI with every kind unticked shows nothing.
                if kindStrings.isEmpty {
                    conditions.append("0")
                } else {
                    let placeholders = Array(repeating: "?", count: kindStrings.count).joined(separator: ", ")
                    conditions.append("kind IN (\(placeholders))")
                }
            }
            if sinceEpoch != nil { conditions.append("occurred_at >= ?") }

            var sql = """
            SELECT id, kind, vendor, title, detail, occurred_at, observed_at, source, url
            FROM event
            """
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY occurred_at DESC, observed_at DESC, id ASC"
            if let limit, limit > 0 { sql += " LIMIT \(limit)" }
            sql += ";"

            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }

            var bindIdx: Int32 = 1
            if let vendorString {
                try db.bindText(stmt, bindIdx, vendorString)
                bindIdx += 1
            }
            if let kindStrings {
                for kind in kindStrings {
                    try db.bindText(stmt, bindIdx, kind)
                    bindIdx += 1
                }
            }
            if let sinceEpoch {
                try db.bindInt64(stmt, bindIdx, sinceEpoch)
                bindIdx += 1
            }

            var results: [AIEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(stmt, 0),
                      let kindText = sqlite3_column_text(stmt, 1),
                      let vendorText = sqlite3_column_text(stmt, 2),
                      let titleText = sqlite3_column_text(stmt, 3),
                      let sourceText = sqlite3_column_text(stmt, 7)
                else { continue }

                // A row written by a build with a kind, vendor, or source this
                // build does not know is skipped rather than mis-filed under
                // some default: an event of unknown kind is not a price change.
                guard let kind = AIEventKind(rawValue: String(cString: kindText)),
                      let vendorId = VendorIdentifier(rawValue: String(cString: vendorText)),
                      let source = AIEventSource(rawValue: String(cString: sourceText))
                else { continue }

                let detail = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let occurredAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5)))
                let observedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))
                let url = sqlite3_column_text(stmt, 8)
                    .map { String(cString: $0) }
                    .flatMap { URL(string: $0) }

                results.append(AIEvent(
                    id: String(cString: idText),
                    kind: kind,
                    vendorId: vendorId,
                    title: String(cString: titleText),
                    detail: detail,
                    occurredAt: occurredAt,
                    observedAt: observedAt,
                    source: source,
                    url: url
                ))
            }
            return results
            #else
            return []
            #endif
        }
    }

    /// Deletes events that occurred before `cutoff`. Events are small and
    /// useful for a long time, so callers prune on a far longer horizon than
    /// readings (see `AIEventEngine.eventRetentionInterval`).
    public func pruneEvents(before cutoff: Date) async throws {
        try await ensureOpen()
        let epoch = Int64(cutoff.timeIntervalSince1970)
        try await database.perform { db in
            #if canImport(SQLite3)
            let stmt = try db.prepare(sql: "DELETE FROM event WHERE occurred_at < ?;")
            defer { db.finalize(stmt) }
            try db.bindInt64(stmt, 1, epoch)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
            }
            #endif
        }
    }

    // MARK: - Account models

    /// Every model ever seen on `vendor`'s own model list, keyed by model id.
    /// Rows are never deleted, so a model that drops out of one response and
    /// comes back is not announced a second time.
    public func accountModels(vendor: VendorIdentifier) async throws -> [String: AccountModelRecord] {
        try await ensureOpen()
        let vendorString = vendor.rawValue
        return try await database.perform { db -> [String: AccountModelRecord] in
            #if canImport(SQLite3)
            let stmt = try db.prepare(sql: """
            SELECT model_id, name, first_seen, last_seen FROM account_model WHERE vendor = ?;
            """)
            defer { db.finalize(stmt) }
            try db.bindText(stmt, 1, vendorString)

            var result: [String: AccountModelRecord] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(stmt, 0) else { continue }
                let modelId = String(cString: idText)
                result[modelId] = AccountModelRecord(
                    vendorId: vendor,
                    modelId: modelId,
                    name: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                    firstSeen: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2))),
                    lastSeen: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 3)))
                )
            }
            return result
            #else
            return [:]
            #endif
        }
    }

    /// Upserts the given records. Callers carry `firstSeen` forward for a
    /// model already known, so this is a plain replace.
    public func upsertAccountModels(_ records: [AccountModelRecord]) async throws {
        try await ensureOpen()
        guard !records.isEmpty else { return }
        let rows = records

        try await database.perform { db in
            #if canImport(SQLite3)
            try db.beginTransaction()
            var didCommit = false
            defer { if !didCommit { try? db.rollbackTransaction() } }

            let stmt = try db.prepare(sql: """
            INSERT OR REPLACE INTO account_model (vendor, model_id, name, first_seen, last_seen)
            VALUES (?, ?, ?, ?, ?);
            """)
            defer { db.finalize(stmt) }

            for row in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try db.bindText(stmt, 1, row.vendorId.rawValue)
                try db.bindText(stmt, 2, row.modelId)
                try db.bindText(stmt, 3, row.name)
                try db.bindInt64(stmt, 4, Int64(row.firstSeen.timeIntervalSince1970))
                try db.bindInt64(stmt, 5, Int64(row.lastSeen.timeIntervalSince1970))
                let status = sqlite3_step(stmt)
                guard status == SQLITE_DONE else {
                    throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
                }
            }

            try db.commitTransaction()
            didCommit = true
            #endif
        }
    }
}

#if canImport(SQLite3)
extension HistoryDatabase {
    /// Rows changed by the most recent INSERT/UPDATE/DELETE on this
    /// connection. Zero after an `INSERT OR IGNORE` that hit an existing key.
    func changesInLastStatement() -> Int {
        guard let handle = rawHandle else { return 0 }
        return Int(sqlite3_changes(handle))
    }
}
#endif
