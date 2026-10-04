import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Raw token consumption over time, summed inside SQLite.
///
/// The desktop widget's Tokens layout charts these. A 30-day range can hold
/// hundreds of thousands of per-turn records, so the sums are taken in the
/// database rather than by fetching every row and bucketing it in Swift.
///
/// Everything here is an *observation*: tokens a local tool recorded for a
/// turn or session. A record whose source reported no token figure at all has
/// a `NULL` total, and is counted separately as uncounted — never summed as
/// zero, which would read as "this turn cost nothing".
extension QuotaHistoryStore {

    /// What one source recorded inside one time bucket.
    public struct TokenBucket: Sendable, Equatable {
        public let source: String
        /// Start of the bucket: `anchor + index * bucketSeconds`.
        public let start: Date
        public let tokens: Int
        /// How many records contributed a total to `tokens`.
        public let records: Int

        public init(source: String, start: Date, tokens: Int, records: Int) {
            self.source = source
            self.start = start
            self.tokens = tokens
            self.records = records
        }
    }

    public struct TokenUsage: Sendable, Equatable {
        /// Only buckets where at least one record reported a total.
        public let buckets: [TokenBucket]
        /// Records in the range that reported no total, per source. They are
        /// in no bucket and no sum.
        public let uncountedRecords: [String: Int]

        public init(buckets: [TokenBucket], uncountedRecords: [String: Int]) {
            self.buckets = buckets
            self.uncountedRecords = uncountedRecords
        }

        public static let empty = TokenUsage(buckets: [], uncountedRecords: [:])
    }

    /// Tokens per source per time bucket, for records observed in
    /// `since ... until` (both ends inclusive).
    ///
    /// Buckets are `bucketSeconds` wide and aligned to `anchor`, so the caller
    /// picks where they fall (the widget aligns them to local midnight). An
    /// anchor later than `since` is pulled back to it: a record before the
    /// anchor would otherwise land in bucket zero by integer truncation.
    public func fetchTokenUsage(
        since: Date,
        until: Date,
        bucketSeconds: Int,
        anchor: Date
    ) async throws -> TokenUsage {
        guard bucketSeconds > 0, since <= until else { return .empty }
        try await ensureOpen()

        let sinceEpoch = Int64(since.timeIntervalSince1970)
        let untilEpoch = Int64(until.timeIntervalSince1970)
        let anchorEpoch = min(Int64(anchor.timeIntervalSince1970), sinceEpoch)
        let size = Int64(bucketSeconds)

        return try await database.perform { db -> TokenUsage in
            #if canImport(SQLite3)
            let sql = """
            SELECT source,
                   (observed_at - ?) / ? AS bucket,
                   COALESCE(SUM(total_tokens), 0),
                   COUNT(total_tokens),
                   COUNT(*)
            FROM activity
            WHERE observed_at >= ? AND observed_at <= ?
            GROUP BY source, bucket
            ORDER BY source ASC, bucket ASC;
            """
            let stmt = try db.prepare(sql: sql)
            defer { db.finalize(stmt) }
            try db.bindInt64(stmt, 1, anchorEpoch)
            try db.bindInt64(stmt, 2, size)
            try db.bindInt64(stmt, 3, sinceEpoch)
            try db.bindInt64(stmt, 4, untilEpoch)

            var buckets: [TokenBucket] = []
            var uncounted: [String: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let sourceText = sqlite3_column_text(stmt, 0) else { continue }
                let source = String(cString: sourceText)
                let index = sqlite3_column_int64(stmt, 1)
                let tokens = sqlite3_column_int64(stmt, 2)
                let counted = sqlite3_column_int64(stmt, 3)
                let all = sqlite3_column_int64(stmt, 4)

                if all > counted { uncounted[source, default: 0] += Int(all - counted) }
                // A bucket in which nothing reported a total is not a bucket
                // of zero tokens; it simply has no figure.
                guard counted > 0 else { continue }
                buckets.append(TokenBucket(
                    source: source,
                    start: Date(timeIntervalSince1970: TimeInterval(anchorEpoch + index * size)),
                    tokens: Int(tokens),
                    records: Int(counted)
                ))
            }
            return TokenUsage(buckets: buckets, uncountedRecords: uncounted)
            #else
            return .empty
            #endif
        }
    }
}
