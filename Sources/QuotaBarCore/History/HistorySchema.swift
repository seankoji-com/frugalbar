import Foundation

public enum HistorySchema {
    public static let readingTable = "reading"
    public static let activityTable = "activity"
    /// Per-request ledger rows written since the accounting change. Kept apart
    /// from `activity` so legacy rows can never be rewritten in place.
    ///
    /// The published account and workspace identities are stored only as
    /// `account_hash`/`workspace_hash` fingerprints (`IdentityFingerprint`).
    /// A database written before that change still has the retired raw
    /// `account_id`/`workspace_id` columns; `HistoryIdentityMigration` adds the
    /// fingerprint columns in place, moves the values across, and empties the
    /// raw columns. It is additive and idempotent — no version bump, and no row
    /// loses a token, time or model figure.
    public static let activityRequestTable = "activity_request"
    /// The read-only union the app queries: every ledger row, plus legacy
    /// `activity` rows that no ledger row has superseded.
    public static let activityUnifiedView = "activity_unified"
    public static let activitySourceStatusTable = "activity_source_status"
    public static let ingestWatermarkTable = "ingest_watermark"
    public static let eventTable = "event"
    public static let catalogModelTable = "catalog_model"
    public static let feedItemTable = "feed_item"
    public static let accountModelTable = "account_model"
    public static let balanceReadingTable = "balance_reading"

    /// The on-disk schema generation. A mismatch on open drops every table.
    ///
    /// Version 1 has shipped, so this must not be bumped any more: a bump
    /// deletes the user's readings. New tables are added to `createTablesSQL`
    /// as `CREATE TABLE IF NOT EXISTS` (the `event`, `catalog_model`,
    /// `feed_item` and `account_model` tables arrived that way, additively, under the same
    /// version). Changing an existing table's shape needs a real migration.
    public static let version: Int32 = 1

