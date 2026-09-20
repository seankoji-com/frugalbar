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
    public let totalTokens: Int

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
            let inp = inputTokens ?? 0
            let out = outputTokens ?? 0
            let cr = cacheReadTokens ?? 0
            let cw = cacheWriteTokens ?? 0
            self.totalTokens = inp + out + cr + cw
        }
    }
}
