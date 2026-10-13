import Foundation

/// Meta Muse Code subscription usage.
///
/// `POST https://api.meta.ai/muse-code/key`, authenticated with the OAuth
/// session token the Muse Code CLI stores in the macOS login Keychain (service
/// `ai.meta.dev.credentials`, account `meta`).
///
/// Muse publishes **no read-only usage endpoint**. The subscription snapshot
/// rides the CLI's own key-mint response — the same call the CLI makes on
/// launch — and this provider polls exactly that. The call is idempotent: it
/// returns the key the account already holds and creates nothing (verified
/// against a live account: repeated calls return a byte-identical `api_key`).
/// The alternative the CLI also uses, a usage frame carried in-band on a model
/// response, is deliberately not used: FrugalBar never makes a model call, so
/// polling would spend the quota it reports.
///
/// The minted `api_key` in that response is **not** a usable credential here —
/// the endpoint authenticates the OAuth session and answers a minted api_key
/// with 401. Only `access_token` is sent.
///
/// The vendor normalises its two blocks to percentages:
/// `window` is the five-hour-class block (and carries its own length),
/// `weekly` is the rolling week. `used_percent` is verbatim and may exceed 100,
/// so it is never clamped as a *figure* — only the bar fill is clamped to the
/// track, and an over-quota window still reads "Exhausted".
public final class MuseQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .muse
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    /// The OAuth access token, when one is injected (Settings' verify, tests).
    private let apiKey: String?

    /// Named `apiKey` to match every other provider's call site, though the
    /// value is the Muse OAuth session token, not the minted api key.
    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    // MARK: - Endpoint

    static let usageURL = "https://api.meta.ai/muse-code/key"

    // MARK: - Fetch

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let token = await credential(injected: apiKey, for: .muse) else {
            return unavailable(.notConfigured)
        }

        // The body must be JSON: an empty body is a 400 upstream, so `{}` is
        // sent even though the endpoint takes no parameters.
        let (data, http) = try await QuotaHTTP.post(
            url: Self.usageURL,
            body: Data("{}".utf8),
            headers: [
                "Accept": "application/json",
                "x-api-version": "1.0.0",
            ],
            auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(
            for: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After")
        ) {
            return unavailable(reason)
        }

        guard let response = Self.parse(data) else {
            return unavailable(.badResponse)
        }
        return Self.snapshot(from: response, provider: self, now: Date())
    }

    // MARK: - Response shape

    struct KeyResponse: Decodable, Sendable {
        /// The vendor's own statement that the subscription can serve a request
        /// right now. Absent is "unknown", never assumed active.
        let is_subs_active: Bool?
        /// The vendor's own statement that the account cannot serve until a
        /// payment method is added.
        let require_payment: Bool?
        /// "Muse Code Power Usage" — the subscription tier's published name.
        let subs_tier_name: String?
        let subs_usage: SubscriptionUsage?
    }

    /// The one usage payload. `window` is the five-hour-class block; `weekly`
    /// is the rolling week, which the vendor publishes without a duration.
    struct SubscriptionUsage: Decodable, Sendable {
        let window: Window?
        let weekly: Weekly?
        let tier: String?

        struct Window: Decodable, Sendable {
            let used_percent: MuseNumber?
            /// The vendor's own window length (300 = five hours). Absent means
            /// no pace tick, never a constant.
            let window_duration_mins: MuseNumber?
            /// Epoch seconds, as the endpoint sends it.
            let resets_at: MuseTimestamp?
        }

        struct Weekly: Decodable, Sendable {
            let used_percent: MuseNumber?
            let resets_at: MuseTimestamp?
        }
    }

    /// A field the endpoint sends as a JSON number, tolerated as a numeric
    /// string so a future response that starts quoting it still decodes.
    struct MuseNumber: Decodable, Sendable {
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

    /// A reset time. The endpoint sends epoch **seconds**; the CLI normalises
    /// them to milliseconds for its own wire schema, so both are accepted —
    /// a unit change must not draw a countdown centuries out.
    struct MuseTimestamp: Decodable, Sendable {
        let date: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self), number.isFinite, number > 0 {
                date = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
            } else if let text = try? container.decode(String.self) {
                date = Self.parseISO8601(text)
            } else {
                date = nil
            }
        }

        static func parseISO8601(_ text: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            return ISO8601DateFormatter().date(from: text)
        }
    }

    static func parse(_ data: Data) -> KeyResponse? {
        try? JSONDecoder().decode(KeyResponse.self, from: data)
    }

    // MARK: - Snapshot construction

    /// Builds the snapshot from a decoded body. Split from the network call so
    /// every branch is tested without one, and with an explicit `now` so no
    /// assertion depends on the wall clock.
    static func snapshot(
        from response: KeyResponse,
        provider: MuseQuotaProvider,
        now: Date
    ) -> QuotaSnapshot {
        // A present-and-false `is_subs_active` says the subscription cannot
        // serve a request. It is a state the user must act on, not an absent
        // reading, so it never renders as a healthy, fully-available row. An
        // *absent* flag is unknown, not "active", so it falls through to the
        // usage check rather than assuming health.
        if response.is_subs_active == false {
            return response.require_payment == true
                ? paymentRequiredSnapshot(provider: provider, now: now)
                : provider.unavailable(.unsupported("Muse reported no active subscription"))
        }

        guard let usage = response.subs_usage else {
            return provider.unavailable(.unsupported("Muse reported no subscription usage"))
        }

        let fiveHour = row(usage.window, label: "5H", now: now)
        let weekly = row(usage.weekly, label: "WK", now: now)

        // A body carrying no window at all is "the vendor published nothing",
        // not a healthy provider: there is no figure to draw, so this must not
        // reach `measured`.
        guard fiveHour != nil || weekly != nil else {
            return provider.unavailable(.unsupported("Muse reported no usage window"))
        }

        let measured = [fiveHour, weekly].compactMap { $0?.primaryFraction }
        let worst = measured.max()
        let urgency: Urgency
        if let worst, worst >= 0.95 { urgency = .critical }
        else if let worst, worst >= 0.80 { urgency = .warning }
        else { urgency = .none }

        let badge: String?
        if let worst, worst >= 1.0 { badge = "Exhausted" }
        else if let worst { badge = "\(Int(((1 - worst) * 100).rounded()))% left" }
        else { badge = nil }

        // The vendor's own tier label, verbatim. `subs_usage.tier` is an opaque
        // numeric id and `nil` would leave the subtitle empty, so the published
        // name is used as-is rather than trimmed to a guessed plan word.
        let planName = response.subs_tier_name?.trimmed

        return QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .subscription(tierName: planName, renewalDate: nil),
            status: .measured(urgency),
            resetsAt: weekly?.resetsAt ?? fiveHour?.resetsAt,
            lastUpdated: now,
            auxiliaryInfo: "Live Muse Code subscription usage",
            row1: fiveHour,
            row2: weekly,
            badgeText: badge,
            planName: planName,
            cliSource: "macOS Keychain / Muse CLI"
        )
    }

    /// The subscription exists but cannot serve a request until a payment
    /// method is added. A real critical state, on DeepSeek's `is_available`
    /// precedent — not "no usage API", and not a 0%-used healthy row.
    private static func paymentRequiredSnapshot(
        provider: MuseQuotaProvider,
        now: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(.critical),
            resetsAt: nil,
            lastUpdated: now,
            auxiliaryInfo: "Live Muse Code subscription usage",
            row1: nil,
            row2: nil,
            badgeText: "Payment required",
            planName: nil,
            cliSource: "macOS Keychain / Muse CLI"
        )
    }

    /// One block as a bar.
    ///
    /// A block with no percentage is omitted rather than drawn at 0%: the
    /// vendor published no figure, and a 0% bar would read as "plenty left".
    private static func row(_ block: SubscriptionUsage.Window?, label: String, now: Date) -> DualBarMetrics? {
        guard let block, let percent = block.used_percent?.value else { return nil }
        // The vendor's own length when it gives one; `nil` otherwise, which
        // draws no pace tick rather than inventing a window length.
        let length = block.window_duration_mins?.value.flatMap { $0 > 0 ? $0 * 60 : nil }
        return Self.bar(fraction: percent / 100, label: label, reset: block.resets_at?.date,
                        length: length, now: now)
    }

    /// The rolling week. Muse publishes the block without a duration; the name
    /// is the period, the same reading `QuotaWindow.week` carries everywhere
    /// else in the app.
    private static func row(_ block: SubscriptionUsage.Weekly?, label: String, now: Date) -> DualBarMetrics? {
        guard let block, let percent = block.used_percent?.value else { return nil }
        return Self.bar(fraction: percent / 100, label: label, reset: block.resets_at?.date,
                        length: QuotaWindow.week, now: now)
    }

    private static func bar(
        fraction: Double,
        label: String,
        reset: Date?,
        length: TimeInterval?,
        now: Date
    ) -> DualBarMetrics {
        // Verbatim percentages, so an over-quota reading (say 120) stays over
        // quota in the text while the fill only ever reaches the end of the
        // track.
        let clamped = min(max(fraction, 0), 1)
        let percentText = Int(fraction.isFinite ? (fraction * 100).rounded() : 0)
        return DualBarMetrics(
            primaryFraction: clamped,
            expectedPaceFraction: length.flatMap {
                DualBarMetrics.proRataPace(resetsAt: reset, windowLength: $0, now: now)
            },
            label: label,
            usedText: "\(percentText)% used",
            resetText: reset.map {
                "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))"
            },
            resetsAt: reset,
            windowLength: length
        )
    }

    // MARK: - CLI discovery

    /// The Muse Code CLI's OAuth session token, read from the blob the CLI
    /// stores in the macOS login Keychain. Returns nil when there is no CLI
    /// login; the user's own pasted token wins over this in `apiKey(for:)`.
    static func discoverCLICredential() -> String? {
        accessToken(from: CredentialStore.cachedMuseBlob())
    }

    /// Extracts `access_token` from the CLI's credential blob
    /// (`{secret_schema_version, access_token, api_key}`). The api_key is not
    /// returned: the mint rejects it.
    static func accessToken(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty
        else { return nil }
        return token
    }
}