    public static let createTablesSQL = """
    -- Derived views are rebuilt on every open so a changed coexistence rule
    -- reaches an existing database without a schema-version bump. They hold
    -- no rows.
    DROP VIEW IF EXISTS activity_unified;
    DROP VIEW IF EXISTS activity_reconciled_aggregate;
    DROP VIEW IF EXISTS activity_aggregate;

    CREATE TABLE IF NOT EXISTS reading (
      vendor        TEXT    NOT NULL,
      bar_label     TEXT    NOT NULL,      -- "5H" / "WK" / "MO" / "CYCLE"
      measured_at   INTEGER NOT NULL,      -- epoch seconds
      fraction      REAL,                  -- NULL = no reading. NEVER 0 as a stand-in.
      is_blocked    INTEGER NOT NULL,
      confidence    TEXT    NOT NULL,      -- Confidence case name, not its ordinal
      urgency       TEXT    NOT NULL,      -- Urgency case name, not its ordinal
      resets_at     INTEGER,
      window_length INTEGER,
      elapsed_only  INTEGER NOT NULL,      -- DualBarMetrics.measuresElapsedTimeOnly
      PRIMARY KEY (vendor, bar_label, measured_at)
    ) WITHOUT ROWID;

    CREATE INDEX IF NOT EXISTS reading_vendor_time ON reading(vendor, measured_at);

    CREATE TABLE IF NOT EXISTS activity (
      source        TEXT    NOT NULL,    -- "claude-code" | "codex" | "opencode"
      record_id     TEXT    NOT NULL,    -- Claude: message.id · Codex: session_id · OpenCode: message id
      session_id    TEXT    NOT NULL,
      project_path  TEXT,                -- NULL when the tool recorded no cwd
      git_branch    TEXT,
      model         TEXT,
      observed_at   INTEGER NOT NULL,
      input_tokens  INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      total_tokens  INTEGER,             -- NULL when the source reported no total
      PRIMARY KEY (source, record_id)          -- the dedup guarantee
    ) WITHOUT ROWID;

    CREATE INDEX IF NOT EXISTS activity_time ON activity(observed_at);
    CREATE INDEX IF NOT EXISTS activity_project ON activity(project_path);

    -- The ledger written since the accounting change. New adapter rows go
    -- here, never into `activity`, so existing rows survive unchanged and the
    -- old table can always be read as history. See `activity_unified`.
    CREATE TABLE IF NOT EXISTS activity_request (
      source        TEXT    NOT NULL,    -- tool/source identity, not billing identity
      record_id     TEXT    NOT NULL,    -- stable source record id (response_id, message id)
      session_id    TEXT    NOT NULL,
      project_path  TEXT,
      git_branch    TEXT,
      model         TEXT,
      observed_at   INTEGER NOT NULL,    -- epoch seconds, at the source's own recorded time
      input_tokens  INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      reasoning_tokens  INTEGER,         -- a subset of output; never summed
      total_tokens  INTEGER,             -- NULL = unknown, never zero
      total_kind    TEXT    NOT NULL,    -- published | derived | partial | unknown
      semantics     TEXT    NOT NULL,    -- additive | cacheIncludedInInput
      granularity   TEXT    NOT NULL,    -- request | session
      -- The provider label the source published (public metadata, kept
      -- verbatim). The account and workspace it published are private
      -- identifiers nobody needs to read back, so only a domain-separated
      -- SHA-256 of each is stored here (IdentityFingerprint). A raw published
      -- account or workspace id must never be written to any column.
      published_provider TEXT,
      account_hash  TEXT,                -- fbfp1.account.<sha256> | NULL = unpublished
      workspace_hash TEXT,               -- fbfp1.workspace.<sha256> | NULL = unpublished
      PRIMARY KEY (source, record_id)
    ) WITHOUT ROWID;

    CREATE INDEX IF NOT EXISTS activity_request_time ON activity_request(observed_at);
    CREATE INDEX IF NOT EXISTS activity_request_session ON activity_request(source, session_id);

    -- What each source last managed to read, and what it could not represent.
    -- Persisted so an unchanged-file skip cannot erase yesterday's diagnostics.
    CREATE TABLE IF NOT EXISTS activity_source_status (
      source        TEXT    NOT NULL,    -- adapter source identifier
      last_scan_at  INTEGER,             -- epoch seconds, NULL = never scanned here
      last_successful_scan_at INTEGER,   -- every input found was read
      read_failures INTEGER NOT NULL,
      malformed_records INTEGER NOT NULL,
      inconsistent_records INTEGER NOT NULL,
      incomplete_records INTEGER NOT NULL,
      records_observed INTEGER NOT NULL,
      last_pass_complete INTEGER NOT NULL,
      PRIMARY KEY (source)
    ) WITHOUT ROWID;

    -- Per-input diagnostics. Kept apart from the per-source roll-up so an
    -- unchanged faulty file keeps its own counts while a different file is
    -- read cleanly. Rows are added and removed with the input set; no
    -- history table is rewritten.
    CREATE TABLE IF NOT EXISTS activity_input_status (
      source        TEXT    NOT NULL,
      file_path     TEXT    NOT NULL,
      malformed_records INTEGER NOT NULL,
      inconsistent_records INTEGER NOT NULL,
      incomplete_records INTEGER NOT NULL,
      records_observed INTEGER NOT NULL,
      read_failure  INTEGER NOT NULL,
      last_scanned_at INTEGER NOT NULL,
      PRIMARY KEY (source, file_path)
    ) WITHOUT ROWID;

    -- One read surface for activity. Legacy `activity` rows are used only
    -- when a ledger row supersedes them:
    --   * the same (source, record_id) a Claude/OpenCode re-read has written;
    --   * for Codex, a session aggregate (legacy or ledger) is shown only
    --     while its tokens are not fully reconstructed by request rows.
    --
    -- A Codex session aggregate is a published cumulative total. When request
    -- rows for that session, observed at or before the aggregate, have known
    -- totals summing to at least that total, the aggregate is proven
    -- superseded and the request rows are the accounting. Otherwise the
    -- aggregate stays, and request rows observed inside it are withheld from
    -- totals: they are already part of that total. A request observed after
    -- the aggregate is additive — the cumulative counter cannot contain it.
    -- Nothing is allocated to a time the source did not record, and no
    -- observation is deleted.
    CREATE VIEW IF NOT EXISTS activity_aggregate AS
    SELECT source, record_id, session_id, project_path, git_branch, model,
           observed_at, input_tokens, output_tokens, cache_read_tokens,
           cache_write_tokens,
           NULL AS reasoning_tokens,
           total_tokens,
           'legacy' AS total_kind,
           CASE WHEN source = 'codex' THEN 'cacheIncludedInInput' ELSE 'additive' END AS semantics,
           'session' AS granularity,
           NULL AS published_provider,
           NULL AS account_hash,
           NULL AS workspace_hash
    FROM activity
    WHERE source = 'codex'
      AND NOT EXISTS (
        SELECT 1 FROM activity_request r
        WHERE r.source = activity.source AND r.record_id = activity.record_id
      )
    UNION ALL
    SELECT source, record_id, session_id, project_path, git_branch, model,
           observed_at, input_tokens, output_tokens, cache_read_tokens,
           cache_write_tokens, reasoning_tokens, total_tokens, total_kind,
           semantics, granularity, published_provider, account_hash, workspace_hash
    FROM activity_request
    WHERE granularity = 'session';

    CREATE VIEW IF NOT EXISTS activity_reconciled_aggregate AS
    SELECT a.source, a.record_id
    FROM activity_aggregate a
    WHERE a.total_tokens IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM activity_request r
        WHERE r.source = a.source
          AND r.session_id = a.session_id
          AND r.granularity = 'request'
          AND r.observed_at <= a.observed_at
        GROUP BY r.session_id
        HAVING COUNT(r.total_tokens) = COUNT(*)
           AND SUM(r.total_tokens) >= a.total_tokens
      );

    CREATE VIEW IF NOT EXISTS activity_unified AS
    -- Legacy non-Codex rows stand in for a request the ledger has not
    -- re-read; any same-id ledger row replaces one.
    SELECT source, record_id, session_id, project_path, git_branch, model,
           observed_at, input_tokens, output_tokens, cache_read_tokens,
           cache_write_tokens, NULL AS reasoning_tokens, total_tokens,
           'legacy' AS total_kind, 'additive' AS semantics, 'legacy' AS granularity,
           NULL AS published_provider, NULL AS account_hash, NULL AS workspace_hash
    FROM activity
    WHERE source <> 'codex'
      AND NOT EXISTS (
        SELECT 1 FROM activity_request r
        WHERE r.source = activity.source AND r.record_id = activity.record_id
      )
    UNION ALL
    -- A session aggregate remains until request rows prove they cover it.
    SELECT a.source, a.record_id, a.session_id, a.project_path, a.git_branch, a.model,
           a.observed_at, a.input_tokens, a.output_tokens, a.cache_read_tokens,
           a.cache_write_tokens, a.reasoning_tokens, a.total_tokens, a.total_kind,
           a.semantics, a.granularity, a.published_provider, a.account_hash, a.workspace_hash
    FROM activity_aggregate a
    WHERE NOT EXISTS (
      SELECT 1 FROM activity_reconciled_aggregate reconciled
      WHERE reconciled.source = a.source AND reconciled.record_id = a.record_id
    )
    UNION ALL
    -- A request inside an unreconciled aggregate is already counted there.
    SELECT r.source, r.record_id, r.session_id, r.project_path, r.git_branch, r.model,
           r.observed_at, r.input_tokens, r.output_tokens, r.cache_read_tokens,
           r.cache_write_tokens, r.reasoning_tokens, r.total_tokens, r.total_kind,
           r.semantics, r.granularity, r.published_provider, r.account_hash, r.workspace_hash
    FROM activity_request r
    WHERE r.granularity = 'request'
      AND NOT EXISTS (
        SELECT 1 FROM activity_aggregate a
        WHERE a.source = r.source
          AND a.session_id = r.session_id
          AND a.observed_at >= r.observed_at
          AND a.total_tokens IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM activity_reconciled_aggregate reconciled
            WHERE reconciled.source = a.source AND reconciled.record_id = a.record_id
          )
      );

    CREATE TABLE IF NOT EXISTS ingest_watermark (
      source        TEXT    NOT NULL,
      file_path     TEXT    NOT NULL,
      file_size     INTEGER NOT NULL,    -- size at the time `byte_offset` was recorded
      modified_at   INTEGER NOT NULL,    -- epoch seconds (truncated — size carries the rest)
      byte_offset   INTEGER NOT NULL,    -- resume cursor; unit is source-defined
      PRIMARY KEY (source, file_path)
    ) WITHOUT ROWID;

    -- The tables below were added after `version` 1 shipped. They are
    -- purely additive (`CREATE TABLE IF NOT EXISTS` on every open), so the
    -- version is deliberately NOT bumped: a bump drops the user's readings.

    CREATE TABLE IF NOT EXISTS event (
      id            TEXT    NOT NULL,    -- AIEvent.id, the dedup key
      kind          TEXT    NOT NULL,    -- AIEventKind.rawValue
      vendor        TEXT    NOT NULL,    -- VendorIdentifier.rawValue
      instance_id   TEXT,                -- QuotaSnapshot.id (NULL = the vendor's own event)
      title         TEXT    NOT NULL,
      detail        TEXT,
      occurred_at   INTEGER NOT NULL,    -- epoch seconds
      observed_at   INTEGER NOT NULL,    -- epoch seconds
      source        TEXT    NOT NULL,    -- AIEventSource.rawValue
      url           TEXT,
      PRIMARY KEY (id)
    ) WITHOUT ROWID;

    CREATE INDEX IF NOT EXISTS event_time ON event(occurred_at);
    CREATE INDEX IF NOT EXISTS event_vendor_time ON event(vendor, occurred_at);

    -- `catalog_model` and `feed_item` (the OpenRouter catalog and vendor news
    -- feeds) are retired: nothing reads or writes them, and databases that
    -- already have them keep them untouched. `dropTablesSQL` still names them.

    CREATE TABLE IF NOT EXISTS account_model (
      vendor        TEXT    NOT NULL,    -- VendorIdentifier.rawValue
      model_id      TEXT    NOT NULL,    -- the vendor's own id, e.g. "gpt-6.1-sol"
      name          TEXT,                -- display name when the vendor publishes one
      first_seen    INTEGER NOT NULL,
      last_seen     INTEGER NOT NULL,
      PRIMARY KEY (vendor, model_id)
    ) WITHOUT ROWID;

    -- Balance-over-time: the figures a vendor published across polls that are
    -- *not* quotas — account credit, a key's remaining cap, a credit pool, a
    -- count of credits the vendor meters. Kept apart from `reading` because
    -- these have no window and no fraction: `reading.fraction` is a share of a
    -- denominator, and a balance has none. `value` is exact decimal text, not
    -- REAL, so a money figure round-trips without binary rounding.
    CREATE TABLE IF NOT EXISTS balance_reading (
      series_id     TEXT    NOT NULL,    -- BalanceSeries.id: "<source>|<unit>"
      vendor        TEXT    NOT NULL,    -- VendorIdentifier.rawValue
      label         TEXT    NOT NULL,    -- the row's own label, as written
      unit          TEXT    NOT NULL,    -- "currency:USD" | "credits:credits"
      measured_at   INTEGER NOT NULL,    -- epoch seconds
      value         TEXT    NOT NULL,    -- the observed figure, exact decimal text
      PRIMARY KEY (series_id, measured_at)
    ) WITHOUT ROWID;
    """

