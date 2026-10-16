import Foundation

/// Configuration for connecting to a CLIProxyAPI instance.
public struct CLIProxyConfig: Sendable, Equatable {
    public let url: URL
    public let managementKey: String
    public let label: String?

    public init(url: URL, managementKey: String, label: String? = nil) {
        self.url = url
        self.managementKey = managementKey
        self.label = label
    }
}

/// An account managed by CLIProxyAPI.
public struct CLIProxyAuthFile: Decodable, Sendable, Equatable {
    public struct IDToken: Decodable, Sendable, Equatable {
        public let chatgptAccountId: String?
        public let chatgptPlanType: String?
        public let planType: String?

        public init(chatgptAccountId: String? = nil, chatgptPlanType: String? = nil, planType: String? = nil) {
            self.chatgptAccountId = chatgptAccountId
            self.chatgptPlanType = chatgptPlanType
            self.planType = planType
        }

        enum CodingKeys: String, CodingKey {
            case chatgptAccountId = "chatgpt_account_id"
            case chatgptPlanType = "chatgpt_plan_type"
            case planType = "plan_type"
        }
    }

    public let id: String?
    public let authIndex: String
    public let provider: String
    public let email: String?
    public let disabled: Bool?
    public let idToken: IDToken?

    public init(
        id: String? = nil,
        authIndex: String,
        provider: String,
        email: String? = nil,
        disabled: Bool? = nil,
        idToken: IDToken? = nil
    ) {
        self.id = id
        self.authIndex = authIndex
        self.provider = provider
        self.email = email
        self.disabled = disabled
        self.idToken = idToken
    }

    enum CodingKeys: String, CodingKey {
        case id
        case authIndex = "auth_index"
        case provider
        case email
        case disabled
        case idToken = "id_token"
    }
}

/// Anthropic OAuth usage API response payload.
public struct ClaudeOAuthUsageResponse: Decodable, Sendable, Equatable {
    public struct Window: Decodable, Sendable, Equatable {
        public let utilization: Double
        public let resetsAt: String?

        public init(utilization: Double, resetsAt: String? = nil) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    /// Anthropic's monthly **extra-usage** credit, as this endpoint publishes
    /// it: a spend figure and the monthly limit it draws on.
    ///
    /// Two shapes have been seen on this endpoint, and both are decoded
    /// leniently:
    ///
    /// - the older `extra_usage` block — `is_enabled`, `used_credits`,
    ///   `monthly_limit`, `currency` — whose two amounts are in **minor units
    ///   (cents)**, so they are scaled by `decimal_places` when the payload
    ///   declares it and by 2 otherwise. This is the one place in this app
    ///   where a money figure *is* divided by 100, and the only reason the
    ///   resulting dollars can be trusted is that the payload's own unit is
    ///   minor units: assuming the opposite would print a $20.00 monthly limit
    ///   as $2,000.00.
    /// - the newer `spend` block, which states its own minor unit and exponent
    ///   per amount (`{amount_minor, currency, exponent}`), so no scale is
    ///   assumed at all.
    ///
    /// An `enabled` / `is_enabled` that is not true is the vendor saying the
    /// pool is off, which is why it yields no entry rather than a stale one.
    /// Every figure is nil when the payload did not carry it: nothing here is
    /// defaulted to 0.
    public struct MoneyCredit: Sendable, Equatable {
        /// Which block of the payload this reading was taken from.
        ///
        /// The two blocks are the same pool in two shapes, and only the block
        /// that actually answered can be named: a `spend` block that is off or
        /// unreadable falls through to `extra_usage` (see `monthlyCredit`), so
        /// a provenance line that assumed the newer block won would name a
        /// block that contributed nothing.
        public enum Source: String, Sendable, Equatable {
            case spend
            case extraUsage = "extra_usage"
        }

        public let used: Decimal
        public let limit: Decimal?
        public let currencyCode: String
        /// Defaulted to the older block, so a caller that does not track the
        /// provenance cannot claim the newer one by omission.
        public let source: Source

