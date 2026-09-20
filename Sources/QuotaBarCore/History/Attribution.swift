import Foundation

/// Attribution of observed local coding tokens to projects within a time window.
public struct ProjectAttribution: Sendable, Equatable, Identifiable {
    public var id: String { projectPath }
    public let projectPath: String
    public let displayName: String
    public let tokenCount: Int
    public let tokenShare: Double // 0.0 ... 1.0 of observed tokens in the window
    public let sessionCount: Int

    public init(
        projectPath: String,
        displayName: String,
        tokenCount: Int,
        tokenShare: Double,
        sessionCount: Int
    ) {
        self.projectPath = projectPath
        self.displayName = displayName
        self.tokenCount = tokenCount
        self.tokenShare = tokenShare
        self.sessionCount = sessionCount
    }
}

public enum AttributionCaveat: String, Sendable, Equatable {
    case unmonitoredToolsConfigured = "unmonitored_tools"
    case concurrentSessionsDetected = "concurrent_sessions"
    case unrecordedExternalActivityPossible = "unrecorded_activity"
}

public struct AttributionSummary: Sendable, Equatable {
    public let windowStart: Date
    public let windowEnd: Date
    public let startConsumptionFraction: Double?
    public let endConsumptionFraction: Double?
    public let consumedFractionDelta: Double?
    public let totalObservedTokens: Int
    public let projectAttributions: [ProjectAttribution]
    public let unmonitoredVendors: [VendorIdentifier]
    public let hasConcurrentSessions: Bool
    public let caveats: [AttributionCaveat]

    public init(
        windowStart: Date,
        windowEnd: Date,
        startConsumptionFraction: Double?,
        endConsumptionFraction: Double?,
        consumedFractionDelta: Double?,
        totalObservedTokens: Int,
        projectAttributions: [ProjectAttribution],
        unmonitoredVendors: [VendorIdentifier],
        hasConcurrentSessions: Bool,
        caveats: [AttributionCaveat]
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.startConsumptionFraction = startConsumptionFraction
        self.endConsumptionFraction = endConsumptionFraction
        self.consumedFractionDelta = consumedFractionDelta
        self.totalObservedTokens = totalObservedTokens
        self.projectAttributions = projectAttributions
        self.unmonitoredVendors = unmonitoredVendors
        self.hasConcurrentSessions = hasConcurrentSessions
        self.caveats = caveats
    }
}

public enum AttributionEngine {

    /// Unmonitored vendors that do not produce local CLI telemetry logs.
    public static let unmonitoredVendorIdentifiers: Set<VendorIdentifier> = [
        .grok,
        .kiro,
        .gemini
    ]

    /// Computes project token shares and uncertainty caveats for a given window.
    ///
    /// CRITICAL INVARIANT:
    /// Local CLI tokens are NOT converted into vendor quota percentages.
    /// Instead, project token shares are reported alongside the vendor's measured
    /// allowance delta, with explicit caveats for unmonitored and concurrent sources.
    public static func computeAttribution(
        windowStart: Date,
        windowEnd: Date,
        startConsumptionFraction: Double?,
        endConsumptionFraction: Double?,
        activities: [ActivityRecord],
        configuredVendors: [VendorIdentifier] = []
    ) -> AttributionSummary {
        // 1. Filter activities within window
        let inWindow = activities.filter { record in
            record.observedAt >= windowStart && record.observedAt <= windowEnd
        }

        // 2. Group by project
        var projectTokensMap: [String: Int] = [:]
        var projectSessionsMap: [String: Set<String>] = [:]

        for record in inWindow {
            let path = record.projectPath ?? "Unspecified Directory"
            projectTokensMap[path, default: 0] += record.totalTokens
            projectSessionsMap[path, default: []].insert(record.sessionId)
        }

        let totalObservedTokens = projectTokensMap.values.reduce(0, +)

        // 3. Compute shares
        var attributions: [ProjectAttribution] = []
        for (path, tokens) in projectTokensMap {
            let share = totalObservedTokens > 0 ? (Double(tokens) / Double(totalObservedTokens)) : 0.0
            let displayName = URL(fileURLWithPath: path).lastPathComponent
            let sessionCount = projectSessionsMap[path]?.count ?? 0
            attributions.append(ProjectAttribution(
                projectPath: path,
                displayName: displayName.isEmpty ? path : displayName,
                tokenCount: tokens,
                tokenShare: share,
                sessionCount: sessionCount
            ))
        }

        // Sort descending by token count
        attributions.sort { $0.tokenCount > $1.tokenCount }

        // 4. Allowance delta
        let consumedFractionDelta: Double?
        if let start = startConsumptionFraction, let end = endConsumptionFraction {
            consumedFractionDelta = max(0.0, end - start)
        } else {
            consumedFractionDelta = nil
        }

        // 5. Concurrency check: distinct sessions overlapping within 60s
        var hasConcurrency = false
        if inWindow.count > 1 {
            let sortedByTime = inWindow.sorted { $0.observedAt < $1.observedAt }
            for i in 0..<(sortedByTime.count - 1) {
                let current = sortedByTime[i]
                let next = sortedByTime[i + 1]
                if current.sessionId != next.sessionId &&
                   abs(next.observedAt.timeIntervalSince(current.observedAt)) <= 60 {
                    hasConcurrency = true
                    break
                }
            }
        }

        // 6. Caveats
        var caveats: [AttributionCaveat] = []
        let activeUnmonitored = configuredVendors.filter { unmonitoredVendorIdentifiers.contains($0) }
        if !activeUnmonitored.isEmpty {
            caveats.append(.unmonitoredToolsConfigured)
        }
        if hasConcurrency {
            caveats.append(.concurrentSessionsDetected)
        }
        caveats.append(.unrecordedExternalActivityPossible)

        return AttributionSummary(
            windowStart: windowStart,
            windowEnd: windowEnd,
            startConsumptionFraction: startConsumptionFraction,
            endConsumptionFraction: endConsumptionFraction,
            consumedFractionDelta: consumedFractionDelta,
            totalObservedTokens: totalObservedTokens,
            projectAttributions: attributions,
            unmonitoredVendors: activeUnmonitored,
            hasConcurrentSessions: hasConcurrency,
            caveats: caveats
        )
    }
}
