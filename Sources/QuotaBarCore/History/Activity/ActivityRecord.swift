import Foundation

/// Represents a single recorded CLI coding agent activity slice or turn.
public struct ActivityRecord: Sendable, Equatable, Identifiable {
    public var id: String { "\(source):\(recordId)" }

    public let source: String
    public let recordId: String
    public let sessionId: String
    public let projectPath: String?
    public let gitBranch: String?
    public let model: String?
    public let observedAt: Date
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    /// Total observed tokens, or `nil` when the source did not report enough to
    /// state one.
    ///
    /// Derived only from a *complete* breakdown: a partial sum presented as a
    /// total would be a measured-looking figure the source never reported, and
    /// these totals feed project token shares.
    public let totalTokens: Int?

    public init(
        source: String,
        recordId: String,
        sessionId: String,
        projectPath: String? = nil,
        gitBranch: String? = nil,
        model: String? = nil,
        observedAt: Date,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.source = source
        self.recordId = recordId
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.model = model
        self.observedAt = observedAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens

        if let totalTokens {
            self.totalTokens = totalTokens
        } else if let inputTokens, let outputTokens, let cacheReadTokens, let cacheWriteTokens {
            self.totalTokens = inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        } else {
            self.totalTokens = nil
        }
    }
}
