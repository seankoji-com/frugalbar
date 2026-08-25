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

    private struct Response: Decodable {
        struct RateLimit: Decodable {
            struct Window: Decodable {
                let used_percent: Double?
                let reset_at: TimeInterval?
                let limit_window_seconds: Double?
            }
            let primary_window: Window?
            let secondary_window: Window?
        }
        let plan_type: String?
        let rate_limit: RateLimit?
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

        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return unavailable(.badResponse)
        }
        // Both windows are real subscription limits: `primary_window` is the
        // 5-hour session window and `secondary_window` the weekly one. Showing
        // only the first — under a label that named neither — is how a weekly
        // quota came to be drawn as "PLAN" with the 5-hour window missing.
        let windows = [response.rate_limit?.primary_window, response.rate_limit?.secondary_window]
            .compactMap { $0 }
            .compactMap(Self.reading)
        guard let worst = windows.map(\.used).max() else { return unavailable(.badResponse) }

        // Badge and urgency both come from the fullest window, so the menu bar
        // and the row can never disagree about which limit is binding.
        let urgency: Urgency = worst > 0.90 ? .critical : worst > 0.70 ? .warning : .none
        // An unread plan is nil, not the vendor's name wearing a tier's
        // clothes. `shortPlanName` renders nil as nothing at all.
        let plan = response.plan_type?.capitalized

        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: plan ?? displayName, renewalDate: nil),
            status: .measured(urgency), resetsAt: windows.first?.reset, lastUpdated: Date(),
            auxiliaryInfo: "Live ChatGPT subscription quota",
            row1: windows[safe: 0].map(Self.row), row2: windows[safe: 1].map(Self.row),
            badgeText: "\(Int(((1 - worst) * 100).rounded()))% left", planName: plan,
            cliSource: "Codex ChatGPT login"
        )
    }

    private struct Reading {
        let used: Double
        let reset: Date?
        let label: String
        /// Pro-rata share of the window elapsed, or nil when OpenAI published
        /// no window length to measure it against.
        let pace: Double?
        let windowSeconds: Double?
    }

    private static func reading(_ window: Response.RateLimit.Window) -> Reading? {
        guard let percent = window.used_percent, (0...100).contains(percent) else { return nil }
        let reset = window.reset_at.map { Date(timeIntervalSince1970: $0) }
        return Reading(
            used: percent / 100,
            reset: reset,
            label: label(forWindowSeconds: window.limit_window_seconds),
            pace: window.limit_window_seconds.flatMap {
                DualBarMetrics.proRataPace(resetsAt: reset, windowLength: $0)
            },
            windowSeconds: window.limit_window_seconds
        )
    }

    /// Names a window from the length the vendor reports rather than from its
    /// position in the payload. A hardcoded label cannot survive OpenAI adding,
    /// reordering, or resizing a window — and a mislabelled window is a wrong
    /// number in the only place that explains what the bar means.
    static func label(forWindowSeconds seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "PLAN" }
        let hours = seconds / 3600
        if hours < 1 { return "\(Int((seconds / 60).rounded()))M" }
        if hours < 24 { return "\(Int(hours.rounded()))H" }
        let days = hours / 24
        if days < 7 { return "\(Int(days.rounded()))D" }
        if days < 28 { return "WK" }
        return "MO"
    }

    private static func row(_ reading: Reading) -> DualBarMetrics {
        DualBarMetrics(
            primaryFraction: reading.used, expectedPaceFraction: reading.pace,
            label: reading.label, statusColor: "#10a37f",
            usedText: "\(Int((reading.used * 100).rounded()))% used",
            resetText: reading.reset.map(resetText),
            resetsAt: reading.reset, windowLength: reading.windowSeconds
        )
    }

    private static func resetText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Resets \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
