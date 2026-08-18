import Foundation

// MARK: - Vendor identifiers

public enum VendorIdentifier: String, Sendable, CaseIterable, Codable {
    case claude
    case gemini
    case opencode
    case copilot
    case openrouter
    case githubRest   = "github_rest"
    case githubGraphql = "github_graphql"

    public var displayName: String {
        switch self {
        case .claude:        "Claude"
        case .gemini:        "Gemini"
        case .opencode:      "OpenCode"
        case .copilot:       "GitHub Copilot"
        case .openrouter:    "OpenRouter"
        case .githubRest:    "GitHub REST"
        case .githubGraphql: "GitHub GraphQL"
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

    public var headline: String {
        switch self {
        case .notConfigured:      "Not configured"
        case .credentialRejected: "Credential rejected"
        case .unsupported:        "No usage API"
        case .offline:            "Offline"
        case .timedOut:           "Timed out"
        case .badResponse:        "Unexpected response"
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
        }
    }
}

public enum ProviderStatus: Sendable, Equatable {
    /// We have a real reading. `urgency` describes the quota pressure.
    case measured(Urgency)
    /// We have no reading. This is informational, never an emergency.
    case unavailable(UnavailableReason)
    /// We have a real reading and the vendor is throttling us.
    case rateLimited(retryAfter: Date?)

    // Convenience constructors that keep call sites readable.
    public static var healthy: ProviderStatus { .measured(.none) }
    public static var warning: ProviderStatus { .measured(.warning) }
    public static var critical: ProviderStatus { .measured(.critical) }
    public static var unauthenticated: ProviderStatus { .unavailable(.notConfigured) }
    public static func unsupported(_ reason: String) -> ProviderStatus {
        .unavailable(.unsupported(reason))
    }

    /// Quota pressure only. An unreadable provider contributes `.none` — it is
    /// surfaced through `confidence`, not by masking a real emergency.
    public var urgency: Urgency {
        switch self {
        case .measured(let u):  u
        case .rateLimited:      .critical
        case .unavailable:      .none
        }
    }

    public var confidence: Confidence {
        switch self {
        case .measured, .rateLimited: .measured
        case .unavailable:            .unavailable
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

    public init(
        id: String,
        vendorId: VendorIdentifier,
        displayName: String,
        category: MetricCategory,
        metric: MetricType,
        status: ProviderStatus,
        resetsAt: Date?,
        lastUpdated: Date,
        auxiliaryInfo: String?
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
