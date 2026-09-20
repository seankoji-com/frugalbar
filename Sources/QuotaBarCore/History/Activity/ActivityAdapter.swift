import Foundation

/// Protocol implemented by local CLI tool activity parsers.
public protocol ActivityAdapter: Sendable {
    /// Unique identifier for this activity source, e.g. "claude_code", "codex", "opencode".
    var sourceIdentifier: String { get }

    /// Collects activity created since the previously recorded per-file progress.
    ///
    /// `watermarks` is keyed by file path and holds everything the engine
    /// persisted for this source. Adapters return the progress to store *after*
    /// the engine has written the records, so a crash between the two leaves the
    /// watermark behind and the same records are re-read (and de-duplicated by
    /// `(source, record_id)`) rather than skipped.
    ///
    /// Throwing is meaningful: it tells the engine the source could not be read
    /// at all, which must not be presented as "nothing new".
    func collectActivities(watermarks: [String: ActivityWatermark]) async throws -> ActivityIngestResult
}
