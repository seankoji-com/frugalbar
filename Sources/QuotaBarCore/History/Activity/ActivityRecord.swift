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
    /// Total observed tokens, or `nil` when the source reported no token figures
    /// at all.
    ///
    /// When the source did not publish a total, this is the sum of the
    /// components it *did* report — a true statement about what was observed.
    /// The components above stay `nil` when unreported, so an absent figure is
    /// never mistaken for a measured zero; that coercion was the defect, not
    /// the summing.
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
        } else {
            let reported = [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens].compactMap { $0 }
            self.totalTokens = reported.isEmpty ? nil : reported.reduce(0, +)
        }
    }
}
