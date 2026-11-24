import Foundation

/// The prepaid Gemini API credit for a Google AI Studio key's Cloud Billing
/// account, as recorded by the account holder.
///
/// The balance belongs to the billing account, not the key: every project and
/// key on that account draws on the same prepay funds and the same monthly
/// grant, so FrugalBar records it once rather than per key.
///
/// No documented API returns this figure. AI Studio manages and reports its
/// Prepay balance only in its own Billing tab; the Gemini API key surface
/// (`generativelanguage.googleapis.com`) serves models and generation, not
/// billing; and the Cloud Billing API exposes billing accounts, budgets and SKU
/// prices but no prepay credit balance. An API key cannot read its own spend or
/// credit, so FrugalBar cannot measure it. Returning an invented 0 would be
/// worse than showing nothing, which is why the figure is only ever the one the
/// user typed in — and why every surface calls it *configured*.
///
/// Deliberately not an `APICreditEntry`. That type rides a snapshot's measured
/// fetch, and `BalanceSeries` charts each entry it carries: a configured number
/// would become a vendor balance-history point it never was. This field lives
/// outside `apiCredits`, so it cannot reach `consumptionFraction`, the urgency
/// bands, exhaustion sorting, the advice engine, the menu bar icon, the widget's
/// average or any balance series. The popover draws only the spend cap, as an
/// "API credit" line with a calendar-month progress meter
/// (`GeminiAPICreditPresentation.Budget`); the prepaid balance and monthly
/// grant stay in Settings and are not drawn. The meter's fill is elapsed
/// calendar time, never spend, because no documented API returns an API key's
/// spend and dividing the prepaid balance into the cap would mix two pools.
/// That meter is presentation-only and outside every quota calculation.
public struct GeminiAPICredit: Codable, Equatable, Sendable {

    /// The billing account's own currency, e.g. "AUD". One code applies to all
    /// three figures because they are one account's money; no amount is ever
    /// converted between currencies.
    public let currencyCode: String

    /// The prepay balance AI Studio reports, after credits have been drawn
    /// down. Zero is a real reading of an empty prepay account, and a negative
    /// figure is the ten-minute billing lag running the account past zero
    /// (Google documents it), so both are kept rather than treated as "not
    /// reported".
    public let prepaidBalance: Decimal?

    /// A recurring Google Developer Program grant's local-currency amount, as
    /// it appears in AI Studio — e.g. the A$ value of the programme's US$10
    /// monthly credit. The programme states the grant in USD and Cloud Billing
    /// converts it at redemption, so this is the account's own figure.
    public let monthlyCredit: Decimal?

    /// The project's monthly spend cap, drawn as the API credit's monthly
    /// progress line. The meter's fill is elapsed calendar time, never a spend
    /// fraction: the usage that would give one meaning was not measured.
    public let monthlySpendCap: Decimal?

    /// When the user saved these figures. The row states it because a
    /// configured balance ages without any poll saying so — and a figure with
    /// no date would read as current forever.
    public let configuredAt: Date

    /// At least one money figure is required: a currency and a date alone are
    /// not a figure. The prepay balance may be negative (the vendor documents
    /// a billing lag that overdraws it); the monthly credit may not, and a
    /// spend cap of zero is not a cap (every request would fail) and is refused
    /// rather than drawn. The cap may be the only figure, so a user who wants
    /// just the API credit does not have to invent a balance.
    public init?(
        currencyCode: String,
        prepaidBalance: Decimal? = nil,
        monthlyCredit: Decimal? = nil,
        monthlySpendCap: Decimal? = nil,
        configuredAt: Date
    ) {
        let code = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // ISO 4217: three ASCII letters. `MoneyText` decides the symbol and the
        // minor-unit count from this, so an unrecognised code still prints
        // deterministically rather than borrowing the process locale.
        guard code.count == 3,
              code.allSatisfy({ $0.isASCII && $0.isLetter }),
              configuredAt.timeIntervalSince1970.isFinite else { return nil }
        guard Self.valid(prepaidBalance, allowsNegative: true),
              Self.valid(monthlyCredit, allowsNegative: false),
              Self.valid(monthlySpendCap, allowsNegative: false),
              monthlySpendCap.map({ $0 > 0 }) ?? true else { return nil }
        guard prepaidBalance != nil || monthlyCredit != nil || monthlySpendCap != nil
        else { return nil }

        self.currencyCode = code
        self.prepaidBalance = prepaidBalance
        self.monthlyCredit = monthlyCredit
        self.monthlySpendCap = monthlySpendCap
        self.configuredAt = configuredAt
    }

    private static func valid(_ amount: Decimal?, allowsNegative: Bool) -> Bool {
        guard let amount else { return true }
        guard !amount.isNaN else { return false }
        return allowsNegative || amount >= 0
    }

    /// What one typed amount field means.
    public enum AmountInput: Equatable, Sendable {
        /// Nothing typed. This is "not recorded", never zero.
        case empty
        case value(Decimal)
        /// Something was typed, but not one whole number. Saving must be
        /// refused rather than take `Decimal(string:)`'s leading prefix.
        case invalid

        /// The figure for a `.value`, nil for empty or invalid input.
        public var decimal: Decimal? {
            if case .value(let value) = self { return value }
            return nil
        }
    }

