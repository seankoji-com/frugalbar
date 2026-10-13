import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// A thinned read of the `reading` table for overview sparklines.
///
/// The History window's at-a-glance strip draws every provider at once, over
/// up to the whole retention period. Every poll writes a row per window, so
/// a 30-day read of every vendor is hundreds of thousands of rows, most of
/// which a 150pt sparkline cannot show. This keeps one row per instance, per
/// window, per time bucket, chosen inside SQLite.
///
/// Each returned row is a real reading — the latest one recorded in its
/// bucket, with every column as it was written. Nothing is averaged or
/// interpolated, so a point on a sparkline is always a figure some poll
/// actually received, and a bucket whose latest reading had no fraction
/// keeps that `nil` rather than borrowing a neighbour's figure.
extension QuotaHistoryStore {

    /// The latest reading per instance, window and `bucketSeconds`-wide bucket
    /// in `since ... until`, oldest first. `since` nil reads from the start
    /// of the history.
    ///
    /// Throws when the read stops part-way: a short result would draw an
    /// overview missing whichever providers had not been reached yet.
    public func fetchSampledReadings(
        since: Date?,
        until: Date,
        bucketSeconds: Int
    ) async throws -> [ReadingRecord] {
        try await ensureOpen()
        let size = Int64(max(bucketSeconds, 1))
        let sinceEpoch = since.map { Int64($0.timeIntervalSince1970) }
        let untilEpoch = Int64(until.timeIntervalSince1970)

        return try await database.perform { db -> [ReadingRecord] in
            #if canImport(SQLite3)
            // SQLite returns a bare column from the row that supplied the
            // single MAX() aggregate in its group, so every column below
            // belongs to the bucket's latest reading.
            var sql = """
            SELECT vendor, bar_label, MAX(measured_at), fraction, is_blocked,
                   confidence, urgency, resets_at, window_length, elapsed_only
            FROM reading
            WHERE measured_at <= ?
            """
            if sinceEpoch != nil { sql += " AND measured_at >= ?" }
            sql += """
             GROUP BY vendor, bar_label, measured_at / ?
             ORDER BY 3 ASC, vendor ASC, bar_label ASC;
            """

            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }
            var index: Int32 = 1
            try db.bindInt64(stmt, index, untilEpoch)
            index += 1
            if let sinceEpoch {
                try db.bindInt64(stmt, index, sinceEpoch)
                index += 1
            }
            try db.bindInt64(stmt, index, size)

            var results: [ReadingRecord] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
                }
                if let record = Self.readingRecord(from: stmt) { results.append(record) }
            }
            return results
            #else
            return []
            #endif
        }
    }
}
