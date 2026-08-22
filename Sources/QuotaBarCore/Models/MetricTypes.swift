import Foundation

// MARK: - Vendor identifiers

public enum VendorIdentifier: String, Sendable, CaseIterable, Codable {
    case claude
    case openai
    case gemini
    case opencode
    case copilot
    case openrouter
    case githubRest   = "github_rest"
    case githubGraphql = "github_graphql"

    public var displayName: String {
        switch self {
        case .claude:        "Claude"
        case .openai:        "OpenAI"
        case .gemini:        "Gemini"
        case .opencode:      "OpenCode"
        case .copilot:       "GitHub Copilot"
        case .openrouter:    "OpenRouter"
        case .githubRest:    "GitHub REST"
        case .githubGraphql: "GitHub GraphQL"
        }
    }

    public var accentColorHex: String {
        switch self {
        case .claude:        "#d97757"
        case .openai:        "#10a37f"
        case .gemini:        "#3b82f6"
        case .opencode:      "#d47b00"
        case .copilot:       "#6e7681"
        case .openrouter:    "#d47b00"
        case .githubRest:    "#ffb4ab"
        case .githubGraphql: "#ffb4ab"
        }
    }

    public var iconSymbol: String {
        switch self {
        case .claude:        "sparkles"
        case .openai:        "circle.hexagongrid.fill"
        case .gemini:        "sparkle"
        case .opencode:      "chevron.left.forwardslash.chevron.right"
        case .copilot:       "curlybraces"
        case .openrouter:    "arrow.triangle.branch"
        case .githubRest:    "network"
        case .githubGraphql: "point.3.connected.trianglepath.dotted"
        }
    }
}


// MARK: - Metric types

public enum MetricType: Sendable, Equatable {
    /// 0.0 … 1.0 used fraction, optional detail string
    case percentage(usedFraction: Double, displayDetails: String?)
    case count(remaining: Int, limit: Int, unitName: String)
    case currency(balance: Decimal, limit: Decimal?, spent: Decimal?, currencyCode: String)
    case subscription(tierName: String, renewalDate: Date?)
}

// MARK: - Provider health

/// How much pressure the user's quota is under. This is the axis that drives
/// the menu bar icon: it answers "how urgent is this for my work right now?"
public enum Urgency: Int, Sendable, Comparable, CaseIterable {
    case none     = 0
    case warning  = 1   // usage > 70%  or credit < 25%
    case critical = 2   // usage > 90%  or credit < 10%

    public static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How much we trust the reading. Orthogonal to `Urgency` — a provider we
/// cannot read is not an emergency, and must never outrank one.
public enum Confidence: Int, Sendable, Comparable, CaseIterable {
    case measured    = 0   // we parsed a real response
    case unavailable = 1   // no reading: unauthenticated, offline, unsupported

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why a provider could not be read. Kept as a closed set so the UI can offer
/// a specific remedy — and so raw error text (which can embed credentials)
/// never reaches a user-facing or persisted field.
public enum UnavailableReason: Sendable, Equatable {
    case notConfigured            // no credential present
    case credentialRejected       // vendor said 401/403
    case unsupported(String)      // vendor exposes no usage API at all
    case offline                  // transport failure
    case timedOut
    case badResponse              // non-2xx, or a body we could not parse
    /// Vendor throttled us. A 429 on a metadata endpoint says nothing about
    /// the user's quota, so this is an absence of a reading — not an emergency.
    case rateLimited(retryAfter: Date?)

    public var headline: String {
        switch self {
        case .notConfigured:      "Not configured"
        case .credentialRejected: "Credential rejected"
        case .unsupported:        "No usage API"
        case .offline:            "Offline"
        case .timedOut:           "Timed out"
        case .badResponse:        "Unexpected response"
        case .rateLimited:        "Rate limited"
        }
    }

    /// Short, actionable next step shown beneath the row.
    public var remedy: String {
        switch self {
        case .notConfigured:      "Add a key in Settings"
        case .credentialRejected: "Check the key in Settings"
        case .unsupported(let d): d
        case .offline:            "Check your connection"
        case .timedOut:           "Vendor slow — will retry"
        case .badResponse:        "Vendor returned unexpected data"
        case .rateLimited:        "Vendor throttling — will retry"
        }
    }
}

public enum ProviderStatus: Sendable, Equatable {
    /// We have a real reading. `urgency` describes the quota pressure.
    case measured(Urgency)
    /// We have no reading. This is informational, never an emergency.
    case unavailable(UnavailableReason)