    // No secondary index on `balance_reading`. The `WITHOUT ROWID` table's
    // primary key *is* its clustering b-tree, so an index on
    // `(series_id, measured_at)` would be a second copy of the same keys: pure
    // dead storage and one more b-tree write on every poll. Neither read could
    // use it either — a `series_id` prefix is served by the primary key order
    // itself, an unfiltered `fetchBalanceSeries` has no `series_id` predicate
    // to use it with, and the retention prune (`WHERE measured_at < ?`) cannot
    // use a `series_id`-first key at all.

    /// Idempotent in-place rewrites of stored values, run on every open after
    /// the tables exist. Never a shape change and never a delete.
    ///
    /// - Command Code's monthly plan credits were stored under the window
    ///   token "CR" until the token was standardised to "MO". Renaming the
    ///   old rows keeps that history one continuous series. The vendor never
    ///   wrote an "MO" row before, so the primary key cannot collide; `OR
    ///   IGNORE` makes that certain rather than assumed.
    /// - Grok's fallback for a period with no type and no length was "CR"
    ///   too; it is now "PLAN", and its readings follow.
    /// - OpenCode Go readings used to be filed under the bare vendor key
    ///   `opencode`. They now belong to the legacy workspace's stable instance
    ///   key, so a workspace-scoped query finds them and a second workspace's
    ///   rows cannot collide with them. Renaming the key keeps that history one
    ///   continuous series.
    /// - The same rename for OpenCode Go's *poll-derived events* (resets,
    ///   restores, credit grants). Only `source = 'quotaPoll'` rows are
    ///   claimed: a status-page incident or a news item is the vendor's own
    ///   event, not one subscription's, and stays NULL so it shows for every
    ///   workspace.
    ///
    /// The keys are interpolated from the constants that write them. Written
    /// out by hand they would compile even after `legacyID` or the prefix were
    /// renamed, silently orphaning the very rows they exist to carry.
    public static let dataMigrationsSQL = """
    UPDATE OR IGNORE reading SET bar_label = 'MO' WHERE vendor = 'commandcode' AND bar_label = 'CR';
    UPDATE OR IGNORE reading SET bar_label = 'PLAN' WHERE vendor = 'grok' AND bar_label = 'CR';
    UPDATE OR IGNORE reading SET vendor = '\(legacyOpenCodeKey)' WHERE vendor = '\(openCodeVendorKey)';
    UPDATE event SET instance_id = '\(legacyOpenCodeKey)'
      WHERE vendor = '\(openCodeVendorKey)' AND instance_id IS NULL AND source = '\(quotaPollSource)';
    """

