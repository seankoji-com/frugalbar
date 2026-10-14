import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Balance-over-time reads and writes for the `balance_reading` table.
///
/// The figures here are the ones a vendor published across polls that are
/// *not* quotas: an account credit, a key's remaining cap, a credit pool, a
/// count of credits the vendor meters. They ride `record(_:now:)`'s own
/// transaction — one write per poll, in the same pass that records the
/// readings — so a balance series and its readings always agree on which poll
/// they came from.
extension QuotaHistoryStore {

    /// One row to write. Internal so `record(_:now:)` can prepare a batch and
    /// write it inside its existing transaction.
    struct BalanceRowToWrite: Sendable {
        let seriesId: String
        let vendor: String
        let label: String
        let unit: String
        let measuredAt: Int64
        let value: String
    }

    /// The balance rows a batch of snapshots contributes.
    ///
    /// A snapshot contributes its own metric's figure when that figure is a
    /// balance (`BalanceSeries.of`), and one row per prepaid credit entry it
    /// carries — but only when the poll actually read the vendor
    /// (`BalanceSeries.isCurrent`). A poll that did not measure, a poll that
    /// failed and left the previous figures in place, a metric with no balance,
    /// and a cumulative-spend figure all contribute nothing: never a 0 standing
    /// in for a figure nobody published, and never a carried-over figure
    /// re-stamped as this poll's reading.
    static func balanceRows(from snapshots: [QuotaSnapshot], at timestamp: Int64) -> [BalanceRowToWrite] {
        var rows: [BalanceRowToWrite] = []
        for snapshot in snapshots {
            guard BalanceSeries.isCurrent(snapshot) else { continue }
            if let series = BalanceSeries.of(snapshot),
               let value = BalanceSeries.value(of: snapshot.metric) {
                rows.append(row(series, value: value, at: timestamp))
            }
            // An entry rides the fetch the snapshot already made, so the
            // snapshot's own freshness is the entry's too: a poll that failed
            // published no figure to record, and the retained copy's entries are
            // the previous poll's.
            for entry in snapshot.apiCredits {
                guard let series = BalanceSeries.of(entry),
                      let value = BalanceSeries.value(of: entry.metric) else { continue }
                rows.append(row(series, value: value, at: timestamp))
            }
        }
        return rows
    }

    private static func row(
        _ series: BalanceSeries.Series, value: Decimal, at timestamp: Int64
    ) -> BalanceRowToWrite {
        BalanceRowToWrite(
            seriesId: series.id,
            vendor: series.vendor,
            label: series.label,
            unit: series.unit.storageKey,
            measuredAt: timestamp,
            value: decimalText(value)
        )
    }

    /// A money figure as exact decimal text. `Decimal`'s own representation, so
    /// 179.50 round-trips as 179.50 rather than the nearest binary double.
    static func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// The inverse, pinned to a fixed locale so a decimal point is always a
    /// period regardless of the reader's machine.
    static func decimal(fromText text: String) -> Decimal? {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// One series' points in `since ... until`, thinned to at most one per
    /// `bucketSeconds`-wide bucket and returned oldest first.
    ///
    /// Each point is a real reading — the latest one recorded in its bucket,
    /// exactly as written. Nothing is averaged or interpolated, so a point is
    /// always a figure some poll received. Throws when the read stops
    /// part-way, so a short result is a failure to read rather than an absence
    /// of history.
    public func fetchBalancePoints(
        seriesId: String, since: Date?, until: Date, bucketSeconds: Int
    ) async throws -> [BalancePoint] {
        try await ensureOpen()
        let size = Int64(max(bucketSeconds, 1))
        let sinceEpoch = since.map { Int64($0.timeIntervalSince1970) }
        let untilEpoch = Int64(until.timeIntervalSince1970)

        return try await database.perform { db -> [BalancePoint] in
            #if canImport(SQLite3)
            var sql = """
            SELECT MAX(measured_at), value
            FROM balance_reading
            WHERE series_id = ? AND measured_at <= ?
            """
            if sinceEpoch != nil { sql += " AND measured_at >= ?" }
            sql += " GROUP BY measured_at / ? ORDER BY MAX(measured_at) ASC;"

            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }
            try db.bindText(stmt, 1, seriesId)
            var index: Int32 = 2
            try db.bindInt64(stmt, index, untilEpoch); index += 1
            if let sinceEpoch { try db.bindInt64(stmt, index, sinceEpoch); index += 1 }
            try db.bindInt64(stmt, index, size)

            return try Self.balancePoints(from: stmt, db: db)
            #else
            return []
            #endif
        }
    }

    /// Every series' points in `since ... until`, thinned the same way, keyed
    /// by series id. One query for the popover's inline sparklines, so opening
    /// it does not issue one read per row.
    ///
    /// `seriesIds` nil reads every series in the window.
    public func fetchBalanceSeries(
        since: Date, until: Date, bucketSeconds: Int, seriesIds: [String]? = nil
    ) async throws -> [String: [BalancePoint]] {
        try await ensureOpen()
        let size = Int64(max(bucketSeconds, 1))
        let sinceEpoch = Int64(since.timeIntervalSince1970)
        let untilEpoch = Int64(until.timeIntervalSince1970)

        return try await database.perform { db -> [String: [BalancePoint]] in
            #if canImport(SQLite3)
            var sql = """
            SELECT series_id, MAX(measured_at), value
            FROM balance_reading
            WHERE measured_at <= ? AND measured_at >= ?
            """
            let narrowed = seriesIds.map { !$0.isEmpty } ?? false
            if narrowed, let seriesIds {
                sql += " AND series_id IN (\(Array(repeating: "?", count: seriesIds.count).joined(separator: ",")))"
            }
            sql += " GROUP BY series_id, measured_at / ? ORDER BY series_id ASC, MAX(measured_at) ASC;"

            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }
            try db.bindInt64(stmt, 1, untilEpoch)
            try db.bindInt64(stmt, 2, sinceEpoch)
            var index: Int32 = 3
            if narrowed, let seriesIds {
                for id in seriesIds { try db.bindText(stmt, index, id); index += 1 }
            }
            try db.bindInt64(stmt, index, size)

            var result: [String: [BalancePoint]] = [:]
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
                }
                guard let idC = sqlite3_column_text(stmt, 0),
                      let point = Self.balancePoint(measuredAtColumn: 1, valueColumn: 2, stmt: stmt)
                else { continue }
                result[String(cString: idC), default: []].append(point)
            }
            return result
            #else
            return [:]
            #endif
        }
    }

    #if canImport(SQLite3)
    /// Rows of `(MAX(measured_at), value)` from a statement, oldest first.
    private static func balancePoints(from stmt: OpaquePointer?, db: HistoryDatabase) throws -> [BalancePoint] {
        var results: [BalancePoint] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
            }
            if let point = balancePoint(measuredAtColumn: 0, valueColumn: 1, stmt: stmt) {
                results.append(point)
            }
        }
        return results
    }

    private static func balancePoint(
        measuredAtColumn: Int32, valueColumn: Int32, stmt: OpaquePointer?
    ) -> BalancePoint? {
        guard let textC = sqlite3_column_text(stmt, valueColumn),
              let value = decimal(fromText: String(cString: textC)) else { return nil }
        let epoch = sqlite3_column_int64(stmt, measuredAtColumn)
        return BalancePoint(measuredAt: Date(timeIntervalSince1970: TimeInterval(epoch)), value: value)
    }
    #endif
}
