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
    private let cliProxyConfig: CLIProxyConfig?

    public init(accessToken: String? = nil, accountID: String? = nil, cliProxyConfig: CLIProxyConfig? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.cliProxyConfig = cliProxyConfig
    }

    public struct Response: Decodable, Sendable, Equatable {
        public struct RateLimit: Decodable, Sendable, Equatable {
            public struct Window: Decodable, Sendable, Equatable {
                public let used_percent: Double?
                public let reset_at: TimeInterval?
                public let limit_window_seconds: Double?

                public init(used_percent: Double? = nil, reset_at: TimeInterval? = nil, limit_window_seconds: Double? = nil) {
                    self.used_percent = used_percent
                    self.reset_at = reset_at
                    self.limit_window_seconds = limit_window_seconds
                }
            }
            public let primary_window: Window?
            public let secondary_window: Window?

            public init(primary_window: Window? = nil, secondary_window: Window? = nil) {
                self.primary_window = primary_window
                self.secondary_window = secondary_window
            }
        }
        /// Codex's credit balance block. Every field optional and decoded
        /// leniently: anything unrecognised is nil.
        ///
        /// `balance` is a string of *unverified unit* — a live Pro account
        /// reported "62500", which is not plausibly dollars. It is decoded so
        /// the payload round-trips, but must never be displayed as money (or
        /// at all) until the unit is known: a figure under the wrong label is
        /// the same defect as an invented one.
        public struct Credits: Decodable, Sendable, Equatable {
            public let has_credits: Bool?
            public let unlimited: Bool?
            public let balance: String?

            public init(has_credits: Bool? = nil, unlimited: Bool? = nil, balance: String? = nil) {
                self.has_credits = has_credits
                self.unlimited = unlimited
                self.balance = balance
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: LenientKey.self)
                has_credits = c.lenientBool("has_credits")
                unlimited = c.lenientBool("unlimited")
                balance = c.lenientString("balance")
            }
        }

        /// Banked "reset my limits" credits the user can redeem in Codex.
        ///
        /// `available_count` is the banked total; `applicable_available_count`
        /// is how many can be redeemed against the current window state (a
        /// live account showed 2 banked, 0 redeemable).
        public struct ResetCredits: Decodable, Sendable, Equatable {
            public let available_count: Int?
            public let applicable_available_count: Int?

            public init(available_count: Int? = nil, applicable_available_count: Int? = nil) {
                self.available_count = available_count
                self.applicable_available_count = applicable_available_count
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: LenientKey.self)
                available_count = c.lenientInt("available_count")
                applicable_available_count = c.lenientInt("applicable_available_count")
            }
        }

        public let plan_type: String?
        public let rate_limit: RateLimit?
        public let credits: Credits?
        public let rate_limit_reset_credits: ResetCredits?

        public init(
            plan_type: String? = nil,
            rate_limit: RateLimit? = nil,
            credits: Credits? = nil,
            rate_limit_reset_credits: ResetCredits? = nil
        ) {
            self.plan_type = plan_type
            self.rate_limit = rate_limit
            self.credits = credits
            self.rate_limit_reset_credits = rate_limit_reset_credits
        }

        private enum CodingKeys: String, CodingKey {
            case plan_type, rate_limit, credits, rate_limit_reset_credits
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plan_type = try c.decodeIfPresent(String.self, forKey: .plan_type)
            rate_limit = try c.decodeIfPresent(RateLimit.self, forKey: .rate_limit)
            // The credit blocks are enrichment. A shape we did not anticipate
            // must cost only the enrichment (nil), never the usage windows —
            // a decode failure here would otherwise turn a perfectly good
            // reading into `.badResponse`.
            credits = (try? c.decodeIfPresent(Credits.self, forKey: .credits)) ?? nil
            rate_limit_reset_credits = (try? c.decodeIfPresent(
                ResetCredits.self, forKey: .rate_limit_reset_credits)) ?? nil
        }
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        try await fetchSnapshot(now: Date())
    }

    func fetchSnapshot(now: Date) async throws -> QuotaSnapshot {
        if let injectedToken = accessToken, !injectedToken.isEmpty {
            return try await fetchSnapshotDirect(token: injectedToken, now: now)
        }
        if accessToken != nil {
            return unavailable(.notConfigured)
        }

        let proxyConfig = cliProxyConfig ?? (TestHost.isActive ? nil : CLIProxyClient.discoverConfig())
        if let proxyConfig {
            do {
                return try await fetchSnapshotViaProxy(config: proxyConfig, now: now)
            } catch let error as ProviderError {
                if error.reason == .credentialRejected || error.reason == .rateLimited(retryAfter: nil) {
                    return unavailable(error.reason)
                }
            } catch {
                // Fall through to direct credential check
            }
        }

        guard let token = await credential(injected: nil, for: .openai) else {
            return unavailable(.notConfigured)
        }
        return try await fetchSnapshotDirect(token: token, now: now)
    }

    private func fetchSnapshotViaProxy(config: CLIProxyConfig, now: Date) async throws -> QuotaSnapshot {
        let (response, account) = try await CLIProxyClient.fetchCodexUsage(config: config)
        let host = config.url.host ?? "proxy"
        let accountPlan = account.idToken?.chatgptPlanType ?? account.idToken?.planType
        return makeSnapshot(
            response: response,
            accountPlan: accountPlan,
            cliSource: "CLI Proxy (\(host))",
            now: now
        )
    }

    private func fetchSnapshotDirect(token: String, now: Date) async throws -> QuotaSnapshot {
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
        return makeSnapshot(
            response: response,
            accountPlan: nil,
            cliSource: "Codex ChatGPT login",
            now: now
        )
    }

    func makeSnapshot(
        response: Response,
        accountPlan: String?,
        cliSource: String,
        now: Date = Date()
    ) -> QuotaSnapshot {
        // Both windows are real subscription limits: `primary_window` is the
        // 5-hour session window and `secondary_window` the weekly one. Showing
        // only the first — under a label that named neither — is how a weekly
        // quota came to be drawn as "PLAN" with the 5-hour window missing.
        let windows = [response.rate_limit?.primary_window, response.rate_limit?.secondary_window]
            .compactMap { $0 }
            .compactMap { Self.reading($0, now: now) }
        guard let worst = windows.map(\.used).max() else { return unavailable(.badResponse) }

        // Badge and urgency both come from the fullest window, so the menu bar
        // and the row can never disagree about which limit is binding.
        let urgency: Urgency = worst > 0.90 ? .critical : worst > 0.70 ? .warning : .none
        // An unread plan is nil, not the vendor's name wearing a tier's
        // clothes. `shortPlanName` renders nil as nothing at all.
        let plan = response.plan_type?.capitalized ?? accountPlan?.capitalized

        // The vendor's own count, or nil when the payload carried none —
        // never 0 standing in for "not reported".
        let resetCredits = response.rate_limit_reset_credits?.available_count
        let applicableCredits = response.rate_limit_reset_credits?.applicable_available_count

        var snapshot = QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: plan ?? displayName, renewalDate: nil),
            status: .measured(urgency), resetsAt: windows.first?.reset, lastUpdated: now,
            auxiliaryInfo: Self.auxiliaryInfo(resetCredits: resetCredits, applicable: applicableCredits),
            row1: windows[safe: 0].map { Self.row($0, now: now) },
            row2: windows[safe: 1].map { Self.row($0, now: now) },
            badgeText: "\(Int(((1 - worst) * 100).rounded()))% left", planName: plan,
            cliSource: cliSource
        )
        snapshot.resetCreditsAvailable = resetCredits
        snapshot.resetCreditsApplicable = applicableCredits
        return snapshot
    }

    /// The row's note. Mentions banked reset credits only when OpenAI
    /// reported at least one: "0 banked" is noise on every account that never
    /// had any, and an absent count says nothing at all. The redeemable count
    /// is added only when positive, for the same reason.
    static func auxiliaryInfo(resetCredits: Int?, applicable: Int? = nil) -> String {
        let base = "Live ChatGPT subscription quota"
        guard let count = resetCredits, count > 0 else { return base }
        var text = "\(base) · \(count) reset credit\(count == 1 ? "" : "s") banked"
        if let applicable, applicable > 0 {
            text += " · \(applicable) redeemable now"
        }
        return text
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

    private static func reading(_ window: Response.RateLimit.Window, now: Date = Date()) -> Reading? {
        guard let percent = window.used_percent, (0...100).contains(percent) else { return nil }
        let reset = window.reset_at.map { Date(timeIntervalSince1970: $0) }
        return Reading(
            used: percent / 100,
            reset: reset,
            label: label(forWindowSeconds: window.limit_window_seconds),
            pace: window.limit_window_seconds.flatMap {
                DualBarMetrics.proRataPace(resetsAt: reset, windowLength: $0, now: now)
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

    private static func row(_ reading: Reading, now: Date = Date()) -> DualBarMetrics {
        DualBarMetrics(
            primaryFraction: reading.used, expectedPaceFraction: reading.pace,
            label: reading.label,
            usedText: "\(Int((reading.used * 100).rounded()))% used",
            resetText: reading.reset.map { resetText($0, now: now) },
            resetsAt: reading.reset, windowLength: reading.windowSeconds
        )
    }

    private static func resetText(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Resets \(formatter.localizedString(for: date, relativeTo: now))"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Any-string coding key, for payload blocks decoded field by field.
struct LenientKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Field readers that accept the shapes a vendor plausibly sends for one
/// value — a number as a JSON number or as a string, a flag as a bool or as
/// "true"/"1" — and yield nil for anything else. Never a default: an
/// unrecognised value is "not reported", not zero or false.
extension KeyedDecodingContainer where Key == LenientKey {
    func lenientInt(_ name: String) -> Int? {
        let key = LenientKey(stringValue: name)
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key),
           value.isFinite, value.rounded() == value, abs(value) < Double(Int32.max) {
            return Int(value)
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func lenientBool(_ name: String) -> Bool? {
        let key = LenientKey(stringValue: name)
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value == 1 ? true : value == 0 ? false : nil
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    func lenientString(_ name: String) -> String? {
        let key = LenientKey(stringValue: name)
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Decimal.self, forKey: key) { return "\(value)" }
        return nil
    }
}
