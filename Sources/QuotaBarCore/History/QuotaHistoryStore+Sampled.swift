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
///
/// A bucket also keeps its earliest and latest row without a fraction, under
/// every label, `providerPollLabel` included. Those rows are what break a
/// line across an outage, and keeping only the latest row dropped them: a
/// failed poll followed by a recovery in the same bucket, or two failed polls
/// either side of a reading, left a sparkline drawn straight across the
/// outage that the full read broke. With the first and last failure of every
/// bucket, any failure that fell between two kept readings of a window has a
/// kept failure between them too.
extension QuotaHistoryStore {

    /// The latest reading per instance, window and `bucketSeconds`-wide bucket
    /// in `since ... until`, plus that bucket's earliest and latest reading
    /// without a fraction, oldest first. `since` nil reads from the start of
    /// the history.
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
            // single MAX() or MIN() aggregate in its group, so every column
            // below belongs to that one reading. UNION drops the row a
            // bucket returns twice, when its latest reading is also its
            // latest (or only) failure.
            func select(_ aggregate: String, failuresOnly: Bool) -> String {
                var part = """
                SELECT vendor, bar_label, \(aggregate)(measured_at), fraction, is_blocked,
                       confidence, urgency, resets_at, window_length, elapsed_only
                FROM reading
                WHERE measured_at <= ?
                """
                if sinceEpoch != nil { part += " AND measured_at >= ?" }
                if failuresOnly { part += " AND fraction IS NULL" }
                return part + " GROUP BY vendor, bar_label, measured_at / ?"
            }
            let parts = [
                select("MAX", failuresOnly: false),
                select("MAX", failuresOnly: true),
                select("MIN", failuresOnly: true),
            ]
            let sql = parts.joined(separator: "\nUNION\n") + "\nORDER BY 3 ASC, 1 ASC, 2 ASC;"

            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }
            var index: Int32 = 1
            for _ in parts {
                try db.bindInt64(stmt, index, untilEpoch)
                index += 1
                if let sinceEpoch {
                    try db.bindInt64(stmt, index, sinceEpoch)
                    index += 1
                }
                try db.bindInt64(stmt, index, size)
                index += 1
            }

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
