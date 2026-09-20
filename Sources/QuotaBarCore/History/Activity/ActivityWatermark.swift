import Foundation

/// Per-file ingestion progress for one activity source.
///
/// The engine previously tracked a single maximum mtime per source, which made
/// every file except the most recently touched one invisible: once any file
/// raised the high-water mark, an append to an older file fell below it and was
/// skipped forever. Progress is therefore recorded per file.
///
/// `cursor` is the resume position *within* that file, and its unit is
/// source-defined:
///
/// - append-only text logs (Claude Code, Codex rollouts) store a **byte offset**
///   that always points at a line boundary;
/// - file-backed databases (OpenCode) store a **source-native position** — the
///   last event timestamp already ingested.
///
/// Staleness is judged on `(fileSize, modifiedAt)`, never on mtime alone: a file
/// can grow without its mtime moving (two writes in the same whole second), and
/// a file can be rewritten in place with an *older* mtime.
public struct ActivityWatermark: Sendable, Equatable {
    public let filePath: String
    /// Size in bytes at the time `cursor` was recorded.
    public let fileSize: Int64
    /// File modification time, epoch seconds (truncated — see `fileSize`).
    public let modifiedAt: Int64
    /// Resume position. See the type doc for the unit.
    public let cursor: Int64

    public init(filePath: String, fileSize: Int64, modifiedAt: Int64, cursor: Int64) {
        self.filePath = filePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.cursor = cursor
    }

    /// True when neither size nor mtime has moved, so there is nothing to read.
    ///
    /// Size is compared first and mtime second because mtime is second-granular:
    /// same-second appends are common, and an equality test on size alone would
    /// also miss a rewrite that preserved length.
    public func isUnchanged(fileSize: Int64, modifiedAt: Int64) -> Bool {
        self.fileSize == fileSize && self.modifiedAt == modifiedAt
    }
}

/// What one adapter pass observed: the records it parsed, plus the per-file
/// progress to persist once those records are safely stored.
public struct ActivityIngestResult: Sendable {
    public let records: [ActivityRecord]
    public let watermarks: [ActivityWatermark]

    public init(records: [ActivityRecord] = [], watermarks: [ActivityWatermark] = []) {
        self.records = records
        self.watermarks = watermarks
    }

    public static let empty = ActivityIngestResult()
}

public enum ActivityAdapterError: Error, LocalizedError, Sendable {
    /// A file-backed source could not be read because another process holds a
    /// write lock. Distinguished from "nothing new" on purpose: a locked
    /// database is a failed read, not an idle one.
    case sourceBusy(path: String)

    public var errorDescription: String? {
        switch self {
        case let .sourceBusy(path):
            "Activity source is locked by another process: \(path)"
        }
    }
}