    // Convenience constructors that keep call sites readable.
    public static var healthy: ProviderStatus { .measured(.none) }
    public static var warning: ProviderStatus { .measured(.warning) }
    public static var critical: ProviderStatus { .measured(.critical) }
    public static var unauthenticated: ProviderStatus { .unavailable(.notConfigured) }
    public static func unsupported(_ reason: String) -> ProviderStatus {
        .unavailable(.unsupported(reason))
    }
    public static func rateLimited(retryAfter: Date?) -> ProviderStatus {
        .unavailable(.rateLimited(retryAfter: retryAfter))
    }

    /// Quota pressure only. An unreadable provider contributes `.none` — it is
    /// surfaced through `confidence`, not by masking a real emergency.
    public var urgency: Urgency {
        switch self {
        case .measured(let u):  u
        case .unavailable:      .none
        }
    }

    public var confidence: Confidence {
        switch self {
        case .measured:    .measured
        case .unavailable: .unavailable
        }
    }

    public var unavailableReason: UnavailableReason? {
        if case .unavailable(let r) = self { return r }
        return nil
    }
}

// MARK: - Metric categories

public enum MetricCategory: String, Sendable, CaseIterable, Codable {
    case aiSubscriptions     = "AI Subscriptions"
    case apiSpendAndCredits  = "API Spend & Credits"
    case developerLimits     = "Developer Limits"
}


// MARK: - Dual-bar burndown metrics

public struct DualBarMetrics: Sendable, Equatable {
    public var primaryFraction: Double          // 0.0 to 1.0 (actual quota consumed)
    public var expectedPaceFraction: Double?     // Pro-rata expected fraction elapsed in window (0.0 to 1.0)
    public var secondaryFraction: Double?       // delta / surge burndown fraction
    public var label: String                    // e.g. "5H", "WK", "REST", "GraphQL"
    public var statusColor: String?
    public var usedText: String?
    public var resetText: String?

    public init(
        primaryFraction: Double,
        expectedPaceFraction: Double? = nil,
        secondaryFraction: Double? = nil,
        label: String,
        statusColor: String? = nil,
        usedText: String? = nil,
        resetText: String? = nil
    ) {
        self.primaryFraction = primaryFraction
        self.expectedPaceFraction = expectedPaceFraction
        self.secondaryFraction = secondaryFraction
        self.label = label
        self.statusColor = statusColor
        self.usedText = usedText
        self.resetText = resetText
    }

    /// Difference between actual consumption and pro-rata expected target.
    /// Positive = burning faster than pro-rata pace (over budget).
    /// Negative = burning slower than pro-rata pace (healthy buffer).
    public var burndownDelta: Double {
        let target = expectedPaceFraction ?? (label == "5H" ? 0.40 : (label == "WK" ? 0.45 : 0.50))
        return primaryFraction - target
    }

    public var isAboveProrataPace: Bool {
        burndownDelta > 0.04
    }
}


// MARK: - Quota snapshot (the core value type)

public struct QuotaSnapshot: Sendable, Identifiable, Equatable {
    public let id: String
    public let vendorId: VendorIdentifier
    public let displayName: String
    public let category: MetricCategory
    public let metric: MetricType
    public let status: ProviderStatus
    public let resetsAt: Date?
    public let lastUpdated: Date
    public let auxiliaryInfo: String?

    public var row1: DualBarMetrics?
    public var row2: DualBarMetrics?
    public var row3: DualBarMetrics?
    public var badgeText: String?
    public var planName: String?
    public var latencyMs: Int?
    public var keyMasked: String?
    public var cliSource: String?

    public var bars: [DualBarMetrics] {
        [row1, row2, row3].compactMap { $0 }
    }

