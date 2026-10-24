import Foundation

/// How the source's token components relate to each other.
///
/// A vendor's field names are not enough to say how its figures add up. Codex
/// reports `cached_input_tokens` **inside** `input_tokens`; Claude Code and
/// OpenCode report cache reads/writes **beside** their input. Summing the
/// fields as if they were all additive counted a Codex turn's cached input
/// twice (100 input including 60 cached + 20 output read as 180, not 120).
public enum TokenComponentSemantics: String, Sendable, Equatable {
    /// Every reported component contributes to the total: input + output +
    /// cache reads + cache writes.
    case additive
    /// Cache reads and writes are subsets of input, and reasoning output is a
    /// subset of output. The total is input + output. Never add a subset again.
    case cacheIncludedInInput
}

/// Where a record's `totalTokens` came from.
public enum TokenTotalKind: String, Sendable, Equatable {
    /// The source published this total itself.
    case published
    /// The total was computed from every component the source publishes for
    /// that record, under its component semantics.
    case derived
    /// The total covers only the components the source actually reported; a
    /// figure is still true about what was seen, but not a complete breakdown.
    case partial
    /// A row written before the ledger described its totals. Its figure is
    /// retained as it was recorded, never retroactively relabelled.
    case legacy
    /// No figure was observed. `totalTokens` is nil; this is not zero.
    case unknown
}

/// Whether a record describes one request/message or a whole session.
public enum ActivityGranularity: String, Sendable, Equatable {
    /// One request or assistant message, at the time the source recorded it.
    case request
    /// A session aggregate, placed at the session's last observed turn. Only
    /// legacy rows and sources that cannot expose per-request usage use this.
    case session
    /// A row from the pre-ledger `activity` table.
    case legacy
}

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
    /// Reasoning output tokens. Codex reports this **inside**
    /// `output_tokens`; it is retained for diagnostics but never added to a
    /// total.
    public let reasoningTokens: Int?
    /// Total tokens observed for this record.
    ///
    /// When the source published a total it is stored unchanged. When it did
    /// not, this is the sum of the components the source did report, under
    /// `semantics` — a true statement about what was observed. The components
    /// stay `nil` when unreported, so an absent figure is never mistaken for a
    /// measured zero.
    public let totalTokens: Int?
    public let totalKind: TokenTotalKind
    public let semantics: TokenComponentSemantics
    public let granularity: ActivityGranularity
    /// The billing provider the source published for this record, when it
    /// published one. This is not the CLI's identity: `source == "opencode"`
    /// says which tool wrote the message, not which provider or account it
    /// billed.
    public let billingProvider: String?
    /// A published account identity, when the source wrote one. `nil` means
    /// unpublished, not "the default account".
    public let accountId: String?
    /// A published workspace identity, when the source wrote one. `nil` means
    /// unpublished, not "the legacy workspace".
    public let workspaceId: String?

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
        reasoningTokens: Int? = nil,
        totalTokens: Int? = nil,
        totalKind: TokenTotalKind? = nil,
        semantics: TokenComponentSemantics = .additive,
        granularity: ActivityGranularity = .request,
        billingProvider: String? = nil,
        accountId: String? = nil,
        workspaceId: String? = nil
    ) {
        self.source = source
        self.recordId = recordId
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.model = model
        self.observedAt = observedAt
        self.semantics = semantics
        self.granularity = granularity
        self.billingProvider = billingProvider
        self.accountId = accountId
        self.workspaceId = workspaceId

        // A negative count is not an observation. It is omitted rather than
        // clamped to zero, and the total falls back to what remains known.
        let input = Self.valid(inputTokens)
        let output = Self.valid(outputTokens)
        let cacheRead = Self.valid(cacheReadTokens)
        let cacheWrite = Self.valid(cacheWriteTokens)
        self.inputTokens = input
        self.outputTokens = output
        self.cacheReadTokens = cacheRead
        self.cacheWriteTokens = cacheWrite
        self.reasoningTokens = Self.valid(reasoningTokens)

        if let totalTokens, totalTokens >= 0 {
            self.totalTokens = totalTokens
            self.totalKind = totalKind ?? .published
        } else {
            let derived = Self.deriveTotal(
                input: input, output: output,
                cacheRead: cacheRead, cacheWrite: cacheWrite,
                semantics: semantics)
            self.totalTokens = derived.total
            self.totalKind = totalKind ?? derived.kind
        }
    }

    private static func valid(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func deriveTotal(
        input: Int?,
        output: Int?,
        cacheRead: Int?,
        cacheWrite: Int?,
        semantics: TokenComponentSemantics
    ) -> (total: Int?, kind: TokenTotalKind) {
        switch semantics {
        case .additive:
            let components = [input, output, cacheRead, cacheWrite]
            let reported = components.compactMap { $0 }
            guard !reported.isEmpty else { return (nil, .unknown) }
            guard let sum = adding(reported) else { return (nil, .unknown) }
            return (sum, reported.count == components.count ? .derived : .partial)
        case .cacheIncludedInInput:
            // `cacheRead` and `cacheWrite` are subsets of `input`; reasoning is
            // a subset of `output`. Only the two top-level figures add up.
            let reported = [input, output].compactMap { $0 }
            guard !reported.isEmpty else { return (nil, .unknown) }
            guard let sum = adding(reported) else { return (nil, .unknown) }
            return (sum, input != nil && output != nil ? .derived : .partial)
        }
    }

    private static func adding(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return nil }
            total = sum
        }
        return total
    }
}
