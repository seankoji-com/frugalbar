import Foundation

public enum HistorySchema {
    public static let readingTable = "reading"
    public static let activityTable = "activity"
    public static let ingestWatermarkTable = "ingest_watermark"

    public static let createTablesSQL = """
    CREATE TABLE IF NOT EXISTS reading (
      vendor        TEXT    NOT NULL,
      bar_label     TEXT    NOT NULL,      -- "5H" / "WK" / "MO" / "CYCLE"
      measured_at   INTEGER NOT NULL,      -- epoch seconds
      fraction      REAL,                  -- NULL = no reading. NEVER 0 as a stand-in.
      is_blocked    INTEGER NOT NULL,
      confidence    INTEGER NOT NULL,      -- Confidence.rawValue: measured=0, unavailable=1
      urgency       INTEGER NOT NULL,
      resets_at     INTEGER,
      window_length INTEGER,
      elapsed_only  INTEGER NOT NULL,      -- DualBarMetrics.measuresElapsedTimeOnly
      PRIMARY KEY (vendor, bar_label, measured_at)
    ) WITHOUT ROWID;

    CREATE INDEX IF NOT EXISTS reading_vendor_time ON reading(vendor, measured_at);

    CREATE TABLE IF NOT EXISTS activity (
      source        TEXT    NOT NULL,    -- "claude-code" | "codex" | "opencode"
      record_id     TEXT    NOT NULL,    -- Claude: message.id · Codex: session_id · OpenCode: session id
      session_id    TEXT    NOT NULL,
      project_path  TEXT,                -- NULL when the tool recorded no cwd
      git_branch    TEXT,
      model         TEXT,
      observed_at   INTEGER NOT NULL,
      input_tokens  INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      total_tokens  INTEGER NOT NULL,
      PRIMARY KEY (source, record_id)          -- the dedup guarantee
    ) WITHOUT ROWID;

    CREATE INDEX IF NOT EXISTS activity_time ON activity(observed_at);
    CREATE INDEX IF NOT EXISTS activity_project ON activity(project_path);

    CREATE TABLE IF NOT EXISTS ingest_watermark (
      source        TEXT    NOT NULL,
      file_path     TEXT    NOT NULL,
      file_size     INTEGER NOT NULL,
      modified_at   INTEGER NOT NULL,
      byte_offset   INTEGER NOT NULL,
      PRIMARY KEY (source, file_path)
    ) WITHOUT ROWID;
    """
}
