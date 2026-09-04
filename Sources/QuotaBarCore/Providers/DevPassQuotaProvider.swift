import Foundation

/// DevPass (LLM Gateway) plan usage.
///
/// `GET https://api.llmgateway.io/v1/key` with the gateway API key. It reports
/// the plan tier and credits spent against the *monthly* plan allowance — a
/// fixed per-month budget (the gateway's own dashboard calls it "spend this
/// cycle"). DevPass is a monthly product, so that allowance is the only figure
/// FrugalBar tracks for it.
///
/// The gateway also publishes a separate *weekly* premium-model window, but it
/// is deliberately ignored here. It is a pay-as-you-go add-on, turns on only
/// once you opt in, and is reset by redeeming separate passes — none of it is
/// the subscription's monthly budget. Tracking it made a monthly product look
/// like two windows with two clocks.
///
/// One gap worth naming: the response gives no date for the monthly cycle
/// turning over, only for the weekly premium window — and since that window is
/// no longer tracked, no reset date is published at all. The monthly cycle is
/// therefore pinned to the subscriber's real renewal (a known, hand-entered
/// date, not a synthetic one) so the bar gets a pace marker and a countdown.
public final class DevPassQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .devpass
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let apiKey: String?
    /// The monthly plan cycle's renewal. Defaults to the pinned known renewal
    /// (Oct 1, 2026 09:10 GMT+10); injectable so a differently-subscribed key,
    /// or this one once the date has passed, can supply its own without
    /// editing source. `nil` only if the pinned date fails to build.
    private let monthlyRenewal: Date?

    public init(apiKey: String? = nil, monthlyRenewal: Date? = nil) {
        self.apiKey = apiKey
        self.monthlyRenewal = monthlyRenewal ?? Self.pinnedMonthlyRenewal
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

        // The monthly plan allowance is the whole story for a monthly product.
        // It carries the gauge, the badge, and the pressure reading; the
        // weekly premium window is a separate pay-as-you-go feature and is not
        // tracked.
        guard let creditsUsed = key.devPlanCreditsUsed.flatMap(\.decimalValue),
              let creditsLimit = key.devPlanCreditsLimit.flatMap(\.decimalValue),
              let planFraction = fraction(used: creditsUsed, limit: creditsLimit)
        else {
            return provider.unavailable(.unsupported("DevPass published no plan allowance"))
        }

        let urgency: Urgency = planFraction >= 0.95 ? .critical
            : planFraction >= 0.80 ? .warning
            : .none

        // The allowance is drawn as the headline gauge, the badge, and a monthly
        // burndown bar (row1). LLM Gateway publishes no turnover date for the
        // monthly cycle, so the bar uses the subscriber's pinned renewal below —
        // rolled forward to the next monthly occurrence so it never goes stale —
        // to place its pace marker and countdown.
        let renewal = provider.nextMonthlyRenewal(after: now)
        let windowLength = renewal.flatMap(DualBarMetrics.monthWindowLength(endingAt:))
        // Preserve nil: an unknown/absent window yields no pace, exactly like
        // the other providers, rather than leaning on a `?? 0` fallback.
        let pace = windowLength.flatMap {
            DualBarMetrics.proRataPace(resetsAt: renewal, windowLength: $0, now: now)
        }

        return QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .percentage(usedFraction: planFraction, displayDetails: nil),
            status: .measured(urgency),
            resetsAt: renewal,
            lastUpdated: now,
            auxiliaryInfo: "DevPass monthly plan credits",
            row1: DualBarMetrics(
                primaryFraction: planFraction,
                expectedPaceFraction: pace,
                label: "MO",
                usedText: "\(money(creditsUsed))/\(plain(creditsLimit)) credits used",
                resetText: renewal.map(Self.renewalText(for:)),
                resetsAt: renewal,
                windowLength: windowLength
            ),
            row2: nil,
            badgeText: badgeText(remaining: key.devPlanCreditsRemaining.flatMap(\.decimalValue), fraction: planFraction),
            planName: planName,
            cliSource: nil
        )
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

    /// The date the monthly plan cycle turns over.
    ///
    /// DevPass publishes no turnover date for the monthly allowance (only the
    /// ignored weekly premium reset), so the default is pinned to this
    /// subscriber's actual renewal — Oct 1, 2026 09:10 GMT+10 — rather than
    /// synthesized. A fixed, known date in the owner's own timezone, kept as
    /// real calendar components so the pace marker measures a true window
    /// length instead of a guessed constant.
    static var pinnedMonthlyRenewal: Date? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 10 * 3600) // GMT+10
        components.year = 2026
        components.month = 10
        components.day = 1
        components.hour = 9
        components.minute = 10
        return components.calendar?.date(from: components)
    }

    /// The next monthly renewal on or after `now`, preserving the anchor's
    /// day-of-month and time. A pinned or injected date is a recurring point
    /// (e.g. the 1st at 09:10), so once the moment passes the cycle rolls to
    /// the following month instead of going stale — the countdown and pace
    /// marker stay meaningful forever, not just until the first occurrence.
    func nextMonthlyRenewal(after now: Date, calendar: Calendar = .current) -> Date? {
        guard let anchor = monthlyRenewal else { return nil }
        var candidate = anchor
        while candidate < now, let next = calendar.date(byAdding: .month, value: 1, to: candidate) {
            candidate = next
        }
        return candidate
    }

    /// Render a renewal date as the "Renews …" line in GMT+10.
    private static func renewalText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 10 * 3600)
        formatter.dateFormat = "MMM d, yyyy HH:mm 'GMT+10'"
        return "Renews \(formatter.string(from: date))"
    }

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
