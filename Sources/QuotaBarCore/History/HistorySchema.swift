import Foundation

public enum HistorySchema {
    public static let readingTable = "reading"
    public static let activityTable = "activity"
    public static let ingestWatermarkTable = "ingest_watermark"
    public static let eventTable = "event"
    public static let catalogModelTable = "catalog_model"
    public static let feedItemTable = "feed_item"
    public static let accountModelTable = "account_model"
    public static let ingestionStateTable = "ingestion_state"

    /// The on-disk schema generation. A mismatch on open drops every table.
    ///
    /// Version 1 has shipped, so this must not be bumped any more: a bump
    /// deletes the user's readings. New tables are added to `createTablesSQL`
    /// as `CREATE TABLE IF NOT EXISTS` (the `event`, `catalog_model`,
    /// `feed_item` and `account_model` tables arrived that way, additively, under the same
    /// version). Changing an existing table's shape needs a real migration.
    public static let version: Int32 = 1

    public static let createTablesSQL = """
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

    -- Facts about the ingestion pipeline itself, kept beside the data they
    -- describe so they cannot outlive it: a database that has been wiped must
    -- not go on claiming its first full pass has finished.
    CREATE TABLE IF NOT EXISTS ingestion_state (
      key           TEXT    NOT NULL,    -- e.g. "activity_full_pass"
      value         INTEGER NOT NULL,    -- epoch seconds when it last happened
      PRIMARY KEY (key)
    ) WITHOUT ROWID;
    """

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
    public static let dataMigrationsSQL = """
    UPDATE OR IGNORE reading SET bar_label = 'MO' WHERE vendor = 'commandcode' AND bar_label = 'CR';
    UPDATE OR IGNORE reading SET bar_label = 'PLAN' WHERE vendor = 'grok' AND bar_label = 'CR';
    """

    /// Drops every table. Used only to reset a development database whose schema
    /// predates `version`.
    public static let dropTablesSQL = """
    DROP TABLE IF EXISTS \(readingTable);
    DROP TABLE IF EXISTS \(activityTable);
    DROP TABLE IF EXISTS \(ingestWatermarkTable);
    DROP TABLE IF EXISTS \(eventTable);
    DROP TABLE IF EXISTS \(catalogModelTable);
    DROP TABLE IF EXISTS \(feedItemTable);
    DROP TABLE IF EXISTS \(accountModelTable);
    DROP TABLE IF EXISTS \(ingestionStateTable);
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
