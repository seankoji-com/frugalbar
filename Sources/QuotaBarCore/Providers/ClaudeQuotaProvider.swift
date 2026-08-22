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
        // Anthropic publishes the unified quota only as response headers, so
        // the smallest possible real request is the only way to read it. That
        // costs one token of the very quota being reported — acceptable at the
        // default refresh interval, and the reason this provider must not be
        // polled aggressively.
        //
        // A Claude Code OAuth token is scoped to Claude Code: the endpoint
        // rejects it unless the request identifies itself as such, so the
        // system prompt below is load-bearing, not decoration.
        let body = try JSONSerialization.data(withJSONObject: [
            "model": Self.probeModel, "max_tokens": 1,
            "system": "You are Claude Code, Anthropic's official CLI for Claude.",
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

        // The binding constraint is whichever window is fuller. Badge and
        // urgency must come from the same number, or the menu bar goes red
        // while the row still reads "95% left".
        let worst = max(fiveHour.used, weekly.used)
        let urgency: Urgency = worst > 0.90 ? .critical : worst > 0.70 ? .warning : .none
        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: "Claude", renewalDate: nil),
            status: .measured(urgency), resetsAt: fiveHour.reset, lastUpdated: Date(),
            auxiliaryInfo: "Live Claude subscription quota", row1: row(fiveHour, label: "5H"),
            row2: row(weekly, label: "WK"), badgeText: "\(Int(((1 - worst) * 100).rounded()))% left",
            planName: "Claude", cliSource: "Claude OAuth rate-limit headers"
        )
    }

    /// The cheapest model that still returns the unified quota headers.
    /// Pinned rather than floating so a deprecation surfaces as an unavailable
    /// provider we can fix, not as a silently wrong reading.
    private static let probeModel = "claude-haiku-4-5-20251001"

    private struct Reading { let used: Double; let reset: Date }

    private func reading(_ response: HTTPURLResponse, prefix: String) -> Reading? {
        guard let raw = response.value(forHTTPHeaderField: "\(prefix)-utilization").flatMap(Double.init),
              let epoch = response.value(forHTTPHeaderField: "\(prefix)-reset").flatMap(Double.init), epoch > 0
        else { return nil }
        // The header has been seen both as a 0…1 fraction and as a percentage.
        // Accept either rather than discarding a real reading as malformed.
        let used = raw > 1 ? raw / 100 : raw
        guard (0...1).contains(used) else { return nil }
        return Reading(used: used, reset: Date(timeIntervalSince1970: epoch))
    }

    private func row(_ reading: Reading, label: String) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: reading.used, label: label, statusColor: "#d97757",
                       usedText: "\(Int((reading.used * 100).rounded()))% used",
                       resetText: "Resets \(RelativeDateTimeFormatter().localizedString(for: reading.reset, relativeTo: Date()))")
    }
}