    /// Parses a whole amount field, never a prefix.
    ///
    /// `Decimal(string:locale:)` reads the leading number and silently drops
    /// the rest: "1,234.50" became 1, "30abc" became 30, and "0.1.2" became
    /// 0.1 — each a wrong money figure saved quietly. Only a plain decimal
    /// ("12", "14.50", "-5") or one with correctly grouped thousands
    /// separators ("1,234.50") is accepted; a comma that is not a group of
    /// three digits is a typo, not a decimal separator. A leading minus is
    /// allowed here; the model decides which pools may be negative.
    public static func amount(from text: String) -> AmountInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let plain = #"^-?[0-9]+(?:\.[0-9]+)?$"#
        let grouped = #"^-?[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?$"#
        let isGrouped = trimmed.range(of: grouped, options: .regularExpression) != nil
        guard isGrouped || trimmed.range(of: plain, options: .regularExpression) != nil
        else { return .invalid }
        let normalized = isGrouped ? trimmed.replacingOccurrences(of: ",", with: "") : trimmed
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else { return .invalid }
        return .value(value)
    }

    private enum CodingKeys: String, CodingKey {
        case currencyCode, prepaidBalance, monthlyCredit, monthlySpendCap, configuredAt
    }

    /// Validated on decode too: a stored blob is not proof the figures were
    /// ever sensible, and a corrupt or hand-edited one must draw nothing rather
    /// than a negative balance.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .currencyCode)
        let balance = try container.decodeIfPresent(Decimal.self, forKey: .prepaidBalance)
        let monthly = try container.decodeIfPresent(Decimal.self, forKey: .monthlyCredit)
        let cap = try container.decodeIfPresent(Decimal.self, forKey: .monthlySpendCap)
        let at = try container.decode(Date.self, forKey: .configuredAt)
        guard let credit = Self(currencyCode: code, prepaidBalance: balance,
                                monthlyCredit: monthly, monthlySpendCap: cap,
                                configuredAt: at) else {
            throw DecodingError.dataCorruptedError(
                forKey: .currencyCode, in: container,
                debugDescription: "Invalid configured Gemini API credit")
        }
        self = credit
    }
}

/// Storage for the configured Gemini API credit.
///
/// A preference, not a credential: the figures are not secret, and the API key
/// they describe is never read, stored or referenced here. Read through
/// `CredentialStore.preferences` so it lands in the app's explicit suite rather
/// than a process-name-dependent standard store.
///
/// Saving does not post a notification. The caller that changed the value
/// reloads the popover (Settings does this through `QuotaStore`), and
/// `QuotaManager` attaches the current value on every read, so a throttled poll
/// can never serve a stale configured figure either.
public enum GeminiAPICreditStore {

    public static let defaultsKey = "QuotaBarGeminiAPICredit"

    public static func load(preferences: UserDefaults = CredentialStore.preferences) -> GeminiAPICredit? {
        guard let data = preferences.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(GeminiAPICredit.self, from: data)
    }

    /// Saves the figures, or clears them when `credit` is nil.
    public static func save(_ credit: GeminiAPICredit?,
                            preferences: UserDefaults = CredentialStore.preferences) {
        guard let credit else {
            preferences.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(credit) else {
            NSLog("frugalbar: configured Gemini API credit failed to encode — save was dropped")
            return
        }
        preferences.set(data, forKey: defaultsKey)
    }

    // MARK: One credit per Google account (owner, 24 Nov 2026)

    /// Each Google account with its own paid AI Studio key bills to its own
    /// Cloud Billing account, so its credit is a separate pool. Keyed by the
    /// Antigravity account id (`agy-account:…`). The single credit under
    /// `defaultsKey` predates this and belongs to the primary account: it is
    /// read as that account's until the primary saves its own.
    public static let accountsDefaultsKey = "QuotaBarGeminiAPICreditsByAccount"

    public static func loadAll(preferences: UserDefaults = CredentialStore.preferences) -> [String: GeminiAPICredit] {
        guard let stored = preferences.dictionary(forKey: accountsDefaultsKey) else { return [:] }
        return stored.compactMapValues { value in
            (value as? Data).flatMap { try? JSONDecoder().decode(GeminiAPICredit.self, from: $0) }
        }
    }

    /// The credit for one account: its own, or for the primary account the
    /// older single credit.
    public static func load(accountID: String, isPrimary: Bool,
                            preferences: UserDefaults = CredentialStore.preferences) -> GeminiAPICredit? {
        loadAll(preferences: preferences)[accountID] ?? (isPrimary ? load(preferences: preferences) : nil)
    }

    /// Saves or clears one account's credit. The primary account's save also
    /// clears the older single credit, so a removed figure cannot come back
    /// through the fallback.
    public static func save(_ credit: GeminiAPICredit?, accountID: String, isPrimary: Bool,
                            preferences: UserDefaults = CredentialStore.preferences) {
        var stored = preferences.dictionary(forKey: accountsDefaultsKey) ?? [:]
        if let credit {
            guard let data = try? JSONEncoder().encode(credit) else {
                NSLog("frugalbar: configured Gemini API credit failed to encode — save was dropped")
                return
            }
            stored[accountID] = data
        } else {
            stored[accountID] = nil
        }
        preferences.set(stored, forKey: accountsDefaultsKey)
        if isPrimary { save(nil, preferences: preferences) }
    }
}
