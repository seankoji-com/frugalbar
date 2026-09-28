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
/// One deliberate omission. The API publishes the *remaining* monthly credits
/// (`monthlyCredits`, plus the purchased and free buckets) but never the
/// allowance they are drawn from. A percentage needs a denominator, so the
/// balance is shown as text and no bar is drawn for it. Deriving the allowance
/// from a hard-coded plan table would put a guessed number beneath a
/// real-looking gauge — the one thing this app refuses to do (see AGENTS.md).
/// The two window caps, by contrast, are published outright, so those bars are
/// real.
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

        let measured = [fiveHour, weekly].compactMap(\.?.primaryFraction)
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
            metric: .subscription(tierName: planName ?? provider.displayName, renewalDate: nil),
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

    /// The credit balance as a text-only row.
    ///
    /// `primaryFraction` is deliberately nil: the API publishes the remaining
    /// balance but not the allowance, so there is no denominator to draw
    /// against. A nil fraction renders as a neutral label over an empty track
    /// (the same "no reading" case DevPass's limit-less key uses), never as a
    /// fabricated percentage.
    static func creditRow(_ credits: Credits?) -> DualBarMetrics? {
        guard let credits, let remaining = credits.remainingCredits else { return nil }
        return DualBarMetrics(
            primaryFraction: nil,
            label: "CR",
            usedText: remaining > 0 ? "\(money(remaining)) credits left" : "No credits left"
        )
    }

    /// The plan id mapped to the name Command Code markets it under.
    ///
    /// A *label* only — never a denominator. The vendor documents its plan
    /// names but not these ids, so an unrecognised id returns nil rather than a
    /// guess (see `shortPlanName`'s note on the old hardcoded tier table).
    static func planDisplayName(_ raw: String?) -> String? {
        let normalized = (raw?.trimmed ?? "").lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }

        let table: [(prefix: String, name: String)] = [
            ("individual-provider", "Provider"),
            ("individual-pro-v1", "Pro"),
            ("individual-ultra", "Max"),
            ("individual-goat", "GOAT"),
            ("individual-pro", "Pro"),
            ("individual-max", "Max"),
            ("individual-go", "Go"),
            ("teams-pro", "Team Pro"),
        ]
        // Longest prefix first, so `individual-provider` never matches
        // `individual-pro`.
        return table
            .sorted { $0.prefix.count > $1.prefix.count }
            .first { normalized.hasPrefix($0.prefix) }?
            .name
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
            guard monthlyCredits?.value != nil
                || purchasedCredits?.value != nil
                || freeCredits?.value != nil
            else { return nil }
            return max(monthlyCredits?.value ?? 0, 0)
                + max(purchasedCredits?.value ?? 0, 0)
                + max(freeCredits?.value ?? 0, 0)
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
