import Foundation

/// ClinePass (Cline's subscription) usage.
///
/// One call: `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits`
/// with `Authorization: Bearer <credential>`, which reports ClinePass's three
/// windows — the rolling 5 hours, the week and the month — as a percentage
/// used plus a reset time each.
///
/// What is verified against cline's own source (github.com/cline/cline):
/// - The account API base, `https://api.cline.bot/api/v1`, and its
///   `{"success": Bool, "data": T}` envelope (`sdk/packages/core/src/account/
///   cline-account-service.ts`), which also falls back to a bare body.
/// - The account token is sent as `Bearer workos:<token>`, and providers.json
///   already stores it with that prefix (`apps/vscode/src/sdk/auth-service.ts`).
/// - Where the token lives; see `discoverCLICredential`.
///
/// Observed against the live API (2026-10-03): a plain app.cline.bot API key
/// is accepted as `Bearer <key>` with no prefix, and an account without
/// ClinePass gets HTTP 404 with
/// `{"data":null,"error":"no plan history found for user","success":false}`
/// from this route, which is reported as unsupported rather than as a fault.
///
/// What is third-party: the success shape,
/// `{"limits": [{"type", "percentUsed", "resetsAt"}]}`, does not appear in
/// cline's source and was not observed live. It comes from several
/// independent integrations that agree on it; no official documentation
/// exists.
///
/// What is deliberately not shown: the account's credit balance. The balance
/// endpoint's unit is undocumented and the integrations disagree on it (cents,
/// micro-dollars, 1e-4 dollars). A dollar figure off by a factor of 100 is
/// worse than none, so only the three percentage windows are tracked.
public final class ClinePassQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .clinepass
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    static let usageLimitsURL = "https://api.cline.bot/api/v1/users/me/plan/usage-limits"

    /// The prefix Cline's API expects on an account (WorkOS) token.
    static let workosPrefix = "workos:"

    static let noSubscription = UnavailableReason.unsupported("No ClinePass subscription on this account")

    // MARK: - Fetch

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        try await fetchSnapshot(now: Date())
    }

    func fetchSnapshot(now: Date) async throws -> QuotaSnapshot {
        guard let key = await credential(injected: apiKey, for: .clinepass)?.trimmed, !key.isEmpty else {
            return unavailable(.notConfigured)
        }

        var (data, http) = try await Self.get(credential: key)
        // A pasted account token may lack the `workos:` prefix the API wants
        // on account tokens; an API key is sent bare. Nothing in the string
        // says which one it is, so a 401 on a bare credential is retried once
        // with the prefix before being reported as rejected.
        if http.statusCode == 401, !key.lowercased().hasPrefix(Self.workosPrefix) {
            (data, http) = try await Self.get(credential: Self.workosPrefix + key)
        }

        if http.statusCode == 404 {
            return unavailable(Self.noSubscription)
        }
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) { return unavailable(reason) }

        switch Self.decode(data) {
        case .limits(let payload): return Self.snapshot(from: payload, provider: self, now: now)
        case .noPlan:              return unavailable(Self.noSubscription)
        case .failed:              return unavailable(.badResponse)
        }
    }

    private static func get(credential: String) async throws -> (Data, HTTPURLResponse) {
        try await QuotaHTTP.get(
            url: usageLimitsURL,
            headers: ["Accept": "application/json"],
            auth: .bearer(credential)
        )
    }

    // MARK: - Snapshot construction

    static func snapshot(
        from payload: UsageLimits,
        provider: ClinePassQuotaProvider,
        now: Date
    ) -> QuotaSnapshot {
        let limits = payload.limits ?? []
        func window(_ type: String) -> Limit? {
            limits.first { $0.type?.trimmed.lowercased() == type }
        }
        let fiveHour = window("five_hour").flatMap {
            row($0, label: "5H", length: { _ in QuotaWindow.fiveHours }, now: now)
        }
        let weekly = window("weekly").flatMap {
            row($0, label: "WK", length: { _ in QuotaWindow.week }, now: now)
        }
        let monthly = window("monthly").flatMap {
            row($0, label: "MO", length: DualBarMetrics.monthWindowLength(endingAt:), now: now)
        }

        // A well-formed envelope with no usable window is not a reading. It
        // must not render as a healthy, untouched subscription.
        let rows = [fiveHour, weekly, monthly].compactMap { $0 }
        guard let worst = rows.compactMap(\.primaryFraction).max() else {
            return provider.unavailable(.badResponse)
        }

        let urgency: Urgency = worst >= 0.90 ? .critical : worst >= 0.70 ? .warning : .none

        return QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            // A 200 here proves a ClinePass subscription exists, but the
            // payload names no tier, and the row already says "ClinePass" —
            // a plan subtitle repeating the vendor name is the placeholder
            // the Claude provider removed for saying nothing.
            metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(urgency),
            // The longest window's reset: the one the popover sorts by.
            resetsAt: monthly?.resetsAt ?? weekly?.resetsAt ?? fiveHour?.resetsAt,
            lastUpdated: now,
            auxiliaryInfo: "Live ClinePass usage",
            row1: fiveHour,
            row2: weekly,
            row3: monthly,
            badgeText: "\(Int(((1 - worst) * 100).rounded()))% left",
            planName: nil,
            cliSource: nil
        )
    }

    /// One window. A window with no `percentUsed` is skipped rather than drawn
    /// at 0%, which would read as "plenty left" for a window we know nothing
    /// about.
    static func row(
        _ limit: Limit,
        label: String,
        length: (Date) -> TimeInterval?,
        now: Date
    ) -> DualBarMetrics? {
        guard let percent = limit.percentUsed?.value else { return nil }
        let fraction = min(max(percent / 100, 0), 1)
        let reset = limit.resetsAt.flatMap(parseResetsAt)
        let windowLength = reset.flatMap(length)
        return DualBarMetrics(
            primaryFraction: fraction,
            expectedPaceFraction: windowLength.flatMap {
                DualBarMetrics.proRataPace(resetsAt: reset, windowLength: $0, now: now)
            },
            label: label,
            usedText: "\(Int((fraction * 100).rounded()))% used",
            resetText: reset.map {
                "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))"
            },
            resetsAt: reset,
            windowLength: windowLength
        )
    }

    /// `resetsAt` arrives with nanosecond precision
    /// (`2026-09-25T14:32:27.073666206Z`). The macOS 26 parser accepts nine
    /// digits, but `.withFractionalSeconds` is documented for milliseconds
    /// only, so the fraction is cut to three digits rather than leaning on
    /// that. A timestamp with no fraction parses as-is.
    static func parseResetsAt(_ raw: String) -> Date? {
        var text = raw.trimmed
        if let dot = text.firstIndex(of: ".") {
            let digitsEnd = text[text.index(after: dot)...].firstIndex { !$0.isNumber } ?? text.endIndex
            let digits = text[text.index(after: dot)..<digitsEnd]
            if digits.count > 3 {
                text = String(text[...dot]) + digits.prefix(3) + text[digitsEnd...]
            }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    // MARK: - Decoding

    /// The account API wraps payloads as `{"data", "error", "success"}`, and
    /// cline's own client accepts a bare body too. `success: false` is never a
    /// reading: it is "no ClinePass" when the error says there is no plan
    /// history, and a bad response otherwise, even under HTTP 200.
    struct Envelope: Decodable {
        let success: Bool?
        let error: String?
        let data: UsageLimits?
    }

    enum Decoded {
        case limits(UsageLimits)
        case noPlan
        case failed
    }

    static func decode(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            if envelope.success == false {
                let noPlan = envelope.error?.lowercased().contains("no plan history") == true
                return noPlan ? .noPlan : .failed
            }
            if let inner = envelope.data { return .limits(inner) }
        }
        return (try? decoder.decode(UsageLimits.self, from: data)).map(Decoded.limits) ?? .failed
    }

    struct UsageLimits: Decodable, Sendable {
        let limits: [Limit]?
    }

    /// Unknown `type` values decode fine and are simply never looked up.
    struct Limit: Decodable, Sendable {
        let type: String?
        let percentUsed: Percent?
        let resetsAt: String?
    }

    /// A percentage sent as a JSON number or a numeric string. Anything else,
    /// including null, is no reading.
    struct Percent: Decodable, Sendable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number.isFinite ? number : nil
            } else if let text = try? container.decode(String.self), let parsed = Double(text.trimmed) {
                value = parsed.isFinite ? parsed : nil
            } else {
                value = nil
            }
        }
    }

    // MARK: - Credential discovery

    /// The first credential found, in this order:
    ///
    /// 1. `CLINE_API_KEY`, then `CLINEPASS_API_KEY` — a convention of
    ///    third-party tools, not something cline itself reads.
    /// 2. `<data>/settings/providers.json` — the Cline CLI/SDK's provider
    ///    store (`ProviderSettingsManager`). Shape:
    ///    `{"providers": {"cline": {"settings": {"apiKey", "auth":
    ///    {"accessToken", "expiresAt", …}}}}}`. The `cline` entry is read,
    ///    then the `cline-pass` one; within each, `auth.accessToken` (stored
    ///    already prefixed `workos:`), then `apiKey`, then `auth.apiKey`. An
    ///    access token whose `expiresAt` (epoch milliseconds) has passed is
    ///    skipped: FrugalBar does not refresh it, and sending it would only
    ///    show "Credential rejected" for what is really "run cline again".
    /// 3. `<data>/secrets.json` `clineApiKey` — the pre-SDK standalone store
    ///    that cline's legacy migration still reads.
    ///
    /// `<data>` is `$CLINE_DATA_DIR`, else `$CLINE_DIR/data`, else
    /// `~/.cline/data` (see `CLIConfigLocations.clineDataRoot`).
    static func discoverCLICredential(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        now: Date = Date()
    ) -> String? {
        for name in ["CLINE_API_KEY", "CLINEPASS_API_KEY"] {
            if let value = environment[name]?.trimmed, !value.isEmpty { return value }
        }

        let providersURL = CLIConfigLocations.clineDataRoot(
            containing: "settings/providers.json", environment: environment, home: home, fileExists: fileExists
        ).appendingPathComponent("settings/providers.json")
        if let data = try? Data(contentsOf: providersURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let providers = root["providers"] as? [String: Any] {
            for id in ["cline", "cline-pass"] {
                guard let entry = providers[id] as? [String: Any],
                      let settings = entry["settings"] as? [String: Any]
                else { continue }
                if let token = credential(fromSettings: settings, now: now) { return token }
            }
        }

        let secretsURL = CLIConfigLocations.clineDataRoot(
            containing: "secrets.json", environment: environment, home: home, fileExists: fileExists
        ).appendingPathComponent("secrets.json")
        if let data = try? Data(contentsOf: secretsURL),
           let secrets = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = (secrets["clineApiKey"] as? String)?.trimmed, !key.isEmpty {
            return key
        }
        return nil
    }

    private static func credential(fromSettings settings: [String: Any], now: Date) -> String? {
        let auth = settings["auth"] as? [String: Any]
        if let token = (auth?["accessToken"] as? String)?.trimmed, !token.isEmpty {
            let expired = (auth?["expiresAt"] as? Double)
                .map { Date(timeIntervalSince1970: $0 / 1000) <= now } ?? false
            if !expired { return token }
        }
        for candidate in [settings["apiKey"], auth?["apiKey"]] {
            if let key = (candidate as? String)?.trimmed, !key.isEmpty { return key }
        }
        return nil
    }
}
