import Foundation

/// GitHub Copilot provider.
///
/// Reads the Copilot entitlement the editors read: `copilot_internal/user`
/// returns the plan, the premium-interaction and chat quota snapshots, and the
/// monthly reset date.
///
/// It is authenticated with the **GitHub OAuth token**, presented as
/// `Authorization: token …`. The previous implementation sent the short-lived
/// Copilot API token that OpenCode caches alongside it and called
/// `copilot_internal/v2/token` — the endpoint that *mints* that token. Both
/// halves of that were wrong, and the pair rendered as a permanent
/// "Credential rejected".
public final class GitHubCopilotProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .copilot
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    /// One metered Copilot allowance. GitHub publishes headroom, not usage.
    struct QuotaSnapshotResponse: Decodable, Sendable {
        let entitlement: Double?
        let remaining: Double?
        let percent_remaining: Double?
        let unlimited: Bool?

        /// A seat with no metered allowance reports zeroes on every field. That
        /// is "this plan publishes no quota", not "0% used" — drawing it as an
        /// empty bar would claim headroom nobody measured.
        var isPlaceholder: Bool {
            (entitlement ?? 0) == 0 && (remaining ?? 0) == 0
        }

        /// 0…1 consumed, or nil when GitHub published no denominator.
        var usedFraction: Double? {
            if unlimited == true || isPlaceholder { return nil }
            if let percent = percent_remaining, (0...100).contains(percent) {
                return 1 - percent / 100
            }
            guard let entitlement, entitlement > 0, let remaining, remaining >= 0 else { return nil }
            return min(max(1 - remaining / entitlement, 0), 1)
        }
    }

    struct UserResponse: Decodable, Sendable {
        struct Snapshots: Decodable, Sendable {
            let premium_interactions: QuotaSnapshotResponse?
            let chat: QuotaSnapshotResponse?
        }
        let quota_snapshots: Snapshots?
        let copilot_plan: String?
        let quota_reset_date: String?
    }

    /// Header set the Copilot editors send. `copilot_internal/user` rejects a
    /// request that does not identify itself as an editor, so these are
    /// load-bearing rather than decorative.
    private static let editorHeaders = [
        "Accept": "application/json",
        "Editor-Version": "vscode/1.96.2",
        "Editor-Plugin-Version": "copilot-chat/0.26.7",
        "User-Agent": "GitHubCopilotChat/0.26.7",
        "X-Github-Api-Version": "2025-04-01",
    ]

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let resolved = await credential(injected: token, for: .copilot) else {
            return unavailable(.notConfigured)
        }

        let (data, http) = try await QuotaHTTP.get(
            url: "https://api.github.com/copilot_internal/user",
            headers: Self.editorHeaders,
            auth: .header(name: "Authorization", value: "token \(resolved)")
        )
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) { return unavailable(reason) }
        guard let user = try? JSONDecoder().decode(UserResponse.self, from: data) else {
            return unavailable(.badResponse)
        }

        let resetDate = user.quota_reset_date.flatMap(Self.parseCopilotReset)
        let premium = user.quota_snapshots?.premium_interactions?.usedFraction
        let chat = user.quota_snapshots?.chat?.usedFraction
        // Business seats and unlimited plans are metered by GitHub's billing,
        // not by a percentage window. Say so instead of drawing a bar.
        guard premium != nil || chat != nil else {
            return unavailable(.unsupported("This Copilot plan publishes no quota"))
        }

        let worst = [premium, chat].compactMap { $0 }.max() ?? 0
        let urgency: Urgency = worst >= 0.95 ? .critical : worst >= 0.80 ? .warning : .none
        // nil when GitHub published no plan: the row subtitle then shows
        // nothing rather than asserting a tier nobody measured.
        let plan = user.copilot_plan.map { $0.capitalized }

        // Copilot's allowance runs to a monthly reset, so the pace marker is
        // the share of that calendar month elapsed — 28 to 31 days, taken from
        // the reset date rather than assumed to be 30.
        let pace = resetDate
            .flatMap(DualBarMetrics.monthWindowLength(endingAt:))
            .flatMap { DualBarMetrics.proRataPace(resetsAt: resetDate, windowLength: $0) }

        func row(_ fraction: Double?, _ label: String) -> DualBarMetrics? {
            guard let fraction else { return nil }
            return DualBarMetrics(
                primaryFraction: fraction, expectedPaceFraction: pace, label: label,
                statusColor: worst >= 0.95 ? "#ffb4ab" : "#6e7681",
                usedText: "\(label == "PREM" ? "Premium" : "Chat"): \(Int((fraction * 100).rounded()))% used",
                resetText: resetDate.map { "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()))" }
            )
        }

        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .subscription(tierName: plan ?? displayName, renewalDate: resetDate),
            status: .measured(urgency),
            resetsAt: resetDate,
            lastUpdated: Date(),
            auxiliaryInfo: "Live Copilot entitlement",
            row1: row(premium, "PREM"),
            row2: row(chat, "CHAT"),
            badgeText: worst >= 1.0 ? "Exhausted" : "\(Int(((1 - worst) * 100).rounded()))% left",
            planName: plan,
            keyMasked: nil,
            cliSource: "GitHub OAuth token"
        )
    }

    /// `quota_reset_date` arrives as a bare `yyyy-MM-dd` as often as a full
    /// timestamp, and `ISO8601DateFormatter` rejects the short form.
    static func parseCopilotReset(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }

        let dayOnly = DateFormatter()
        dayOnly.calendar = Calendar(identifier: .gregorian)
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: trimmed)
    }
}
