import Foundation

/// OpenRouter credit provider — `GET /api/v1/auth/key`.
///
/// Contract notes, because a previous revision misread all three:
///  - `limit` is the **spend cap on this key**, not the account balance, and
///    it is `null` when the key is uncapped (the default).
///  - `limit_remaining` is headroom under that cap, also `null` when uncapped.
///  - `usage` is credits consumed **since the key was created** (all time). It
///    never resets, so it is not a billing-period figure.
///
/// The account's real credit balance is only available from
/// `GET /api/v1/credits`, which requires a provisioning key we do not hold.
///
/// Therefore: with a cap we can draw a real gauge; without one we report spend
/// and draw no gauge, because there is no denominator. We never invent a cap.
public final class OpenRouterProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .openrouter
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .apiSpendAndCredits

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let key = await credential(injected: apiKey, for: .openrouter) else {
            return unavailable(.notConfigured)
        }

        let (data, http) = try await QuotaHTTP.get(
            url: "https://openrouter.ai/api/v1/auth/key",
            auth: .bearer(key)
        )

        if http.statusCode == 429 {
            // A 429 on this metadata endpoint tells us nothing about the
            // user's credit balance, so it is an absent reading rather than a
            // critical quota.
            return unavailable(.rateLimited(retryAfter: Self.retryAfter(from: http)))
        }
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
            return unavailable(reason)
        }

        struct Response: Decodable, Sendable {
            struct Payload: Decodable, Sendable {
                let usage: Double?
                let usage_daily: Double?
                let usage_weekly: Double?
                let usage_monthly: Double?
                let limit: Double?
                let limit_remaining: Double?
                let is_free_tier: Bool?
                let is_management_key: Bool?
                let creator_user_id: String?
            }
            let data: Payload
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return unavailable(.badResponse)
        }

        guard let spentUsd = decoded.data.usage else {
            return unavailable(.badResponse)
        }

        // Credits are authoritative when the supplied key can read them. If
        // this endpoint rejects a normal key, fall back to that key's cap.
        //
        // Best-effort on purpose: we already hold a good reading from
        // /auth/key, and losing it because an *enrichment* call timed out
        // would turn a working gauge into an error.
        let creditsResult = try? await QuotaHTTP.get(
            url: "https://openrouter.ai/api/v1/credits",
            auth: .bearer(key)
        )
        if let (creditsData, creditsHTTP) = creditsResult,
           (200...299).contains(creditsHTTP.statusCode) {
            struct CreditsResponse: Decodable {
                struct Payload: Decodable {
                    let total_credits: Double?
                    let total_usage: Double?
                }
                let data: Payload
            }
            if let credits = try? JSONDecoder().decode(CreditsResponse.self, from: creditsData),
               let purchased = credits.data.total_credits,
               let used = credits.data.total_usage,
               purchased >= 0, used >= 0 {
                let balance = max(purchased - used, 0)
                // Credit has no denominator to draw a gauge from, but a nearly
                // empty account is exactly what this app exists to warn about.
                // Thresholds are on the absolute balance, in dollars.
                let urgency: Urgency = balance < 1 ? .critical : balance < 5 ? .warning : .none
                return QuotaSnapshot(
                    id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
                    category: category,
                    metric: .currency(balance: Decimal(balance), limit: nil,
                                      spent: Decimal(used), currencyCode: "USD"),
                    status: .measured(urgency), resetsAt: nil, lastUpdated: Date(),
                    auxiliaryInfo: "Account credit balance",
                    row1: nil, row2: nil,
                    badgeText: "\(String(format: "$%.2f", balance)) credit",
                    planName: "OpenRouter", cliSource: "OPENROUTER_API_KEY / auth.json",
                    currencyBasis: .accountCredit
                )
            }
        }
        let tierNote = decoded.data.is_free_tier == true ? "Free tier" : nil

        // `usage` never resets, so presenting it as a weekly figure would be a
        // fabricated number by this project's own definition.
        let weeklySpentUsd = decoded.data.usage_weekly ?? spentUsd
        let spendBadge = decoded.data.usage_weekly.map { String(format: "$%.2f this week", $0) }
            ?? String(format: "$%.2f lifetime", spentUsd)

        guard let capUsd = decoded.data.limit, capUsd > 0 else {
            return QuotaSnapshot(
                id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
                category: category,
                metric: .currency(balance: Decimal(spentUsd), limit: nil,
                                  spent: Decimal(weeklySpentUsd), currencyCode: "USD"),
                status: .measured(.none),
                resetsAt: nil, lastUpdated: Date(),
                auxiliaryInfo: tierNote ?? "Key lifetime spend: \(String(format: "$%.2f", spentUsd))",
                row1: nil,
                row2: nil,
                badgeText: spendBadge,
                planName: "OpenRouter",
                cliSource: "OPENROUTER_API_KEY / auth.json",
                currencyBasis: .lifetimeSpend
            )
        }

        let remainingUsd = decoded.data.limit_remaining ?? max(capUsd - spentUsd, 0)

        let consumed = min(max((capUsd - remainingUsd) / capUsd, 0), 1)
        let urgency: Urgency = consumed > 0.90 ? .critical
                             : consumed > 0.70 ? .warning
                             : .none

        let remainingFormatted = String(format: "$%.2f", remainingUsd)

        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category,
            metric: .currency(balance: Decimal(remainingUsd), limit: Decimal(capUsd),
                              spent: Decimal(weeklySpentUsd), currencyCode: "USD"),
            status: .measured(urgency),
            resetsAt: nil, lastUpdated: Date(),
            auxiliaryInfo: tierNote ?? "Key spend cap, not account credit",
            row1: nil,
            row2: nil,
            badgeText: "\(remainingFormatted) key cap left",
            planName: "OpenRouter",
            cliSource: "OPENROUTER_API_KEY / auth.json",
            currencyBasis: .keySpendCap
        )
    }







    private static func retryAfter(from http: HTTPURLResponse) -> Date? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}