        public init(
            used: Decimal, limit: Decimal?, currencyCode: String,
            source: Source = .extraUsage
        ) {
            self.used = used
            self.limit = limit
            self.currencyCode = currencyCode
            self.source = source
        }

        /// The remaining balance, derived by subtraction *only* when both
        /// published figures are present — the same arithmetic OpenRouter's
        /// credit balance already rests on, and never a substitute for a
        /// figure the vendor withheld.
        public var remaining: Decimal? {
            guard let limit, limit >= used else { return nil }
            return limit - used
        }
    }

    /// The `spend` block's per-amount shape: minor units plus the exponent that
    /// turns them into major ones.
    public struct SpendAmount: Decodable, Sendable, Equatable {
        public let amountMinor: Int?
        public let currency: String?
        public let exponent: Int?

        public init(amountMinor: Int?, currency: String?, exponent: Int?) {
            self.amountMinor = amountMinor
            self.currency = currency
            self.exponent = exponent
        }

        enum CodingKeys: String, CodingKey {
            case currency, exponent
            case amountMinor = "amount_minor"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LenientKey.self)
            amountMinor = c.lenientInt("amount_minor")
            currency = c.lenientString("currency")
            exponent = c.lenientInt("exponent")
        }

        /// The amount in major units, or nil when this block did not state a
        /// scale or a value. A negative amount is not a balance either, so it
        /// is nil rather than sign-flipped.
        public var majorUnits: Decimal? {
            guard let amountMinor, amountMinor >= 0, let exponent else { return nil }
            return ClaudeOAuthUsageResponse.scaled(amountMinor, exponent: exponent)
        }
    }

    public struct SpendBlock: Decodable, Sendable, Equatable {
        public let enabled: Bool?
        public let used: SpendAmount?
        public let limit: SpendAmount?

