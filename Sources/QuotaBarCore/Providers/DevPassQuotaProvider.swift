import Foundation

/// DevPass (LLM Gateway) plan usage.
///
/// `GET https://api.llmgateway.io/v1/key` with the gateway API key. It reports
/// the plan tier, credits spent against the cycle allowance, and a separate
/// weekly premium-model window with its own reset.
///
/// One gap worth naming: the response gives no date for the *monthly* cycle,
/// only for the weekly premium window. FrugalBar will not invent one, so the
/// cycle bar appears only if the user records their renewal date under
/// Preferences → Cycles — and it is labelled `CYCLE` there to keep it distinct
/// from anything the vendor actually published.
public final class DevPassQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .devpass
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    static let usageURL = "https://api.llmgateway.io/v1/key"

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let key = await credential(injected: apiKey, for: .devpass) else {
            return unavailable(.notConfigured)
        }

        let (data, http) = try await QuotaHTTP.get(
            url: Self.usageURL,
            headers: ["Accept": "application/json"],
            auth: .bearer(key)
        )
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) { return unavailable(reason) }

        guard let response = try? JSONDecoder().decode(KeyResponse.self, from: data) else {
            return unavailable(.badResponse)
        }
        return Self.snapshot(from: response.data, provider: self, now: Date())
    }

    // MARK: - Snapshot construction

    static func snapshot(from key: KeyData, provider: DevPassQuotaProvider, now: Date) -> QuotaSnapshot {
        let planName = planDisplayName(key.devPlan)

        // "none" is a real answer, not a failure: the key works, it just has no
        // DevPass plan behind it. Report the lifetime spend instead of drawing
        // a plan gauge with no plan.
        guard let planName else {
            return lifetimeSnapshot(from: key, provider: provider, now: now)
        }

        let creditsUsed = key.devPlanCreditsUsed.flatMap(\.decimalValue)
        let creditsLimit = key.devPlanCreditsLimit.flatMap(\.decimalValue)
        let premiumUsed = key.devPlanPremiumCreditsUsed.flatMap(\.decimalValue)
        let premiumLimit = key.devPlanPremiumWeeklyLimit.flatMap(\.decimalValue)
        let premiumResetsAt = key.devPlanPremiumWeekResetsAt.flatMap(parseISO8601)

        let cycleFraction = fraction(used: creditsUsed, limit: creditsLimit)
        let premiumFraction = fraction(used: premiumUsed, limit: premiumLimit)

        guard let worst = [cycleFraction, premiumFraction].compactMap({ $0 }).max() else {
            return provider.unavailable(.unsupported("DevPass published no plan allowance"))
        }

        let urgency: Urgency = worst >= 0.95 ? .critical
            : worst >= 0.80 ? .warning
            : .none

        var snapshot = QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .percentage(usedFraction: worst, displayDetails: nil),
            status: .measured(urgency),
            // The vendor publishes no cycle date; the weekly premium reset is
            // the only real one, so it is the only one reported here.
            resetsAt: premiumResetsAt,
            lastUpdated: now,
            auxiliaryInfo: "DevPass plan credits",
            row1: nil,
            row2: nil,
            badgeText: badgeText(remaining: key.devPlanCreditsRemaining.flatMap(\.decimalValue), fraction: cycleFraction),
            planName: planName,
            cliSource: nil
        )

        // The plan-credit total is deliberately not drawn as a bar. LLM Gateway
        // publishes no cycle date to go with it, so the bar had no reset, no
        // pace marker, and no window — three empty columns next to a number
        // already carried by the badge and the detail view.
        _ = creditsLimit

        if let premiumFraction, let premiumUsed, let premiumLimit {
            snapshot.row1 = DualBarMetrics(
                primaryFraction: premiumFraction,
                expectedPaceFraction: DualBarMetrics.proRataPace(
                    resetsAt: premiumResetsAt, windowLength: QuotaWindow.week, now: now),
                label: "WK",
                usedText: "\(money(premiumUsed))/\(plain(premiumLimit)) premium credits used",
                resetText: premiumResetsAt.map {
                    "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))"
                },
                resetsAt: premiumResetsAt,
                windowLength: premiumResetsAt == nil ? nil : QuotaWindow.week
            )
        }

        return snapshot
    }

    /// A working key with no DevPass plan. Lifetime spend is real telemetry, so
    /// it is reported — but it is spend, not headroom, and only becomes a gauge
    /// when the key carries its own limit.
    private static func lifetimeSnapshot(
        from key: KeyData,
        provider: DevPassQuotaProvider,
        now: Date
    ) -> QuotaSnapshot {
        let usage = key.usage.flatMap(\.decimalValue) ?? 0
        let limit = key.limit.flatMap(\.decimalValue)

        guard let limit, limit > 0 else {
            return QuotaSnapshot(
                id: provider.vendorId.rawValue,
                vendorId: provider.vendorId,
                displayName: provider.displayName,
                category: provider.category,
                metric: .currency(balance: usage, limit: nil, spent: usage, currencyCode: "USD"),
                status: .unavailable(.unsupported("No DevPass plan on this key")),
                resetsAt: nil,
                lastUpdated: now,
                auxiliaryInfo: "DevPass key spend",
                row1: DualBarMetrics(
                    primaryFraction: nil,
                    label: "SP",
                    usedText: "\(money(usage)) spent (no key limit set)"
                ),
                badgeText: money(usage),
                planName: nil
            )
        }

        let spentFraction = min(max(NSDecimalNumber(decimal: usage).doubleValue
            / NSDecimalNumber(decimal: limit).doubleValue, 0), 1)
        return QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .currency(balance: limit - usage, limit: limit, spent: usage, currencyCode: "USD"),
            status: .measured(spentFraction >= 0.95 ? .critical : spentFraction >= 0.80 ? .warning : .none),
            resetsAt: nil,
            lastUpdated: now,
            auxiliaryInfo: "DevPass key spend cap",
            row1: DualBarMetrics(
                primaryFraction: spentFraction,
                label: "SP",
                usedText: "\(money(usage))/\(plain(limit)) key limit used"
            ),
            badgeText: money(limit - usage) + " left",
            planName: nil,
            currencyBasis: .keySpendCap
        )
    }

    // MARK: - Helpers

    static func fraction(used: Decimal?, limit: Decimal?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        let usedValue = NSDecimalNumber(decimal: used).doubleValue
        let limitValue = NSDecimalNumber(decimal: limit).doubleValue
        guard usedValue.isFinite, limitValue.isFinite, limitValue > 0 else { return nil }
        return min(max(usedValue / limitValue, 0), 1)
    }

    static func badgeText(remaining: Decimal?, fraction: Double?) -> String? {
        if let fraction, fraction >= 1.0 { return "Exhausted" }
        guard let remaining else { return nil }
        return "\(money(remaining)) left"
    }

    static func money(_ amount: Decimal) -> String {
        SubscriptionCycle.formatCost(amount, currencyCode: "USD")
    }

    /// The right-hand side of a `used/limit` pair. Both halves are the same
    /// currency, so naming it twice ("USD 0.00/USD 87.00") is noise in a row
    /// that has to stay narrow.
    static func plain(_ amount: Decimal) -> String {
        amount.formatted(.number.precision(.fractionLength(2)))
    }

    /// `devPlan` is `lite` | `pro` | `max` | `none`.
    static func planDisplayName(_ raw: String?) -> String? {
        let trimmed = raw?.trimmed.lowercased() ?? ""
        switch trimmed {
        case "", "none": return nil
        case "lite":     return "DevPass Lite"
        case "pro":      return "DevPass Pro"
        case "max":      return "DevPass Max"
        default:         return "DevPass \(trimmed.capitalized)"
        }
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    // MARK: - Response shape

    struct KeyResponse: Decodable, Sendable {
        let data: KeyData
    }

    /// Every monetary and credit field arrives as a decimal *string*. Decoding
    /// them through `Decimal` keeps cent-level values exact — binary floating
    /// point cannot represent them, and a percentage computed from a drifted
    /// value is wrong in the direction the user cares about.
    struct KeyData: Decodable, Sendable {
        let label: String?
        let usage: DecimalString?
        let limit: DecimalString?
        let devPlan: String?
        let devPlanCreditsUsed: DecimalString?
        let devPlanCreditsLimit: DecimalString?
        let devPlanCreditsRemaining: DecimalString?
        let devPlanPremiumWeeklyLimit: DecimalString?
        let devPlanPremiumCreditsUsed: DecimalString?
        let devPlanPremiumWeekResetsAt: String?
    }

    /// A decimal the gateway sends as a string. Also accepts a bare JSON number,
    /// so a future response that stops quoting them still decodes.
    struct DecimalString: Decodable, Sendable {
        let decimalValue: Decimal?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                decimalValue = nil
            } else if let text = try? container.decode(String.self) {
                decimalValue = Decimal(string: text.trimmed)
            } else if let number = try? container.decode(Double.self) {
                decimalValue = number.isFinite ? Decimal(number) : nil
            } else {
                decimalValue = nil
            }
        }
    }
}
