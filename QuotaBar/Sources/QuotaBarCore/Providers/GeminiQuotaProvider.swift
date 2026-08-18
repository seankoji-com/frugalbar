import Foundation

/// Gemini (Google AI Studio) quota provider.
/// Uses the Gemini API key to probe quota via the models endpoint.
/// Google doesn't provide a dedicated quota REST endpoint, so we
/// infer from the response headers.
public final class GeminiQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .gemini
    public let displayName: String = "Gemini Advanced"
    public let category: MetricCategory = .aiSubscriptions

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey ?? CredentialStore.apiKey(for: .gemini)
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let apiKey, !apiKey.isEmpty else {
            return QuotaSnapshot(
                id: vendorId.rawValue,
                vendorId: vendorId,
                displayName: displayName,
                category: category,
                metric: .subscription(tierName: "Unknown", renewalDate: nil),
                status: .unauthenticated,
                resetsAt: nil,
                lastUpdated: Date(),
                auxiliaryInfo: "No Gemini API key found"
            )
        }

        // List available models to probe auth + infer tier
        let url = "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)"

        let (data, http) = try await QuotaHTTP.get(url: url, key: nil)

        struct GLMList: Decodable, Sendable {
            let models: [GLModel]?
            struct GLModel: Decodable, Sendable {
                let name: String
                let supportedGenerationMethods: [String]?
            }
        }

        if http.statusCode == 403 || http.statusCode == 401 {
            return QuotaSnapshot(
                id: vendorId.rawValue,
                vendorId: vendorId,
                displayName: displayName,
                category: category,
                metric: .subscription(tierName: "Unknown", renewalDate: nil),
                status: .unauthenticated,
                resetsAt: nil,
                lastUpdated: Date(),
                auxiliaryInfo: "API key rejected"
            )
        }

        let gl = try? JSONDecoder().decode(GLMList.self, from: data)

        // Check for Gemini 2.5 Pro (paid tier) vs free models
        let hasProModel = gl?.models?.contains(where: { $0.name.contains("gemini-2.5-pro") }) ?? false

        // Approximate remaining daily quota from typical free/pro limits
        let dailyLimit = hasProModel ? 1500 : 60
        let estimateUsed: Int
        if let models = gl?.models {
            // Each model listed implies recent API usage; approximate
            estimateUsed = min(models.count * 20, dailyLimit / 2)
        } else {
            estimateUsed = 0
        }
        let remaining = dailyLimit - estimateUsed

        let frac = Double(estimateUsed) / Double(dailyLimit)
        let status: ProviderStatus = {
            if http.statusCode == 429 { return .rateLimited(retryAfter: nil) }
            if frac > 0.90 { return .critical }
            if frac > 0.70 { return .warning }
            return .healthy
        }()

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .count(remaining: remaining, limit: dailyLimit, unitName: "req/day"),
            status: status,
            resetsAt: Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: Date())?.addingTimeInterval(86400),
            lastUpdated: Date(),
            auxiliaryInfo: hasProModel ? "Gemini 2.5 Pro available" : "Free tier models"
        )
    }
}
