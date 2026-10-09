import Foundation

/// DeepSeek platform credit provider — `GET /user/balance`.
///
/// DeepSeek sells prepaid credit: you top up, and usage draws the balance
/// down. The public API exposes exactly one billing figure, the account's
/// remaining balance, denominated in the account's own currency (CNY or USD).
/// It publishes no spend-per-window and no cap, so this row is a balance and
/// never a gauge: `limit` stays nil and there is no denominator to draw a bar
/// against.
///
/// `is_available` is the vendor's own statement about whether the balance can
/// fund a call right now. It is authoritative for the critical band, so it is
/// used as the signal rather than inferred from the amount.
public final class DeepSeekProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .deepseek
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .apiSpendAndCredits

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let key = await credential(injected: apiKey, for: .deepseek) else {
            return unavailable(.notConfigured)
        }

        let (data, http) = try await QuotaHTTP.get(
            url: "https://api.deepseek.com/user/balance",
            headers: ["Accept": "application/json"],
            auth: .bearer(key)
        )

        if http.statusCode == 429 {
            // A 429 on this metadata endpoint tells us nothing about the
            // balance, so it is an absent reading rather than a critical quota.
            return unavailable(.rateLimited(retryAfter: Self.retryAfter(from: http)))
        }
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
            return unavailable(reason)
        }

        guard let decoded = Self.parse(data) else {
            return unavailable(.badResponse)
        }
        return Self.snapshot(from: decoded, provider: self)
    }

    private static func retryAfter(from http: HTTPURLResponse) -> Date? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    // MARK: - Response shape

    /// `balance_infos` is an array because the platform keys each balance by
    /// currency. A normal account carries exactly one; the first is used, and
    /// an entry without a currency or a readable total is not a reading.
    struct BalanceResponse: Decodable, Sendable {
        struct BalanceInfo: Decodable, Sendable {
            let currency: String?
            let total_balance: DecimalValue?
            let granted_balance: DecimalValue?
            let topped_up_balance: DecimalValue?
        }
        let is_available: Bool?
        let balance_infos: [BalanceInfo]?
    }

    /// A decimal the platform sends as a quoted string (e.g. `"110.00"`). Also
    /// accepts a bare JSON number, so a future response that stops quoting them
    /// still decodes.
    struct DecimalValue: Decodable, Sendable {
        let decimalValue: Decimal?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                decimalValue = nil
            } else if let text = try? container.decode(String.self) {
                decimalValue = Decimal(string: text.trimmed)
            } else if let number = try? container.decode(Double.self) {
                decimalValue = number.isFinite ? Decimal(number) : nil
            } else {
                decimalValue = nil
            }
        }
    }

    static func parse(_ data: Data) -> BalanceResponse? {
        try? JSONDecoder().decode(BalanceResponse.self, from: data)
    }

    /// Builds the snapshot from a decoded body. Split from the network call so
    /// every branch is tested without one, and with an explicit `now` so no
    /// assertion depends on the wall clock.
    static func snapshot(
        from response: BalanceResponse,
        provider: DeepSeekProvider,
        now: Date = Date()
    ) -> QuotaSnapshot {
        guard let info = response.balance_infos?.first,
              let currency = info.currency?.trimmed, !currency.isEmpty,
              let total = info.total_balance?.decimalValue
        else {
            return provider.unavailable(.badResponse)
        }
        let code = currency.uppercased()

        // The vendor's own yes/no about whether a call can be made right now is
        // authoritative for "critical". With no cap and no period published,
        // the balance alone has no denominator to derive a percentage from, so
        // the low-balance bands below are a UI floor, not a measured quota.
        let urgency: Urgency = response.is_available == false
            ? .critical
            : lowBalanceUrgency(total: total, currency: code)

        return QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .currency(balance: total, limit: nil, spent: nil, currencyCode: code),
            status: .measured(urgency),
            resetsAt: nil,
            lastUpdated: now,
            auxiliaryInfo: auxiliaryInfo(for: info, currency: code),
            row1: nil,
            row2: nil,
            badgeText: response.is_available == false
                ? "Insufficient balance"
                : "\(format(total, currencyCode: code)) credit",
            planName: nil,
            cliSource: "DEEPSEEK_API_KEY / auth.json",
            currencyBasis: .accountCredit
        )
    }

    /// Low-balance floors, in the balance's own currency.
    ///
    /// These are UI bands, not a measured allowance: DeepSeek publishes no cap
    /// to measure against, so the only figures are the balance and the
    /// vendor's `is_available` flag. A currency we have no band for is left to
    /// `is_available` alone rather than judged against a guessed threshold.
    static func lowBalanceUrgency(total: Decimal, currency: String) -> Urgency {
        let bands: (warning: Decimal, critical: Decimal)
        switch currency.trimmed.uppercased() {
        case "USD": bands = (5, 1)
        case "CNY": bands = (35, 7)
        default:    return .none
        }
        if total < bands.critical { return .critical }
        if total < bands.warning  { return .warning }
        return .none
    }

    /// "Account credit balance · $10.00 granted, $100.00 topped up" — the
    /// composition is real and worth knowing (granted credit expires), but it
    /// is only stated when the platform sent both parts.
    static func auxiliaryInfo(for info: BalanceResponse.BalanceInfo, currency: String) -> String {
        guard let granted = info.granted_balance?.decimalValue,
              let topped = info.topped_up_balance?.decimalValue
        else { return "Account credit balance" }
        let parts = [
            "\(format(granted, currencyCode: currency)) granted",
            "\(format(topped, currencyCode: currency)) topped up",
        ]
        return "Account credit balance · " + parts.joined(separator: ", ")
    }

    static func format(_ amount: Decimal, currencyCode: String) -> String {
        amount.formatted(.currency(code: currencyCode).precision(.fractionLength(2)))
    }
}
