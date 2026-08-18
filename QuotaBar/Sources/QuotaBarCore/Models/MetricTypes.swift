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
        case .gemini:        "Gemini Advanced"
        case .opencode:      "OpenCode Go"
        case .copilot:       "GitHub Copilot"
        case .openrouter:    "OpenRouter"
        case .githubRest:    "GitHub REST API"
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

public enum ProviderStatus: Sendable, Equatable {
    case healthy
    case warning       // usage > 70%  or credit < 25%
    case critical      // usage > 90%  or credit < 10%
    case unauthenticated
    case rateLimited(retryAfter: Date?)
    case networkError(String)

    public var severity: Int {
        switch self {
        case .healthy:          0
        case .warning:          1
        case .critical:         2
        case .unauthenticated:  3
        case .rateLimited:      3
        case .networkError:     3
        }
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

    /// 0.0 … 1.0 fraction *consumed* (0 = empty, 1 = full)
    public var consumptionFraction: Double {
        switch metric {
        case .percentage(let used, _):
            min(max(used, 0.0), 1.0)
        case .count(let remaining, let limit):
            guard limit > 0 else { return 0.0 }
            1.0 - (Double(remaining) / Double(limit))
        case .currency(let balance, let limit, _):
            if let limit, limit > 0 {
                let ld = NSDecimalNumber(decimal: limit).doubleValue
                let bd = NSDecimalNumber(decimal: balance).doubleValue
                return 1.0 - min(max(bd / ld, 0.0), 1.0)
            }
            return 0.0
        case .subscription:
            return 0.0
        }
    }
}
