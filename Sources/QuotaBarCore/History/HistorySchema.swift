import Foundation

public enum HistorySchema {
    public static let readingTable = "reading"
    public static let activityTable = "activity"
    public static let ingestWatermarkTable = "ingest_watermark"
    public static let eventTable = "event"
    public static let catalogModelTable = "catalog_model"
    public static let feedItemTable = "feed_item"

    /// Bumped whenever `createTablesSQL` changes shape.
    ///
    /// The store has never shipped in a release, so a version bump resets rather
    /// than migrates: the only databases in existence are development ones, and
    /// dropping them is safer than a bespoke migration path that will not be
    /// exercised again once the feature is released. Once this ships, migrations
    /// must become additive instead.
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

    -- The three tables below were added after `version` 1 shipped. They are
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

    CREATE TABLE IF NOT EXISTS catalog_model (
      model_id         TEXT    NOT NULL,  -- e.g. "anthropic/claude-opus-5-5"
      vendor           TEXT    NOT NULL,  -- VendorIdentifier.rawValue
      name             TEXT    NOT NULL,
      created_at       INTEGER,           -- the catalog's own `created`; NULL when unpublished
      prompt_price     TEXT,              -- USD per token, decimal text; NULL = unpublished
      completion_price TEXT,
      first_seen       INTEGER NOT NULL,
      last_seen        INTEGER NOT NULL,
      PRIMARY KEY (model_id)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS feed_item (
      feed          TEXT    NOT NULL,    -- feed short name, e.g. "openai-news"
      item_id       TEXT    NOT NULL,    -- the item's guid/id, or its link when it has none
      seen_at       INTEGER NOT NULL,
      PRIMARY KEY (feed, item_id)
    ) WITHOUT ROWID;
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
