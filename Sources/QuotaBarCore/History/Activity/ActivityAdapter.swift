import Foundation

/// Protocol implemented by local CLI tool activity parsers.
public protocol ActivityAdapter: Sendable {
    /// Unique identifier for this activity source, e.g. "claude_code", "codex", "opencode".
    var sourceIdentifier: String { get }

    /// Collects new activity records created or modified since `watermarkMtime`.
    /// Returns the parsed records and the maximum modification timestamp observed.
    func collectActivities(since watermarkMtime: Int64?) async throws -> (records: [ActivityRecord], maxMtime: Int64?)
}
