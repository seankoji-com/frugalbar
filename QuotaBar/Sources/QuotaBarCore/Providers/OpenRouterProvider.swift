import Foundation

// MARK: - OpenRouter provider

/// GET https://openrouter.ai/api/v1/auth/key
/// Returns credit balance, limit, and spend info.
public final class OpenRouterProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .openrouter
    public let displayName: String = "OpenRouter Credits"
    public let category: MetricCategory = .apiSpendAndCredits

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey ?? CredentialStore.apiKey(for: .openrouter)
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        let url = "https://openrouter.ai/api/v1/auth/key"
        let (data, http) = try await QuotaHTTP.get(url: url, key: apiKey)
        struct Response: Decodable, Sendable {
            struct Data: Decodable, Sendable {
                let usage: Double?
                let limit: Double?
                let is_free_tier: Bool?
            }
            let data: Data
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)

        let usage = decoded.data.usage ?? 0
        let limit = decoded.data.limit ?? 20.0
        let balance = limit - usage
        let limitDecimal = Decimal(limit)
        let spentDecimal = Decimal(usage)
        let balanceDecimal = Decimal(balance)

        let remainingFrac = limit > 0 ? usage / limit : 0.0
        let status: ProviderStatus = {
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthenticated }
            let frac = remainingFrac
            if frac > 0.90 { return .critical }
            if frac > 0.70 { return .warning }
            return .healthy
        }()

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .currency(balance: balanceDecimal, limit: limitDecimal, spent: spentDecimal, currencyCode: "USD"),
            status: status,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: decoded.data.is_free_tier == true ? "Free tier" : nil
        )
    }
}