        public init(enabled: Bool?, used: SpendAmount?, limit: SpendAmount?) {
            self.enabled = enabled
            self.used = used
            self.limit = limit
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LenientKey.self)
            enabled = c.lenientBool("enabled")
            used = try? c.decodeIfPresent(SpendAmount.self, forKey: LenientKey(stringValue: "used"))
            limit = try? c.decodeIfPresent(SpendAmount.self, forKey: LenientKey(stringValue: "limit"))
        }
    }

    /// The older `extra_usage` block. Amounts are minor units (see
    /// `MoneyCredit`).
    public struct ExtraUsage: Decodable, Sendable, Equatable {
        public let isEnabled: Bool?
        public let usedCredits: Int?
        public let monthlyLimit: Int?
        public let currency: String?
        public let decimalPlaces: Int?

        public init(
            isEnabled: Bool?, usedCredits: Int?, monthlyLimit: Int?,
            currency: String?, decimalPlaces: Int?
        ) {
            self.isEnabled = isEnabled
            self.usedCredits = usedCredits
            self.monthlyLimit = monthlyLimit
            self.currency = currency
            self.decimalPlaces = decimalPlaces
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LenientKey.self)
            isEnabled = c.lenientBool("is_enabled")
            usedCredits = c.lenientInt("used_credits")
            monthlyLimit = c.lenientInt("monthly_limit")
            currency = c.lenientString("currency")
            decimalPlaces = c.lenientInt("decimal_places")
        }
    }

    /// Anthropic's promo / cloud-session credit — the `iguana_necktie` block,
    /// another feature codename. Its amounts are **already dollars**
    /// (`*_dollars`), so they are never scaled; `resets_at` here is the
    /// credit's **expiry**, not a recurring reset, which is why it is surfaced
    /// as an expiry and never as a countdown to a refill.
    public struct PromoCredit: Decodable, Sendable, Equatable {
        public let limitDollars: Decimal?
        public let usedDollars: Decimal?
        public let remainingDollars: Decimal?
        public let resetsAt: String?

        public init(
            limitDollars: Decimal?, usedDollars: Decimal?,
            remainingDollars: Decimal?, resetsAt: String?
        ) {
            self.limitDollars = limitDollars
            self.usedDollars = usedDollars
            self.remainingDollars = remainingDollars
            self.resetsAt = resetsAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LenientKey.self)
            limitDollars = c.lenientDecimal("limit_dollars")
            usedDollars = c.lenientDecimal("used_dollars")
            remainingDollars = c.lenientDecimal("remaining_dollars")
            resetsAt = c.lenientString("resets_at")
        }
    }

    /// Minor units → major units. `decimal_places`/`exponent` is the payload's
    /// own statement of the scale; this never guesses one beyond the caller's
    /// documented default.
    static func scaled(_ minorUnits: Int, exponent: Int) -> Decimal? {
        guard (0...9).contains(exponent) else { return nil }
        var result = Decimal(minorUnits)
        for _ in 0..<exponent { result /= 10 }
        return result
    }

    /// Anthropic's monthly API credit, from whichever block this endpoint
    /// served. Nil when neither carried a usable figure, or when the payload
    /// stated no scale to read its minor units in.
    ///
    /// The newer `spend` block is preferred, but only when it can actually be
    /// read. A `spend` block that is present and unusable — off, without a
    /// readable amount, or without a currency — must not hide the older
    /// `extra_usage` block the same payload may still carry: this endpoint has
    /// served both at once during its rollover, and returning nil on the
    /// unusable newer one discarded a figure the payload did publish. The
    /// block that answered is reported as `source`, so the row is not left
    /// claiming a provenance it did not use. Each block's own `enabled` /
    /// `is_enabled` still gates the entry, so an explicitly off `spend` block
    /// only means that block reports nothing — it is not a reading of the
    /// account, and `extra_usage` is then the reading, if it is on.
    public var monthlyCredit: MoneyCredit? {
        if let spend = spendBlock,
           spend.enabled == true,
           let used = spend.used?.majorUnits,
           let code = spend.limit?.currency ?? spend.used?.currency {
            // The newer block declares its own exponent per amount, so it
            // needs no default scale.
            return MoneyCredit(
                used: used, limit: spend.limit?.majorUnits,
                currencyCode: code, source: .spend
            )
        }
        if let extra = extraUsage {
            guard extra.isEnabled == true,
                  let usedMinor = extra.usedCredits,
                  usedMinor >= 0
            else { return nil }
            // 2 (cents) unless the payload says otherwise — see `MoneyCredit`.
            let exponent = extra.decimalPlaces ?? 2
            guard let used = Self.scaled(usedMinor, exponent: exponent) else { return nil }
            let limit = extra.monthlyLimit.flatMap { $0 >= 0 ? Self.scaled($0, exponent: exponent) : nil }
            return MoneyCredit(
                used: used, limit: limit,
                currencyCode: (extra.currency?.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? "USD",
                source: .extraUsage
            )
        }
        return nil
    }

    /// One banked usage-limit reset Anthropic has granted the account.
    ///
    /// Served under the `cedar_ember` key — an Anthropic feature codename,
    /// requested with `?cedar_ember=1` — which the claude.ai web UI reads to
    /// draw its "Limit resets" panel. As of October 2026 the OAuth surface
    /// FrugalBar authenticates with answers `eligible: false,
    /// ineligible_reason: "surface"` with an empty `grants` list, so this
    /// decodes to nothing for a CLI login. It is parsed anyway so the row and
    /// the reset-credit event light up the day Anthropic opens the surface,
    /// and shows nothing until then — never a 0 standing in for "not served".
    public struct ResetGrant: Decodable, Sendable, Equatable {
        public let id: String?
        public let label: String?
        public let resetsLeft: Int?
        public let resetsTotal: Int?
        /// The windows one use clears, e.g. `["five_hour", "seven_day"]`. A
        /// grant that clears `seven_day` is a "full reset" in the web UI; one
        /// that clears only `five_hour` is a "5-hour reset".
        public let clears: [String]?
        public let usableNow: Bool?
        public let endsAt: String?

        public init(id: String?, label: String?, resetsLeft: Int?, resetsTotal: Int?,
                    clears: [String]?, usableNow: Bool?, endsAt: String?) {
            self.id = id
            self.label = label
            self.resetsLeft = resetsLeft
            self.resetsTotal = resetsTotal
            self.clears = clears
            self.usableNow = usableNow
            self.endsAt = endsAt
        }

        enum CodingKeys: String, CodingKey {
            case id, label, clears
            case resetsLeft = "resets_left"
            case resetsTotal = "resets_total"
            case usableNow = "usable_now"
            case endsAt = "ends_at"
        }
    }

    /// The `cedar_ember` block. `grants` is empty both when the account holds
    /// no reset and when the surface is not served one, so `eligible` is
    /// kept to tell the two apart in logs; neither is turned into a figure.
    public struct ResetGrants: Decodable, Sendable, Equatable {
        public let eligible: Bool?
        public let ineligibleReason: String?
        public let grants: [ResetGrant]

        public init(eligible: Bool?, ineligibleReason: String?, grants: [ResetGrant]) {
            self.eligible = eligible
            self.ineligibleReason = ineligibleReason
            self.grants = grants
        }

        enum CodingKeys: String, CodingKey {
            case eligible, grants
            case ineligibleReason = "ineligible_reason"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            eligible = try? container.decodeIfPresent(Bool.self, forKey: .eligible)
            ineligibleReason = try? container.decodeIfPresent(String.self, forKey: .ineligibleReason)
            // One malformed grant must not hide the others.
            grants = (try? container.decodeIfPresent([LenientGrant].self, forKey: .grants))?
                .compactMap(\.grant) ?? []
        }

        private struct LenientGrant: Decodable {
            let grant: ResetGrant?
            init(from decoder: Decoder) throws {
                grant = try? ResetGrant(from: decoder)
            }
        }

        /// Banked resets the vendor says the account holds, summed over
        /// grants. `nil` when there are no grants at all — including the
        /// not-served case — because "no figure" and "zero" are different.
        public var resetsAvailable: Int? {
            // Every grant must carry its count. A grant without one (a
            // renamed field, say) makes the sum unknowable; summing the rest
            // would print a figure nobody published.
            guard !grants.isEmpty, grants.allSatisfy({ $0.resetsLeft != nil }) else { return nil }
            return grants.reduce(0) { $0 + ($1.resetsLeft ?? 0) }
        }

        /// Of those, the ones the vendor flags as usable right now.
        public var resetsUsableNow: Int? {
            guard resetsAvailable != nil else { return nil }
            return grants.filter { $0.usableNow == true }.reduce(0) { $0 + ($1.resetsLeft ?? 0) }
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    /// Model-scoped weekly windows. Only some plans report them, and they
    /// arrive as `null` otherwise.
    public let sevenDayOpus: Window?
    public let sevenDaySonnet: Window?
    /// Banked reset grants, when the surface is served them. See `ResetGrant`.
    public let resetGrants: ResetGrants?
    /// The pay-as-you-go credit pool, in whichever of its two shapes this
    /// endpoint served. Both decoded leniently; `monthlyCredit` picks between
    /// them. Nil is "not published", never "zero".
    public let spendBlock: SpendBlock?
    public let extraUsage: ExtraUsage?
    /// Anthropic's promo / cloud-session credit. See `PromoCredit`.
    public let promoCredit: PromoCredit?

    public init(
        fiveHour: Window? = nil,
        sevenDay: Window? = nil,
        sevenDayOpus: Window? = nil,
        sevenDaySonnet: Window? = nil,
        resetGrants: ResetGrants? = nil,
        spendBlock: SpendBlock? = nil,
        extraUsage: ExtraUsage? = nil,
        promoCredit: PromoCredit? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.resetGrants = resetGrants
        self.spendBlock = spendBlock
        self.extraUsage = extraUsage
        self.promoCredit = promoCredit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Each window decodes independently: one reshaped window must not
        // discard the others. `makeSnapshot` reports a bad response only when
        // neither primary window is usable.
        fiveHour = try? container.decodeIfPresent(Window.self, forKey: .fiveHour)
        sevenDay = try? container.decodeIfPresent(Window.self, forKey: .sevenDay)
        sevenDayOpus = try? container.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try? container.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
        resetGrants = try? container.decodeIfPresent(ResetGrants.self, forKey: .resetGrants)
        // Each money block is decoded independently and leniently too: a
        // reshaped `spend` must not cost the row its reset grants, and a
        // credit block is one figure among several rather than the reading.
        spendBlock = try? container.decodeIfPresent(SpendBlock.self, forKey: .spendBlock)
        extraUsage = try? container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        promoCredit = try? container.decodeIfPresent(PromoCredit.self, forKey: .promoCredit)
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case resetGrants = "cedar_ember"
        case spendBlock = "spend"
        case extraUsage = "extra_usage"
        case promoCredit = "iguana_necktie"
    }
}

/// Client for discovering CLIProxyAPI hubs and querying account usage via its management API.
public enum CLIProxyClient {

    /// Anthropic's OAuth usage endpoint. Reading it is free, unlike a
    /// messages request, which spends the quota it reports on.
    public static let claudeOAuthUsageURL = "https://api.anthropic.com/api/oauth/usage"
    /// The same endpoint asked to include banked reset grants. A feature
    /// flag, not a credential, so it may travel in the query string.
    public static let claudeOAuthUsageWithGrantsURL = claudeOAuthUsageURL + "?cedar_ember=1"

    /// How long to hold off the automatic poll after Anthropic throttles the
    /// usage endpoint without saying for how long.
    ///
    /// Anthropic answers a throttle with `Retry-After: 0`, and a non-positive
    /// delta is "no instruction" to `QuotaHTTP.retryAfterDate` — so the poll
    /// loop re-asked every 120 s for the whole ~40-minute window the account
    /// spends throttled, and each ask is itself a request against a budget the
    /// account shares with Claude Code. Claude Code, the client whose own reads
    /// this endpoint serves, answers the same status with a five-minute
    /// cooldown; this is that figure, not a guess.
    public static let claudeUsageRateLimitFloor: TimeInterval = 300

    /// The ceiling on a vendor-requested cooldown. Claude Code clamps the same
    /// way, so an hour-long `Retry-After` cannot park the row for a day.
    public static let claudeUsageCooldownCap: TimeInterval = 3600

    /// When the usage endpoint may be asked again after a throttle.
    ///
    /// The vendor's own `Retry-After` wins when it asked for a positive
    /// interval, clamped to `claudeUsageCooldownCap`; otherwise the floor
    /// applies. Either way the answer is a real instant, which is what gives
    /// `QuotaManager` something to hold the *automatic* poll behind — the user's
    /// own ⟳ still goes out, because swallowing their click is the dead-button
    /// bug #90 fixed.
    public static func claudeUsageCooldown(retryAfter raw: String?, now: Date = Date()) -> Date {
        let asked = QuotaHTTP.retryAfterDate(secondsHeader: raw, now: now)
            .map { $0.timeIntervalSince(now) } ?? 0
        let seconds = asked > 0 ? min(asked, claudeUsageCooldownCap) : claudeUsageRateLimitFloor
        return now.addingTimeInterval(seconds)
    }

    /// Maps the usage endpoint's status to a failure reason, under Claude
    /// Code's own policy.
    ///
    /// Deliberately not `QuotaHTTP.failureReason`, which is the right rule for
    /// an *API key* surface: there a 403 is a key that cannot call the endpoint
    /// and 401/403 both mean "fix the credential". Anthropic's OAuth usage
    /// endpoint instead uses 403 as a throttle — a working token being held
    /// back — and `QuotaManager` exempts `credentialRejected` from the poll
    /// floor, so reading a throttle as a bad credential re-asked forever and
    /// told the user to check a key that was fine. Both 403 and 429 are
    /// therefore rate limits here, carrying a cooldown from
    /// `claudeUsageCooldown`.
    public static func claudeUsageFailureReason(
        for status: Int, retryAfter raw: String? = nil, now: Date = Date()
    ) -> UnavailableReason? {
        switch status {
        case 200...299: nil
        case 401:       .credentialRejected
        case 403, 429:  .rateLimited(retryAfter: claudeUsageCooldown(retryAfter: raw, now: now))
        default:        .badResponse
        }
    }

    public static func base64url(string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    public static func parseResetDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: string) {
            return date
        }
        let custom = DateFormatter()
        custom.locale = Locale(identifier: "en_US_POSIX")
        custom.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
        if let date = custom.date(from: string) {
            return date
        }
        custom.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return custom.date(from: string)
    }

    public static func managementURL(path: String, base: URL) -> String {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents()
        components.scheme = base.scheme ?? "http"
        components.host = base.host
        components.port = base.port
        components.path = "/v0/management/\(cleanPath)"
        if let url = components.url {
            return url.absoluteString
        }
        let scheme = base.scheme ?? "http"
        let host = base.host ?? "localhost"
        let portPart = base.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portPart)/v0/management/\(cleanPath)"
    }

    static func discoverConfig(
        settingsURL: URL? = nil,
        storeDir: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isCLIDiscoveryEnabled: Bool = CredentialStore.isCLIDiscoveryEnabled,
        isTestHost: Bool = TestHost.isActive
    ) -> CLIProxyConfig? {
        // 1. Environment variables
        if let rawUrl = environment["CLIPROXY_URL"] ?? environment["FRUGALBAR_CLIPROXY_URL"],
           let url = URL(string: rawUrl),
           let key = environment["CLIPROXY_API_KEY"] ?? environment["FRUGALBAR_CLIPROXY_KEY"],
           !key.isEmpty {
            return CLIProxyConfig(url: url, managementKey: key, label: "Environment")
        }

        // 2. Preferences / Keychain
        if let prefUrl = CredentialStore.preferences.string(forKey: "QuotaBarCLIProxyURL"),
           let url = URL(string: prefUrl) {
            let key = (try? KeychainManager.shared.get(label: "cliproxy")) ?? CredentialStore.preferences.string(forKey: "QuotaBarCLIProxyKey")
            if let key, !key.isEmpty {
                return CLIProxyConfig(url: url, managementKey: key, label: "Preferences")
            }
        }

        // 3. ~/.t3/userdata/settings.json
        guard isCLIDiscoveryEnabled else { return nil }
        if isTestHost && settingsURL == nil {
            return nil
        }

        let defaultSettingsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".t3/userdata/settings.json")
        let targetSettingsURL = settingsURL ?? defaultSettingsURL

        guard let data = try? Data(contentsOf: targetSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = json["usageLimitSources"] as? [String: Any]
        else {
            return nil
        }

        let defaultStoragePath = [".t3", "userdata", "secrets"].joined(separator: "/")
        let defaultStoreDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(defaultStoragePath)
        let targetStoreDir = storeDir ?? defaultStoreDir

        for (sourceId, value) in sources {
            guard let sourceDict = value as? [String: Any],
                  sourceDict["kind"] as? String == "cliproxy",
                  sourceDict["enabled"] as? Bool != false,
                  let urlString = sourceDict["url"] as? String,
                  let url = URL(string: urlString)
            else { continue }

            let label = sourceDict["label"] as? String
            var managementKey = (sourceDict["managementKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let redactedMarker = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
            if managementKey == nil || managementKey == redactedMarker || managementKey?.isEmpty == true {
                let recordFileName = "usage-limit-source-\(base64url(string: sourceId)).bin"
                let recordFile = targetStoreDir.appendingPathComponent(recordFileName)
                if let recordData = try? Data(contentsOf: recordFile),
                   let recordText = String(data: recordData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !recordText.isEmpty {
                    managementKey = recordText
                }
            }

            if let key = managementKey, !key.isEmpty, key != redactedMarker {
                return CLIProxyConfig(url: url, managementKey: key, label: label ?? "CLI Proxy")
            }
        }

        return nil
    }

    private struct AuthFilesWrapper: Decodable {
        let files: [CLIProxyAuthFile]
    }

    public static func decodeAuthFiles(from data: Data) throws -> [CLIProxyAuthFile] {
        if let wrapper = try? JSONDecoder().decode(AuthFilesWrapper.self, from: data) {
            return wrapper.files
        }
        return try JSONDecoder().decode([CLIProxyAuthFile].self, from: data)
    }

    private struct APICallWrapper: Decodable {
        let statusCode: Int
        let body: String
        /// The upstream response's headers, as the proxy relays them.
        ///
        /// Only `Retry-After` is read, and it is enrichment: the status code is
        /// what says a 429 happened, so a header shape we did not anticipate
        /// must cost the retry time, never the reason. Decoded leniently for
        /// exactly that reason.
        let header: [String: HeaderValues]?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case body, header
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            statusCode = try c.decode(Int.self, forKey: .statusCode)
            body = try c.decode(String.self, forKey: .body)
            header = try? c.decodeIfPresent([String: HeaderValues].self, forKey: .header)
        }

        /// The vendor's own backoff instruction, relayed verbatim. Header
        /// names are case-insensitive, so the lookup is too — the proxy
        /// reproduces the vendor's own casing, which varies.
        var retryAfterHeader: String? {
            header?.first { $0.key.lowercased() == "retry-after" }?.value.values.first
        }
    }

    /// One relayed header. The proxy serialises its `http.Header` map as arrays
    /// of values; a plain string is accepted too so a proxy that flattens them
    /// still yields the value instead of an empty list.
    private struct HeaderValues: Decodable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([String].self) {
                values = list
            } else if let single = try? container.decode(String.self) {
                values = [single]
            } else {
                values = []
            }
        }
    }

    public static func decodeClaudeUsage(from data: Data, now: Date = Date()) throws -> ClaudeOAuthUsageResponse {
        if let wrapper = try? JSONDecoder().decode(APICallWrapper.self, from: data) {
            // The wrapper carries Anthropic's own answer to the usage request,
            // so it is read under Claude's policy rather than the API-key one:
            // a relayed 403 is a throttle, not a rejected credential.
            if let reason = claudeUsageFailureReason(
                for: wrapper.statusCode, retryAfter: wrapper.retryAfterHeader, now: now) {
                throw ProviderError(reason)
            }
            guard let innerData = wrapper.body.data(using: .utf8) else {
                throw ProviderError.badResponse
            }
            return try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: innerData)
        }
        return try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
    }

    public static func fetchClaudeUsage(
        config: CLIProxyConfig, now: Date = Date()
    ) async throws -> (ClaudeOAuthUsageResponse, CLIProxyAuthFile) {
        let authFilesURL = managementURL(path: "auth-files", base: config.url)
        let (authData, authResponse) = try await QuotaHTTP.get(
            url: authFilesURL,
            headers: ["Accept": "application/json"],
            auth: .bearer(config.managementKey)
        )
        if let reason = QuotaHTTP.failureReason(
            for: authResponse.statusCode,
            retryAfter: authResponse.value(forHTTPHeaderField: "Retry-After"), now: now) {
            throw ProviderError(reason)
        }

        let files = try decodeAuthFiles(from: authData)
        guard let claudeAccount = files.first(where: {
            ($0.disabled != true) && $0.provider.lowercased() == "claude"
        }) else {
            throw ProviderError(.notConfigured)
        }

        let apiCallURL = managementURL(path: "api-call", base: config.url)
        let payload: [String: Any] = [
            "auth_index": claudeAccount.authIndex,
            "method": "GET",
            "url": claudeOAuthUsageWithGrantsURL,
            "header": [
                "Authorization": "Bearer $TOKEN$",
                "anthropic-beta": "oauth-2025-04-20"
            ]
        ]
        let requestBody = try JSONSerialization.data(withJSONObject: payload)
        let (apiCallData, apiCallResponse) = try await QuotaHTTP.post(
            url: apiCallURL,
            body: requestBody,
            headers: ["Content-Type": "application/json"],
            auth: .bearer(config.managementKey)
        )
        if let reason = QuotaHTTP.failureReason(
            for: apiCallResponse.statusCode,
            retryAfter: apiCallResponse.value(forHTTPHeaderField: "Retry-After"), now: now) {
            throw ProviderError(reason)
        }

        let usage = try decodeClaudeUsage(from: apiCallData, now: now)
        return (usage, claudeAccount)
    }

    public static func decodeCodexUsage(from data: Data, now: Date = Date()) throws -> OpenAIQuotaProvider.Response {
        if let wrapper = try? JSONDecoder().decode(APICallWrapper.self, from: data) {
            if let reason = QuotaHTTP.failureReason(
                for: wrapper.statusCode, retryAfter: wrapper.retryAfterHeader, now: now) {
                throw ProviderError(reason)
            }
            guard let innerData = wrapper.body.data(using: .utf8) else {
                throw ProviderError.badResponse
            }
            return try JSONDecoder().decode(OpenAIQuotaProvider.Response.self, from: innerData)
        }
        return try JSONDecoder().decode(OpenAIQuotaProvider.Response.self, from: data)
    }

    public static func fetchCodexUsage(
        config: CLIProxyConfig, now: Date = Date()
    ) async throws -> (OpenAIQuotaProvider.Response, CLIProxyAuthFile) {
        let authFilesURL = managementURL(path: "auth-files", base: config.url)
        let (authData, authResponse) = try await QuotaHTTP.get(
            url: authFilesURL,
            headers: ["Accept": "application/json"],
            auth: .bearer(config.managementKey)
        )
        if let reason = QuotaHTTP.failureReason(
            for: authResponse.statusCode,
            retryAfter: authResponse.value(forHTTPHeaderField: "Retry-After"), now: now) {
            throw ProviderError(reason)
        }

        let files = try decodeAuthFiles(from: authData)
        guard let codexAccount = files.first(where: {
            ($0.disabled != true) && ($0.provider.lowercased() == "codex" || $0.provider.lowercased() == "openai")
        }) else {
            throw ProviderError(.notConfigured)
        }

        let apiCallURL = managementURL(path: "api-call", base: config.url)
        var headers: [String: String] = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "OpenAI-Beta": "codex-1",
            "Originator": "Codex Desktop",
        ]
        if let accountId = codexAccount.idToken?.chatgptAccountId {
            headers["Chatgpt-Account-Id"] = accountId
        }

        let payload: [String: Any] = [
            "auth_index": codexAccount.authIndex,
            "method": "GET",
            "url": "https://chatgpt.com/backend-api/wham/usage",
            "header": headers,
        ]
        let requestBody = try JSONSerialization.data(withJSONObject: payload)
        let (apiCallData, apiCallResponse) = try await QuotaHTTP.post(
            url: apiCallURL,
            body: requestBody,
            headers: ["Content-Type": "application/json"],
            auth: .bearer(config.managementKey)
        )
        if let reason = QuotaHTTP.failureReason(
            for: apiCallResponse.statusCode,
            retryAfter: apiCallResponse.value(forHTTPHeaderField: "Retry-After"), now: now) {
            throw ProviderError(reason)
        }

        let usage = try decodeCodexUsage(from: apiCallData, now: now)
        return (usage, codexAccount)
    }
}