    /// The pre-workspace OpenCode Go key, and the key its single subscription
    /// now carries. Named here rather than typed into the SQL above so the
    /// migration cannot drift from the runtime constants — a hand-written
    /// `'quotaPoll'` where the raw value is `quota-poll` matches nothing, and
    /// the migration would silently do nothing.
    private static let openCodeVendorKey = VendorIdentifier.opencode.rawValue
    private static let quotaPollSource = AIEventSource.quotaPoll.rawValue
    static let legacyOpenCodeKey = OpenCodeGoWorkspaceStore.instancePrefix + OpenCodeGoWorkspaceStore.legacyID

    /// Drops every table. Used only to reset a development database whose schema
    /// predates `version`.
    public static let dropTablesSQL = """
    DROP VIEW IF EXISTS \(activityUnifiedView);
    DROP VIEW IF EXISTS activity_reconciled_aggregate;
    DROP VIEW IF EXISTS activity_aggregate;
    DROP TABLE IF EXISTS \(activityRequestTable);
    DROP TABLE IF EXISTS \(activitySourceStatusTable);
    DROP TABLE IF EXISTS activity_input_status;
    DROP TABLE IF EXISTS \(readingTable);
    DROP TABLE IF EXISTS \(activityTable);
    DROP TABLE IF EXISTS \(ingestWatermarkTable);
    DROP TABLE IF EXISTS \(eventTable);
    DROP TABLE IF EXISTS \(catalogModelTable);
    DROP TABLE IF EXISTS \(feedItemTable);
    DROP TABLE IF EXISTS \(accountModelTable);
    DROP TABLE IF EXISTS \(balanceReadingTable);
    """
}

// MARK: - Enum persistence

/// `Confidence` and `Urgency` are persisted by *name*, not by `rawValue`.
///
/// Storing the ordinal made the meaning of every historical row a positional
/// fact about source code that is expected to change: inserting a case in the
/// middle — invisible in a diff — silently reinterpreted all of history. The
/// names survive reordering and insertion.
extension Confidence {
    var historyName: String {
        switch self {
        case .measured:    "measured"
        case .unavailable: "unavailable"
        }
    }

    init?(historyName: String) {
        switch historyName {
        case "measured":    self = .measured
        case "unavailable": self = .unavailable
        default:            return nil
        }
    }
}

extension Urgency {
    var historyName: String {
        switch self {
        case .none:     "none"
        case .warning:  "warning"
        case .critical: "critical"
        }
    }

    init?(historyName: String) {
        switch historyName {
        case "none":     self = .none
        case "warning":  self = .warning
        case "critical": self = .critical
        default:         return nil
        }
    }
}