    public init(
        id: String,
        vendorId: VendorIdentifier,
        displayName: String,
        category: MetricCategory,
        metric: MetricType,
        status: ProviderStatus,
        resetsAt: Date?,
        lastUpdated: Date,
        auxiliaryInfo: String?,
        row1: DualBarMetrics?,
        row2: DualBarMetrics?,
        badgeText: String? = nil,
        planName: String? = nil,
        latencyMs: Int? = nil,
        keyMasked: String? = nil,
        cliSource: String? = nil
    ) {
        self.id = id
        self.vendorId = vendorId
        self.displayName = displayName
        self.category = category
        self.metric = metric
        self.status = status
        self.resetsAt = resetsAt
        self.lastUpdated = lastUpdated
        self.auxiliaryInfo = auxiliaryInfo
        self.row1 = row1
        self.row2 = row2
        self.row3 = nil
        self.badgeText = badgeText
        self.planName = planName
        self.latencyMs = latencyMs
        self.keyMasked = keyMasked
        self.cliSource = cliSource
    }

    public init(
        id: String,
        vendorId: VendorIdentifier,
        displayName: String,
        category: MetricCategory,
        metric: MetricType,
        status: ProviderStatus,
        resetsAt: Date?,
        lastUpdated: Date,
        auxiliaryInfo: String?,
        row1: DualBarMetrics? = nil,
        row2: DualBarMetrics? = nil,
        row3: DualBarMetrics? = nil,
        badgeText: String? = nil,
        planName: String? = nil,
        latencyMs: Int? = nil,
        keyMasked: String? = nil,
        cliSource: String? = nil
    ) {
        self.id = id
        self.vendorId = vendorId
        self.displayName = displayName
        self.category = category
        self.metric = metric
        self.status = status
        self.resetsAt = resetsAt
        self.lastUpdated = lastUpdated
        self.auxiliaryInfo = auxiliaryInfo
        self.row1 = row1
        self.row2 = row2
        self.row3 = row3
        self.badgeText = badgeText
        self.planName = planName
        self.latencyMs = latencyMs
        self.keyMasked = keyMasked
        self.cliSource = cliSource
    }



    /// Short display name for compact row header (e.g. "Claude", "Gemini", "Copilot").
    public var shortVendorName: String {
        switch vendorId {
        case .claude:        return "Claude"
        case .openai:        return "OpenAI"
        case .gemini:        return "Gemini"
        case .opencode:      return "OpenCode"
        case .copilot:       return "Copilot"
        case .openrouter:    return "OpenRouter"
        case .githubRest, .githubGraphql: return "GitHub"
        }
    }

    /// Short plan name for compact row subtitle (e.g. "Max x20", "AI Pro", "Business", "Go").
    public var shortPlanName: String {
        if vendorId == .openrouter { return "" }
        if let plan = planName, !plan.isEmpty {
            if plan.contains("20x") || plan.contains("Max") { return "Max x20" }
            if plan.contains("Pro") || plan.contains("Premium") || plan.contains("Studio") { return "AI Pro" }
            if plan.contains("Business") || plan.contains("Individual") { return "Business" }
            if plan.contains("Go") { return "Go" }
            if plan.contains("Key") || plan.contains("Prepaid") { return "Key API" }
        }
        switch vendorId {
        case .claude:        return "Max x20"
        case .openai:        return "ChatGPT"
        case .gemini:        return "AI Studio"
        case .copilot:       return "Business"
        case .opencode:      return "Go"
        case .openrouter:    return ""
        case .githubRest, .githubGraphql: return "API Limits"
        }
    }


    /// 0.0 … 1.0 fraction *consumed* (0 = empty, 1 = full).
    ///
    /// `nil` means "there is no denominator" — a subscription, an unreadable
    /// provider, or a spend figure with no cap. Callers must render nil as an
    /// absence (no bar, no percentage), never as 0 or 100.
    public var consumptionFraction: Double? {
        // No reading means no fraction, whatever the placeholder metric says.
        guard status.confidence == .measured else { return nil }
        switch metric {
        case .percentage(let used, _):
            return min(max(used, 0.0), 1.0)
        case .count(let remaining, let limit, _):
            guard limit > 0 else { return nil }
            return 1.0 - min(max(Double(remaining) / Double(limit), 0.0), 1.0)
        case .currency(let balance, let limit, _, _):
            // An uncapped key has no denominator — spend is knowable, headroom is not.
            guard let limit, limit > 0 else { return nil }
            let ld = NSDecimalNumber(decimal: limit).doubleValue
            let bd = NSDecimalNumber(decimal: balance).doubleValue
            return 1.0 - min(max(bd / ld, 0.0), 1.0)
        case .subscription:
            return nil
        }
    }
}

