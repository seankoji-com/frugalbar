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
            return QuotaSnapshot(
                id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
                category: category,
                metric: .subscription(tierName: "Rate limited", renewalDate: nil),
                status: .rateLimited(retryAfter: Self.retryAfter(from: http)),
                resetsAt: Self.retryAfter(from: http), lastUpdated: Date(), auxiliaryInfo: nil
            )
        }
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
            return unavailable(reason)
        }

        struct Response: Decodable, Sendable {
            struct Payload: Decodable, Sendable {
                let usage: Double?
                let limit: Double?
                let limit_remaining: Double?
                let is_free_tier: Bool?
            }
            let data: Payload
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return unavailable(.badResponse)
        }

        guard let spent = decoded.data.usage else {
            // `usage` is documented and always present; its absence means we
            // did not understand the payload, not that nothing was spent.
            return unavailable(.badResponse)
        }
        let tierNote = decoded.data.is_free_tier == true ? "Free tier" : nil

        // Uncapped key: spend is knowable, headroom is not. No denominator,
        // so `.currency` carries a nil limit and the UI draws no bar.
        guard let cap = decoded.data.limit, cap > 0 else {
            return QuotaSnapshot(
                id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
                category: category,
                metric: .currency(balance: Decimal(spent), limit: nil,
                                  spent: Decimal(spent), currencyCode: "USD"),
                status: .measured(.none),
                resetsAt: nil, lastUpdated: Date(),
                auxiliaryInfo: tierNote ?? "Spent all-time · key has no cap"
            )
        }

        // Capped key: a real gauge.
        let remaining = decoded.data.limit_remaining ?? max(cap - spent, 0)
        let consumed = cap > 0 ? min(max((cap - remaining) / cap, 0), 1) : 0
        let urgency: Urgency = consumed > 0.90 ? .critical
                             : consumed > 0.70 ? .warning
                             : .none

        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category,
            metric: .currency(balance: Decimal(remaining), limit: Decimal(cap),
                              spent: Decimal(spent), currencyCode: "USD"),
            status: .measured(urgency),
            resetsAt: nil, lastUpdated: Date(),
            auxiliaryInfo: tierNote ?? "Key spend cap"
        )
    }

    private static func retryAfter(from http: HTTPURLResponse) -> Date? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}
