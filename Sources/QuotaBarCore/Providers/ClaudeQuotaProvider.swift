import Foundation

/// Claude subscription quota from the OAuth rate-limit headers returned by a
/// minimal Claude API request. Derived from claude-rate-monitor (MIT).
public final class ClaudeQuotaProvider: QuotaProvider, Sendable {
    public let vendorId: VendorIdentifier = .claude
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions
    private let apiKey: String?

    public init(apiKey: String? = nil) { self.apiKey = apiKey }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let token = await credential(injected: apiKey, for: .claude) else {
            return unavailable(.notConfigured)
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001", "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])
        let (_, response) = try await QuotaHTTP.post(
            url: "https://api.anthropic.com/v1/messages", body: body,
            headers: ["anthropic-version": "2023-06-01", "anthropic-beta": "oauth-2025-04-20"],
            auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(for: response.statusCode) { return unavailable(reason) }
        guard let fiveHour = reading(response, prefix: "anthropic-ratelimit-unified-5h"),
              let weekly = reading(response, prefix: "anthropic-ratelimit-unified-7d")
        else { return unavailable(.badResponse) }

        let urgency: Urgency = max(fiveHour.used, weekly.used) > 0.90 ? .critical
            : max(fiveHour.used, weekly.used) > 0.70 ? .warning : .none
        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: "Claude", renewalDate: nil),
            status: .measured(urgency), resetsAt: fiveHour.reset, lastUpdated: Date(),
            auxiliaryInfo: "Live Claude subscription quota", row1: row(fiveHour, label: "5H"),
            row2: row(weekly, label: "WK"), badgeText: "\(Int(((1 - weekly.used) * 100).rounded()))% left",
            planName: "Claude", cliSource: "Claude OAuth rate-limit headers"
        )
    }

    private struct Reading { let used: Double; let reset: Date }

    private func reading(_ response: HTTPURLResponse, prefix: String) -> Reading? {
        guard let value = response.value(forHTTPHeaderField: "\(prefix)-utilization"),
              let used = Double(value), (0...1).contains(used),
              let epoch = response.value(forHTTPHeaderField: "\(prefix)-reset").flatMap(Double.init), epoch > 0
        else { return nil }
        return Reading(used: used, reset: Date(timeIntervalSince1970: epoch))
    }

    private func row(_ reading: Reading, label: String) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: reading.used, label: label, statusColor: "#d97757",
                       usedText: "\(Int((reading.used * 100).rounded()))% used",
                       resetText: "Resets \(RelativeDateTimeFormatter().localizedString(for: reading.reset, relativeTo: Date()))")
    }
}
