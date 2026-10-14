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
        try await fetchPrimarySnapshot()
    }

    private func fetchPrimarySnapshot() async throws -> QuotaSnapshot {
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
                let usage_weekly: Double?
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

        // `usage_monthly` and `usage_daily` are deliberately not decoded at
        // all any more. They were the two spend-per-window columns this row
        // used to draw, and they are calendar-aligned to UTC with no reset
        // timestamp published for either: a "daily" figure silently rolled
        // over mid-morning for anyone well east of UTC and read as spend that
        // vanished. The row reports spend, not a spend window — see below.
        //
        // `usage_weekly` survives because it names the figure the uncapped
        // path reports: a key with no cap has spend and no headroom, and the
        // figure beside "spent" has to be one the vendor actually published.

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
                    // The balance *is* this row's figure, so it is the metric's
                    // balance and nothing else: `spent` is nil, which is what
                    // stops the row's chip from printing the account's
                    // lifetime usage under a "spent" label while the balance
                    // sits in the subtitle beside it. One figure, one label —
                    // the shape DeepSeek's balance-only row already has.
                    metric: .currency(balance: Decimal(balance), limit: nil,
                                      spent: nil, currencyCode: "USD"),
                    status: .measured(urgency), resetsAt: nil, lastUpdated: Date(),
                    auxiliaryInfo: "Account credit balance",
                    row1: nil, row2: nil,
                    badgeText: "\(MoneyText.format(Decimal(balance), code: "USD")) credit",
                    planName: nil, cliSource: "OPENROUTER_API_KEY / auth.json",
                    currencyBasis: .accountCredit
                )
            }
        }
        let tierNote = decoded.data.is_free_tier == true ? "Free tier" : nil

        // `usage` never resets, so presenting it as a weekly figure would be a
        // fabricated number by this project's own definition.
        let weeklySpentUsd = decoded.data.usage_weekly ?? spentUsd
        let spendBadge = decoded.data.usage_weekly.map { "\(MoneyText.format(Decimal($0), code: "USD")) this week" }
            ?? "\(MoneyText.format(Decimal(spentUsd), code: "USD")) lifetime"

        guard let capUsd = decoded.data.limit, capUsd > 0 else {
            return QuotaSnapshot(
                id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
                category: category,
                metric: .currency(balance: Decimal(spentUsd), limit: nil,
                                  spent: Decimal(weeklySpentUsd), currencyCode: "USD"),
                status: .measured(.none),
                resetsAt: nil, lastUpdated: Date(),
                auxiliaryInfo: tierNote ?? "Key lifetime spend: \(MoneyText.format(Decimal(spentUsd), code: "USD"))",
                row1: nil,
                row2: nil,
                badgeText: spendBadge,
                planName: nil,
                cliSource: "OPENROUTER_API_KEY / auth.json",
                currencyBasis: .lifetimeSpend
            )
        }

        let remainingUsd = decoded.data.limit_remaining ?? max(capUsd - spentUsd, 0)

        let consumed = min(max((capUsd - remainingUsd) / capUsd, 0), 1)
        let urgency: Urgency = consumed > 0.90 ? .critical
                             : consumed > 0.70 ? .warning
                             : .none

        let remainingFormatted = MoneyText.format(Decimal(remainingUsd), code: "USD")

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
            planName: nil,
            cliSource: "OPENROUTER_API_KEY / auth.json",
            currencyBasis: .keySpendCap
        )
    }


    private static func retryAfter(from http: HTTPURLResponse) -> Date? {
        QuotaHTTP.retryAfterDate(secondsHeader: http.value(forHTTPHeaderField: "Retry-After"))
    }
}
