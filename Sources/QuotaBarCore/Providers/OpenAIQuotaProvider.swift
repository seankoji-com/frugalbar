import Foundation

/// ChatGPT subscription usage from the authenticated Codex session.
///
/// The endpoint reports the subscription's real rolling windows. It does not
/// expose an API-spend balance, so this provider never invents one.
public final class OpenAIQuotaProvider: QuotaProvider, Sendable {
    public let vendorId: VendorIdentifier = .openai
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let accessToken: String?
    private let accountID: String?

    public init(accessToken: String? = nil, accountID: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let token = await credential(injected: accessToken, for: .openai) else {
            return unavailable(.notConfigured)
        }
        let discoveredAccountID = await CredentialStore.openAIAccountIDAsync()
        let accountID = self.accountID ?? discoveredAccountID
        var headers: [String: String] = [:]
        if let accountID { headers["chatgpt-account-id"] = accountID }

        let (data, http) = try await QuotaHTTP.get(
            url: "https://chatgpt.com/backend-api/wham/usage",
            headers: headers,
            auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
            return unavailable(reason)
        }

        struct Response: Decodable {
            struct RateLimit: Decodable {
                struct Window: Decodable {
                    let used_percent: Double?
                    let reset_at: TimeInterval?
                }
                let primary_window: Window?
            }
            let plan_type: String?
            let rate_limit: RateLimit?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let window = response.rate_limit?.primary_window,
              let usedPercent = window.used_percent,
              (0...100).contains(usedPercent)
        else { return unavailable(.badResponse) }

        let fraction = usedPercent / 100
        let reset = window.reset_at.map { Date(timeIntervalSince1970: $0) }
        let urgency: Urgency = fraction > 0.90 ? .critical : fraction > 0.70 ? .warning : .none
        let plan = response.plan_type?.capitalized ?? "ChatGPT"
        let pct = Int(usedPercent.rounded())

        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: plan, renewalDate: nil),
            status: .measured(urgency), resetsAt: reset, lastUpdated: Date(),
            auxiliaryInfo: "ChatGPT rolling usage window",
            row1: DualBarMetrics(primaryFraction: fraction, label: "PLAN", usedText: "\(pct)% used", resetText: reset.map(Self.resetText)),
            row2: nil, badgeText: "\(100 - pct)% left", planName: plan,
            cliSource: "Codex ChatGPT login"
        )
    }

    private static func resetText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Resets \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}
