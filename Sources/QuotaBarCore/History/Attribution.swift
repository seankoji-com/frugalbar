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
    /// Some records carried no total, so the shares are over the subset that did.
    case partialTokenBreakdowns = "partial_token_breakdowns"

    /// One line the UI can show verbatim. Kept next to the cases so a new caveat
    /// cannot be added without deciding how it reads.
    public var explanation: String {
        switch self {
        case .unmonitoredToolsConfigured:
            "Some configured tools have no local activity adapter, so their usage is not represented here."
        case .concurrentSessionsDetected:
            "Multiple CLI sessions ran simultaneously in this window; individual session share cannot be fully separated."
        case .unrecordedExternalActivityPossible:
            "Usage from other machines, the web UI, or tools not listed here is not observed and may account for some of the allowance."
        case .partialTokenBreakdowns:
            "Some sessions reported an incomplete token breakdown; shares cover only sessions reporting a total."
        }
    }
}

public struct AttributionSummary: Sendable, Equatable {
    public let windowStart: Date
    public let windowEnd: Date
    /// The bar these endpoints describe, so the UI never has to imply which one.
    public let barLabel: String?
    public let startConsumptionFraction: Double?
    public let endConsumptionFraction: Double?
    public let consumedFractionDelta: Double?
    public let totalObservedTokens: Int
    /// Records in the window that carried no token total, and so are absent from
    /// the shares above.
    public let recordsWithoutTokenTotals: Int
    public let projectAttributions: [ProjectAttribution]
    public let unmonitoredVendors: [VendorIdentifier]
    public let hasConcurrentSessions: Bool
    public let caveats: [AttributionCaveat]

    public init(
        windowStart: Date,
        windowEnd: Date,
        barLabel: String? = nil,
        startConsumptionFraction: Double?,
        endConsumptionFraction: Double?,
        consumedFractionDelta: Double?,
        totalObservedTokens: Int,
        recordsWithoutTokenTotals: Int = 0,
        projectAttributions: [ProjectAttribution],
        unmonitoredVendors: [VendorIdentifier],
        hasConcurrentSessions: Bool,
        caveats: [AttributionCaveat]
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.barLabel = barLabel
        self.startConsumptionFraction = startConsumptionFraction
        self.endConsumptionFraction = endConsumptionFraction
        self.consumedFractionDelta = consumedFractionDelta
        self.totalObservedTokens = totalObservedTokens
        self.recordsWithoutTokenTotals = recordsWithoutTokenTotals
        self.projectAttributions = projectAttributions
        self.unmonitoredVendors = unmonitoredVendors
        self.hasConcurrentSessions = hasConcurrentSessions
        self.caveats = caveats
    }
}

public enum AttributionEngine {

    /// Unmonitored vendors that do not produce local CLI telemetry logs.
    ///
    /// The UI copy is derived from this set, so this is the single place a
    /// vendor moves in or out of.
    public static let unmonitoredVendorIdentifiers: Set<VendorIdentifier> = [
        .grok,
        .kiro,
        .gemini
    ]

    /// Which local activity sources (if any) can speak for a vendor.
    ///
    /// An empty set means "we hold no local telemetry for this vendor", which is
    /// not the same as "this vendor used nothing" — the caller must say so
    /// rather than showing another tool's tokens against this vendor's name.
    public static func localSourceIdentifiers(for vendor: VendorIdentifier) -> Set<String> {
        switch vendor {
        case .claude:   ["claude_code"]
        case .openai:   ["codex"]
        case .opencode: ["opencode"]
        default:        []
        }
    }

    /// The bar label a window's consumption should be attributed to.
    ///
    /// Picks the label on the most recent reading that carries a fraction,
    /// preferring the longest window among equally recent readings, and returns
    /// `nil` when no reading has one. Callers must use this and then scope their
    /// readings to the returned label: `fetchReadings(vendor:)` interleaves
    /// every bar label, so taking a first/last endpoint across the uncon­strained
    /// list subtracts one window's fraction from another's.
    public static func preferredBarLabel(
        readings: [QuotaHistoryStore.ReadingRecord]
    ) -> String? {
        let measured = readings.filter { $0.fraction != nil }
        guard let latest = measured.map(\.measuredAt).max() else { return nil }

        return measured
            .filter { $0.measuredAt == latest }
            .max { lhs, rhs in
                (lhs.windowLength ?? -1) < (rhs.windowLength ?? -1)
            }?
            .barLabel
    }

    /// First and last measured fractions for one bar label, in time order.
    ///
    /// Both endpoints come from the same label by construction. A label with no
    /// measured reading yields `(nil, nil)` — never a zero, and never a value
    /// borrowed from a different window.
    public static func consumptionEndpoints(
        readings: [QuotaHistoryStore.ReadingRecord],
        barLabel: String
    ) -> (start: Double?, end: Double?) {
        let scoped = readings
            .filter { $0.barLabel == barLabel && $0.fraction != nil }
            .sorted { $0.measuredAt < $1.measuredAt }
        return (scoped.first?.fraction, scoped.last?.fraction)
    }

    /// Computes project token shares and uncertainty caveats for a given window.
    ///
    /// CRITICAL INVARIANT:
    /// Local CLI tokens are NOT converted into vendor quota percentages.
    /// Instead, project token shares are reported alongside the vendor's measured
    /// allowance delta, with explicit caveats for unmonitored and concurrent sources.
    public static func computeAttribution(
        windowStart: Date,
        windowEnd: Date,
        barLabel: String? = nil,
        startConsumptionFraction: Double?,
        endConsumptionFraction: Double?,
        activities: [ActivityRecord],
        configuredVendors: [VendorIdentifier] = []
    ) -> AttributionSummary {
        // 1. Filter activities within window
        let inWindow = activities.filter { record in
            record.observedAt >= windowStart && record.observedAt <= windowEnd
        }

        // 2. Group by project. Sessions are counted from every record, but only
        //    records carrying a real total contribute tokens to a share — a
        //    record with an unknown total must not be counted as zero.
        var projectTokensMap: [String: Int] = [:]
        var projectSessionsMap: [String: Set<String>] = [:]
        var recordsWithoutTokenTotals = 0

        for record in inWindow {
            let path = record.projectPath ?? "Unspecified Directory"
            projectSessionsMap[path, default: []].insert(record.sessionId)
            if let total = record.totalTokens {
                projectTokensMap[path, default: 0] += total
            } else {
                recordsWithoutTokenTotals += 1
            }
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

        // 4. Allowance delta. Both endpoints must come from the same bar, or the
        //    subtraction is between two different windows and means nothing.
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
        if recordsWithoutTokenTotals > 0 {
            caveats.append(.partialTokenBreakdowns)
        }
        caveats.append(.unrecordedExternalActivityPossible)

        return AttributionSummary(
            windowStart: windowStart,
            windowEnd: windowEnd,
            barLabel: barLabel,
            startConsumptionFraction: startConsumptionFraction,
            endConsumptionFraction: endConsumptionFraction,
            consumedFractionDelta: consumedFractionDelta,
            totalObservedTokens: totalObservedTokens,
            recordsWithoutTokenTotals: recordsWithoutTokenTotals,
            projectAttributions: attributions,
            unmonitoredVendors: activeUnmonitored,
            hasConcurrentSessions: hasConcurrency,
            caveats: caveats
        )
    }
}
