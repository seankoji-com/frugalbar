import Foundation

/// GitHub Copilot provider.
///
/// Follows CodexBar's Copilot telemetry implementation:
/// 1. Queries `https://api.github.com/copilot_internal/v2/token` to fetch live quota limits,
///    monthly allowance, token consumption, and reset deadlines.
/// 2. Queries `https://api.github.com/user` to verify login profile.
public final class GitHubCopilotProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .copilot
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    struct InternalTokenResponse: Decodable, Sendable {
        let token: String?
        let expires_at: Int?
        let sku: String?
        let chat_enabled: Bool?
        let monthly_quota: Int?
        let current_usage: Int?
        let quota_reset_date: String?
    }

    struct GHUser: Decodable, Sendable {
        let login: String
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let resolved = await credential(injected: token, for: .copilot) else {
            return unavailable(.notConfigured)
        }

        let (data, http) = try await QuotaHTTP.get(
            url: "https://api.github.com/user",
            headers: ["Accept": "application/vnd.github+json"],
            auth: .bearer(resolved)
        )

        if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
            return unavailable(reason)
        }

        guard let user = try? JSONDecoder().decode(GHUser.self, from: data) else {
            return unavailable(.badResponse)
        }

        let (copilotData, copilotHTTP) = try await QuotaHTTP.get(
            url: "https://api.github.com/copilot_internal/v2/token",
            headers: [
                "Accept": "application/json",
                "Editor-Version": "vscode/1.95.0",
                "Editor-Plugin-Version": "copilot/1.250.0",
                "User-Agent": "GithubCopilot/1.250.0"
            ],
            auth: .bearer(resolved)
        )
        if let reason = QuotaHTTP.failureReason(for: copilotHTTP.statusCode) { return unavailable(reason) }
        guard let copilotToken = try? JSONDecoder().decode(InternalTokenResponse.self, from: copilotData),
              let totalQuota = copilotToken.monthly_quota, totalQuota > 0,
              let currentUsage = copilotToken.current_usage, currentUsage >= 0,
              let resetDate = copilotToken.quota_reset_date.flatMap(Self.parseCopilotReset)
        else { return unavailable(.badResponse) }

        let fraction = totalQuota > 0 ? min(max(Double(currentUsage) / Double(totalQuota), 0.0), 1.0) : 1.0
        let isExhausted = fraction >= 1.0
        let status: ProviderStatus = isExhausted ? .critical : (fraction >= 0.80 ? .warning : .healthy)
        let resetString = "Resets \(RelativeDateTimeFormatter().localizedString(for: resetDate, relativeTo: Date()))"

        let row1 = DualBarMetrics(
            primaryFraction: fraction,
            expectedPaceFraction: 0.60,
            label: "MO",
            statusColor: isExhausted ? "#ffb4ab" : "#53e16f",
            usedText: "\(currentUsage.formatted()) / \(totalQuota.formatted()) AI credits (\(Int((fraction * 100).rounded()))%)",
            resetText: resetString
        )

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .subscription(tierName: "Active", renewalDate: nil),
            status: status,
            resetsAt: resetDate,
            lastUpdated: Date(),
            auxiliaryInfo: "Signed in as \(user.login) • \(currentUsage.formatted()) / \(totalQuota.formatted()) credits used (\(isExhausted ? "Usage paused" : "Active"))",
            row1: row1,
            row2: nil,
            badgeText: isExhausted ? "Exhausted" : "\(totalQuota - currentUsage) left",
            planName: "GitHub Copilot",
            latencyMs: 95,
            keyMasked: nil,
            cliSource: "gh auth token / hosts.json"
        )
    }

    private static func parseCopilotReset(_ isoDate: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: isoDate)
    }

    private static func formatCopilotReset(_ isoDate: String) -> String {
        guard let date = parseCopilotReset(isoDate) else { return "Reset time unavailable" }
        return "Resets \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))"
    }
}






