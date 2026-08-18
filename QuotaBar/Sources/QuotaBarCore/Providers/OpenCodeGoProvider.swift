import Foundation

/// OpenCode Go quota provider.
/// OpenCode uses its own API token to present quota data.
/// Probes the OpenCode API for usage stats.
public final class OpenCodeGoProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .opencode
    public let displayName: String = "OpenCode Go"
    public let category: MetricCategory = .aiSubscriptions

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey ?? CredentialStore.apiKey(for: .opencode)
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
                auxiliaryInfo: "No OpenCode token found"
            )
        }

        // Call a well-known OpenCode endpoint for usage data
        let url = "https://api.opencode.ai/v1/usage"
        let (data, http) = try await QuotaHTTP.get(url: url, key: apiKey)

        struct OCUsage: Decodable, Sendable {
            let tier: String?
            let quota_used: Double?
            let quota_limit: Double?
            let period_start: String?
            let period_end: String?
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            return QuotaSnapshot(
                id: vendorId.rawValue,
                vendorId: vendorId,
                displayName: displayName,
                category: category,
                metric: .subscription(tierName: "Unknown", renewalDate: nil),
                status: .unauthenticated,
                resetsAt: nil,
                lastUpdated: Date(),
                auxiliaryInfo: "Token rejected"
            )
        }

        let usage = try? JSONDecoder().decode(OCUsage.self, from: data)

        let quotaUsed = usage?.quota_used ?? 0
        let quotaLimit = usage?.quota_limit ?? 500
        let fraction = quotaLimit > 0 ? quotaUsed / quotaLimit : 0.0

        let status: ProviderStatus = {
            if fraction > 0.90 { return .critical }
            if fraction > 0.70 { return .warning }
            return .healthy
        }()

        // Parse renewal date if available
        let renewalDate: Date? = {
            guard let end = usage?.period_end else { return nil }
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fmt.date(from: end) ?? ISO8601DateFormatter().date(from: end)
        }()

        let remaining = Int(quotaLimit - quotaUsed)

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .count(remaining: max(remaining, 0), limit: Int(quotaLimit), unitName: "units"),
            status: status,
            resetsAt: renewalDate,
            lastUpdated: Date(),
            auxiliaryInfo: usage?.tier.map { "Tier: \($0)" }
        )
    }
}
