import Foundation

/// Command Code subscription usage.
///
/// Two calls, mirroring the `cmd` CLI's own `/usage` command, both
/// authenticated with the long-lived API key `cmd login` writes (or the
/// `COMMAND_CODE_API_KEY` / `COMMANDCODE_API_KEY` environment variable):
///
///   1. `GET https://api.commandcode.ai/alpha/whoami?limits=1` — best effort;
///      only `org.id` is read, so the credits call can carry `?orgId=`.
///   2. `GET https://api.commandcode.ai/alpha/billing/credits` — the quota
///      payload: the two rolling windows and the credit balance.
///
/// The `alpha` routes are not officially documented. The shapes below match
/// what the CLI reads, corroborated by two independent open-source
/// implementations and their captured responses.
///
/// The API publishes the two window caps and the *remaining* monthly credits
/// (`monthlyCredits`, plus the purchased and free buckets), but not the
/// allowance those credits draw down. The allowance is Command Code's own
/// published figure for each plan (commandcode.ai/docs/resources/pricing-limits),
/// keyed by the `planId` the API returns, so the credit gauge is a real
/// measurement. An unrecognised plan id yields no gauge rather than a guessed
/// denominator, and the figures have to be revisited when Command Code changes
/// its plans.
public final class CommandCodeQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .commandcode
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    // MARK: - Endpoints

    static let whoamiURL = "https://api.commandcode.ai/alpha/whoami?limits=1"
    static let creditsURL = "https://api.commandcode.ai/alpha/billing/credits"

    // MARK: - Fetch

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let key = await credential(injected: apiKey, for: .commandcode) else {
            return unavailable(.notConfigured)
        }

        // The org id only refines the credits call (organization plans pool
        // credits). A whoami that fails costs that refinement, never the
        // reading itself, so its errors are swallowed here on purpose — the
        // credits call's own status is what decides the outcome.
        let orgId = await Self.fetchOrgId(apiKey: key)

        var url = Self.creditsURL
        if let orgId, !orgId.isEmpty, var components = URLComponents(string: url) {
            components.queryItems = [URLQueryItem(name: "orgId", value: orgId)]
            url = components.url?.absoluteString ?? url
        }

        let (data, http) = try await QuotaHTTP.get(
            url: url,
            headers: ["Accept": "application/json"],
            auth: .bearer(key)
        )
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) { return unavailable(reason) }

        guard let response = Self.decode(CreditsResponse.self, from: data) else {
            return unavailable(.badResponse)
        }
        return Self.snapshot(from: response, provider: self, now: Date())
    }

    private static func fetchOrgId(apiKey: String) async -> String? {
        guard let (data, http) = try? await QuotaHTTP.get(
            url: whoamiURL,
            headers: ["Accept": "application/json"],
            auth: .bearer(apiKey)
        ), QuotaHTTP.failureReason(for: http.statusCode) == nil,
            let whoami = decode(WhoamiResponse.self, from: data)
        else { return nil }
        return whoami.org?.id?.trimmed
    }

    // MARK: - Snapshot construction

    static func snapshot(
        from response: CreditsResponse,
        provider: CommandCodeQuotaProvider,
        now: Date
    ) -> QuotaSnapshot {
        let windows = response.windowLimits
        let fiveHour = row(windows?.fiveHour, label: "5H", length: QuotaWindow.fiveHours, now: now)
        let weekly = row(windows?.weekly, label: "WK", length: QuotaWindow.week, now: now)
        let credits = creditRow(response.credits)

        // Neither a window nor a credit bucket is nothing we can report. A
        // structurally valid response carrying no figure must not render as a
        // healthy, fully-available provider.
        guard fiveHour != nil || weekly != nil || credits != nil else {
            return provider.unavailable(.badResponse)
        }

        let measured = [fiveHour, weekly, credits].compactMap(\.?.primaryFraction)
        let worst = measured.max()
        // `limited` is the vendor saying a request would be declined by a
        // window cap right now — that is quota pressure, not an availability
        // problem, so it is a real critical reading.
        let limited = windows?.limited?.value == true

        let urgency: Urgency
        if limited { urgency = .critical }
        else if let worst, worst >= 0.95 { urgency = .critical }
        else if let worst, worst >= 0.80 { urgency = .warning }
        else { urgency = .none }

        let badge: String?
        if limited { badge = "Blocked" }
        else if let worst, worst >= 1.0 { badge = "Exhausted" }
        else if let worst { badge = "\(Int(((1 - worst) * 100).rounded()))% left" }
        else { badge = nil }

        let planName = planDisplayName(response.credits?.planId)

        return QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .subscription(tierName: planName, renewalDate: nil),
            status: .measured(urgency),
            resetsAt: weekly?.resetsAt ?? fiveHour?.resetsAt,
            lastUpdated: now,
            auxiliaryInfo: "Live Command Code usage",
            row1: fiveHour,
            row2: weekly,
            row3: credits,
            badgeText: badge,
            planName: planName,
            cliSource: nil
        )
    }

    /// One rolling window. Its cap and usage are both published, so the bar is
    /// a real measurement.
    ///
    /// A window with a cap but no `used` figure is skipped rather than treated
    /// as zero: the vendor published no usage, and drawing 0% would read as
    /// "plenty left" for a window we know nothing about.
    static func row(
        _ window: WindowLimits.Window?,
        label: String,
        length: TimeInterval,
        now: Date
    ) -> DualBarMetrics? {
        guard let window,
              let cap = window.cap?.value, cap > 0,
              let used = window.used?.value, used >= 0
        else { return nil }

        let fraction = min(max(used / cap, 0), 1)
        let reset = window.resetAt?.date
        return DualBarMetrics(
            primaryFraction: fraction,
            expectedPaceFraction: DualBarMetrics.proRataPace(
                resetsAt: reset, windowLength: length, now: now),
            label: label,
            usedText: "\(money(used))/\(money(cap)) credits used",
            resetText: reset.map {
                "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))"
            },
            resetsAt: reset,
            windowLength: length
        )
    }

    /// The plan's monthly credits as a real gauge.
    ///
    /// The denominator is the allowance Command Code publishes for the plan;
    /// the balance (`monthlyCredits`) is what is left of it. Purchased and free
    /// credits are uncapped headroom that outlives the plan pool, so they widen
    /// the denominator too: the gauge then answers "how much can I still
    /// spend", where a plan-only denominator would read as exhausted while
    /// on-demand credits were still paying for work.
    ///
    /// When the plan id is unrecognised there is no published allowance, so the
    /// row degrades to the balance as text with no bar — never a guessed
    /// denominator.
    static func creditRow(_ credits: Credits?) -> DualBarMetrics? {
        guard let credits, let remaining = credits.remainingCredits else { return nil }

        guard let allowance = planAllowance(credits.planId), allowance > 0 else {
            return DualBarMetrics(
                primaryFraction: nil,
                label: "CR",
                usedText: remaining > 0 ? "\(money(remaining)) credits left" : "No credits left"
            )
        }

        let monthly = max(credits.monthlyCredits?.value ?? 0, 0)
        // `max(allowance, monthly)` guards a balance reported above the known
        // allowance — a plan change mid-cycle, say — so `used` cannot go
        // negative.
        let total = max(allowance, monthly)
            + max(credits.purchasedCredits?.value ?? 0, 0)
            + max(credits.freeCredits?.value ?? 0, 0)
        guard total > 0 else { return nil }

        let used = min(max(total - remaining, 0), total)
        return DualBarMetrics(
            primaryFraction: used / total,
            label: "CR",
            usedText: "\(money(used))/\(money(total)) credits used"
        )
    }

    /// The plans Command Code sells, with the monthly credit allowance it
    /// publishes for each (`commandcode.ai/docs/resources/pricing-limits`).
    ///
    /// The *ids* are not documented — they are the strings observed in the
    /// `planId` field — so this mapping is inferred and is the one part of this
    /// provider that has to be revisited when Command Code changes its plans.
    /// A nil allowance means the plan has no monthly credits at all (Provider
    /// is pay-as-you-go), which is an answer, not a gap.
    static let plans: [(prefix: String, name: String, allowance: Double?)] = [
        ("individual-provider", "Provider", nil),
        ("individual-pro-v1", "Pro", 80),
        ("individual-ultra", "Max", 300),
        ("individual-goat", "GOAT", 70),
        ("individual-pro", "Pro", 80),
        ("individual-max", "Max", 150),
        ("individual-go", "Go", 10),
        ("teams-pro", "Team Pro", 40),
    ]

    /// The plan row whose id is the longest matching prefix, so
    /// `individual-pro-v1` never falls through to `individual-pro`.
    private static func plan(_ raw: String?) -> (name: String, allowance: Double?)? {
        let normalized = (raw?.trimmed ?? "").lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        return plans
            .sorted { $0.prefix.count > $1.prefix.count }
            .first { normalized.hasPrefix($0.prefix) }
            .map { ($0.name, $0.allowance) }
    }

    /// The plan id mapped to the name Command Code markets it under.
    ///
    /// A label only. An unrecognised id returns nil rather than a guess (see
    /// `shortPlanName`'s note on the old hardcoded tier table).
    static func planDisplayName(_ raw: String?) -> String? {
        plan(raw)?.name
    }

    /// The monthly credit allowance Command Code publishes for the plan, or nil
    /// when the id is unrecognised or the plan has no monthly credits.
    static func planAllowance(_ raw: String?) -> Double? {
        plan(raw)?.allowance
    }

    static func money(_ amount: Double) -> String {
        SubscriptionCycle.formatCost(Decimal(amount), currencyCode: "USD")
    }

    // MARK: - Decoding

    /// Some deployments wrap the payload in a `data` object; the CLI reads
    /// `a.data` when present. Both the wrapped and bare shapes decode here.
    struct Envelope<T: Decodable>: Decodable {
        let data: T?
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope<T>.self, from: data),
           let inner = envelope.data {
            return inner
        }
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - Response shape

    struct WhoamiResponse: Decodable, Sendable {
        struct Org: Decodable, Sendable { let id: String? }
        let org: Org?
    }

    struct CreditsResponse: Decodable, Sendable {
        let credits: Credits?
        let windowLimits: WindowLimits?
    }

    struct Credits: Decodable, Sendable {
        let planId: String?
        let monthlyCredits: FlexibleNumber?
        let purchasedCredits: FlexibleNumber?
        let freeCredits: FlexibleNumber?

        /// The three buckets summed, or nil when the payload publishes none of
        /// them — in which case there is no balance to report, rather than a
        /// zero to infer.
        var remainingCredits: Double? {
            let monthly = monthlyCredits?.value
            let purchased = purchasedCredits?.value
            let free = freeCredits?.value
            guard monthly != nil || purchased != nil || free != nil
            else { return nil }
            let monthlyBalance: Double = max(monthly ?? 0, 0)
            let purchasedBalance: Double = max(purchased ?? 0, 0)
            let freeBalance: Double = max(free ?? 0, 0)
            return monthlyBalance + purchasedBalance + freeBalance
        }
    }

    struct WindowLimits: Decodable, Sendable {
        /// The vendor's own "you are currently capped" signal.
        let limited: FlexibleBool?

        let fiveHour: Window?
        let weekly: Window?

        struct Window: Decodable, Sendable {
            let used: FlexibleNumber?
            let cap: FlexibleNumber?
            /// Epoch milliseconds, epoch seconds, or an ISO 8601 string —
            /// all three observed for these windows.
            let resetAt: FlexibleTimestamp?
        }
    }

    /// A field the API sends as a JSON number or a numeric string.
    struct FlexibleNumber: Decodable, Sendable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = nil
            } else if let number = try? container.decode(Double.self) {
                value = number.isFinite ? number : nil
            } else if let text = try? container.decode(String.self) {
                let parsed = Double(text.trimmed)
                value = (parsed?.isFinite ?? false) ? parsed : nil
            } else {
                value = nil
            }
        }
    }

    /// A boolean the API may send as a JSON bool, a number, or a string.
    struct FlexibleBool: Decodable, Sendable {
        let value: Bool?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = nil
            } else if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let number = try? container.decode(Double.self) {
                value = number != 0
            } else if let text = try? container.decode(String.self) {
                switch text.trimmed.lowercased() {
                case "true", "1", "yes": value = true
                case "false", "0", "no": value = false
                default: value = nil
                }
            } else {
                value = nil
            }
        }
    }

    /// A reset time in any of the three forms the API uses.
    struct FlexibleTimestamp: Decodable, Sendable {
        let date: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self), number.isFinite, number > 0 {
                // Milliseconds land beyond any plausible second epoch; a unit
                // change must not draw a countdown centuries out.
                date = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
            } else if let text = try? container.decode(String.self) {
                date = Self.parseISO8601(text)
            } else {
                date = nil
            }
        }

        /// `resetsAt` carries fractional seconds on some windows, which the
        /// plain ISO8601 parser rejects outright.
        static func parseISO8601(_ text: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            return ISO8601DateFormatter().date(from: text)
        }
    }
}
