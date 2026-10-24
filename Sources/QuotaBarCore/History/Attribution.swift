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
    /// Some records describe local tool use but do not publish the billing
    /// account/workspace they billed. They are not attributed to a
    /// subscription's allowance on the strength of the tool identity alone.
    case unverifiedBillingIdentity = "unverified_billing_identity"

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
        case .unverifiedBillingIdentity:
            "Some local sessions do not record the billing account or workspace being reported on, so they are not attributed to this subscription."
        }
    }
}

/// How strictly a breakdown matches local tool activity to a billing subject.
public enum AttributionBillingScope: Sendable, Equatable {
    /// Include every record the tool wrote. Used where the subject is the tool
    /// itself, not one of its subscriptions.
    case any
    /// Include only records whose published account/workspace identity matches
    /// the subject being reported on. A tool identity (for example `opencode`)
    /// and a published provider id (for example `litellm`) still do not say
    /// which subscription allowance was consumed. An uncorrelated target
    /// (neither account nor workspace) matches nothing, so records stay
    /// explicitly unattributed rather than being assigned to a workspace that
    /// merely happens to share the tool.
    case matchingPublishedIdentity(AttributionBillingTarget)
}

/// The billing identity the caller is reporting on.
///
/// Each field is published by the source, never inferred. A target with only a
/// provider is not enough to identify a workspace: two workspaces can bill
/// through the same provider, so `isCorrelated` requires an account or
/// workspace.
public struct AttributionBillingTarget: Sendable, Equatable {
    public let billingProvider: String?
    public let accountId: String?
    public let workspaceId: String?

    public init(
        billingProvider: String? = nil,
        accountId: String? = nil,
        workspaceId: String? = nil
    ) {
        self.billingProvider = billingProvider
        self.accountId = accountId
        self.workspaceId = workspaceId
    }

    /// A target that names an account or workspace. Without one there is no
    /// correlation, and a record must not be assigned on provider identity
    /// alone.
    public var isCorrelated: Bool { accountId != nil || workspaceId != nil }

    /// True when every identity the target publishes is also published by the
    /// record, and the target names an account or workspace.
    public func matches(_ record: ActivityRecord) -> Bool {
        guard isCorrelated else { return false }
        if let billingProvider, record.billingProvider != billingProvider { return false }
        if let accountId, record.accountId != accountId { return false }
        if let workspaceId, record.workspaceId != workspaceId { return false }
        return true
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
    /// Records excluded from the shares because their published identity does
    /// not establish the billing account/workspace being reported on.
    public let recordsWithoutMatchingBillingIdentity: Int
    /// Billing providers the included records published, deduplicated. Empty
    /// means none was published; it does not mean "the default provider".
    public let publishedBillingProviders: [String]
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
        recordsWithoutMatchingBillingIdentity: Int = 0,
        publishedBillingProviders: [String] = [],
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
        self.recordsWithoutMatchingBillingIdentity = recordsWithoutMatchingBillingIdentity
        self.publishedBillingProviders = publishedBillingProviders
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
        .gemini,
        .antigravityClaude,
        .antigravityArgon,
        .clinepass,
        .muse
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
        configuredVendors: [VendorIdentifier] = [],
        billingScope: AttributionBillingScope = .any
    ) -> AttributionSummary {
        // 1. Filter activities within window
        let inWindow = activities.filter { record in
            record.observedAt >= windowStart && record.observedAt <= windowEnd
        }

        // 1b. A local tool identity does not establish a billing identity. When
        // the caller is reporting on a particular subscription, only records
        // whose published identity matches that subject are counted; the rest
        // are carried as an explicit exclusion instead of being silently
        // assigned to it.
        let scoped: [ActivityRecord]
        var recordsWithoutMatchingBillingIdentity = 0
        switch billingScope {
        case .any:
            scoped = inWindow
        case .matchingPublishedIdentity(let target):
            scoped = inWindow.filter { record in
                if target.matches(record) { return true }
                recordsWithoutMatchingBillingIdentity += 1
                return false
            }
        }

        // 2. Group by project. Sessions are counted from every record, but only
        //    records carrying a real total contribute tokens to a share — a
        //    record with an unknown total must not be counted as zero.
        var projectTokensMap: [String: Int] = [:]
        var projectSessionsMap: [String: Set<String>] = [:]
        var recordsWithoutTokenTotals = 0
        var billingProviders = Set<String>()

        for record in scoped {
            let path = record.projectPath ?? "Unspecified Directory"
            projectSessionsMap[path, default: []].insert(record.sessionId)
            if let provider = record.billingProvider, !provider.isEmpty {
                billingProviders.insert(provider)
            }
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
        if scoped.count > 1 {
            let sortedByTime = scoped.sorted { $0.observedAt < $1.observedAt }
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
        if recordsWithoutMatchingBillingIdentity > 0 {
            caveats.append(.unverifiedBillingIdentity)
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
            recordsWithoutMatchingBillingIdentity: recordsWithoutMatchingBillingIdentity,
            publishedBillingProviders: billingProviders.sorted(),
            projectAttributions: attributions,
            unmonitoredVendors: activeUnmonitored,
            hasConcurrentSessions: hasConcurrency,
            caveats: caveats
        )
    }
}
