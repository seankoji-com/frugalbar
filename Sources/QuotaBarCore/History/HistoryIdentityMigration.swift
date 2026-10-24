import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Moves pre-repair published identities out of the ledger and into
/// fingerprints.
///
/// A database written before the privacy repair holds the published account and
/// workspace ids in `activity_request.account_id` / `workspace_id`, and the
/// public provider label in `billing_provider`. This migration copies the
/// provider label across, writes each identity's `IdentityFingerprint` into the
/// new `account_hash` / `workspace_hash` columns, and empties the raw columns in
/// the same statement — so a row is never in a state where both forms exist.
///
/// It changes no token, time, model, project or record identity, so usage and
/// attribution are preserved exactly. Rows that carry no raw identity are not
/// touched, which makes a second open a no-op. It is additive: `HistorySchema`
/// adds the three columns in place and the schema version is not bumped.
enum HistoryIdentityMigration {

    static func run(in db: HistoryDatabase) throws {
        #if canImport(SQLite3)
        try migrate(in: db)
        #else
        _ = db
        #endif
    }

    #if canImport(SQLite3)
    /// A row still carrying a value in a retired raw column, with whatever the
    /// fingerprint columns already hold.
    private struct PendingRow {
        let source: String
        let recordId: String
        let providerLabel: String?
        let accountHash: IdentityFingerprint?
        let workspaceHash: IdentityFingerprint?
        /// A published value that is not yet fingerprinted. Held only until the
        /// row's own statement runs; it is never bound to a column.
        let rawAccount: String?
        let rawWorkspace: String?
    }

    private static func migrate(in db: HistoryDatabase) throws {
        guard try db.tableExists(HistorySchema.activityRequestTable) else { return }
        // A database created by this build never had the retired columns at
        // all, so there is nothing to move and the query below must not name
        // them. Only a database written before the repair has them.
        let retired = ["billing_provider", "account_id", "workspace_id"]
        guard try !columns(in: db).isDisjoint(with: retired) else { return }
        let pending = try pendingRows(in: db)
        guard !pending.isEmpty else { return }

        try db.beginTransaction()
        var didCommit = false
        defer { if !didCommit { try? db.rollbackTransaction() } }

        let update = """
        UPDATE \(HistorySchema.activityRequestTable)
        SET published_provider = COALESCE(published_provider, ?),
            account_hash = COALESCE(account_hash, ?),
            workspace_hash = COALESCE(workspace_hash, ?),
            billing_provider = NULL,
            account_id = NULL,
            workspace_id = NULL
        WHERE source = ? AND record_id = ?;
        """
        let stmt = try db.prepare(sql: update)
        defer { db.finalize(stmt) }

        for row in pending {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            let accountHash = row.accountHash
                ?? IdentityFingerprint.published(row.rawAccount, in: .account)
            let workspaceHash = row.workspaceHash
                ?? IdentityFingerprint.published(row.rawWorkspace, in: .workspace)

            try db.bindText(stmt, 1, row.providerLabel)
            try db.bindText(stmt, 2, accountHash?.stored)
            try db.bindText(stmt, 3, workspaceHash?.stored)
            try db.bindText(stmt, 4, row.source)
            try db.bindText(stmt, 5, row.recordId)

            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw HistoryDatabaseError.stepFailed(code: status, message: db.lastErrorMessage)
            }
        }

        try db.commitTransaction()
        didCommit = true

        // The UPDATE removed the values from the live rows, but SQLite keeps
        // the old cell bytes in pages it has not rewritten. Compact so the
        // retired columns are gone from the file too. The rows are already
        // scrubbed, so a compaction that cannot run (no space, a busy reader
        // this connection cannot see) must not stop the app opening its
        // history — it is reported instead of pretending nothing is left.
        do {
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
            try db.execute(sql: "VACUUM;")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        } catch {
            NSLog(
                "frugalbar: history identity migration scrubbed %ld identity column(s) but could not compact the database: %@",
                pending.count, String(describing: error))
        }
    }

    private static func columns(in db: HistoryDatabase) throws -> Set<String> {
        let stmt = try db.prepare(sql: "PRAGMA table_info(\(HistorySchema.activityRequestTable));")
        defer { db.finalize(stmt) }
        var names = Set<String>()
        while try db.step(stmt) {
            if let name = sqlite3_column_text(stmt, 1) { names.insert(String(cString: name)) }
        }
        return names
    }

    private static func pendingRows(in db: HistoryDatabase) throws -> [PendingRow] {
        let sql = """
        SELECT source, record_id, billing_provider, account_id, workspace_id,
               published_provider, account_hash, workspace_hash
        FROM \(HistorySchema.activityRequestTable)
        WHERE account_id IS NOT NULL
           OR workspace_id IS NOT NULL
           OR (billing_provider IS NOT NULL AND published_provider IS NULL);
        """
        let stmt = try db.prepare(sql: sql)
        defer { db.finalize(stmt) }

        var rows: [PendingRow] = []
        while try db.step(stmt) {
            guard let sourceText = sqlite3_column_text(stmt, 0),
                  let recordIdText = sqlite3_column_text(stmt, 1) else { continue }
            let providerLabel: String? = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                ?? sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let storedAccountHash: String? = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let storedWorkspaceHash: String? = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            rows.append(PendingRow(
                source: String(cString: sourceText),
                recordId: String(cString: recordIdText),
                providerLabel: providerLabel,
                accountHash: storedAccountHash.flatMap {
                    IdentityFingerprint(stored: $0, expecting: .account)
                },
                workspaceHash: storedWorkspaceHash.flatMap {
                    IdentityFingerprint(stored: $0, expecting: .workspace)
                },
                rawAccount: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
                rawWorkspace: sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            ))
        }
        return rows
    }
    #endif
}
