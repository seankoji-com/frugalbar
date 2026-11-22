import Foundation
import CryptoKit

/// Non-secret identity and presentation for one Antigravity (Google Cloud Code)
/// account. Names and source labels never contain credentials or OAuth tokens.
public struct AntigravityAccount: Codable, Sendable, Equatable, Identifiable {
    public static let instancePrefix = "agy-account:"
    public let id: String
    public let badge: String
    public let sourceLabel: String
    public let fallbackName: String
    public var nickname: String?
    public var planName: String?
    /// True for this Mac's local primary Google OAuth account. Only the primary
    /// account hosts the user-configured `GeminiAPICredit` and inherits legacy
    /// `gemini`, `antigravity_claude`, and `antigravity_argon` history keys.
    public var isPrimary: Bool = false
    /// Previous account ids proven to be this same account. Pool-scoped history
    /// keys expand each alias for the matching allowance.
    public var historyAliases: [String] = []
    public var name: String { nickname?.trimmed.nilIfEmpty ?? fallbackName }

    public init(
        id: String,
        badge: String,
        sourceLabel: String,
        fallbackName: String,
        nickname: String? = nil,
        planName: String? = nil,
        isPrimary: Bool = false,
        historyAliases: [String] = []
    ) {
        self.id = id
        self.badge = badge
        self.sourceLabel = sourceLabel
        self.fallbackName = fallbackName
        self.nickname = nickname
        self.planName = planName
        self.isPrimary = isPrimary
        self.historyAliases = historyAliases
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func instanceID(identity: String) -> String {
        instancePrefix + digest(identity)
    }

    public static func poolSuffix(for allowance: GeminiQuotaProvider.Allowance) -> String {
        switch allowance {
        case .gemini: "gemini"
        case .claude: "claude"
        case .argon:  "argon"
        }
    }

    public static func legacyKey(for allowance: GeminiQuotaProvider.Allowance) -> String {
        switch allowance {
        case .gemini: VendorIdentifier.gemini.rawValue
        case .claude: VendorIdentifier.antigravityClaude.rawValue
        case .argon:  VendorIdentifier.antigravityArgon.rawValue
        }
    }

    public static func allowance(for vendor: VendorIdentifier) -> GeminiQuotaProvider.Allowance? {
        switch vendor {
        case .gemini:            .gemini
        case .antigravityClaude: .claude
        case .antigravityArgon:  .argon
        default:                 nil
        }
    }

    public static func poolInstanceID(
        accountID: String, allowance: GeminiQuotaProvider.Allowance
    ) -> String {
        "\(accountID):\(poolSuffix(for: allowance))"
    }

    public func poolInstanceID(for allowance: GeminiQuotaProvider.Allowance) -> String {
        Self.poolInstanceID(accountID: id, allowance: allowance)
    }

    /// All history instance keys belonging to this account's pool, including
    /// proven account aliases and (for the primary account only) the legacy
    /// single-account vendor key.
    public func poolHistoryKeys(for allowance: GeminiQuotaProvider.Allowance) -> [String] {
        var keys = [poolInstanceID(for: allowance)]
        for alias in historyAliases {
            let candidate = alias.hasPrefix(Self.instancePrefix)
                ? Self.poolInstanceID(accountID: alias, allowance: allowance)
                : alias
            if !keys.contains(candidate) { keys.append(candidate) }
        }
        if isPrimary {
            let legacy = Self.legacyKey(for: allowance)
            if !keys.contains(legacy) { keys.append(legacy) }
        }
        return keys
    }

    /// Pool-scoped aliases excluding this pool's own canonical instance id.
    public func poolHistoryAliases(for allowance: GeminiQuotaProvider.Allowance) -> [String] {
        let canonical = poolInstanceID(for: allowance)
        return poolHistoryKeys(for: allowance).filter { $0 != canonical }
    }

    /// Parses an `agy-account:<hash>:<pool>` instance key into its account id
    /// and allowance. Returns nil for keys that do not match.
    public static func parsePoolInstanceKey(
        _ key: String
    ) -> (accountID: String, allowance: GeminiQuotaProvider.Allowance)? {
        guard key.hasPrefix(instancePrefix) else { return nil }
        if key.hasSuffix(":gemini") {
            return (String(key.dropLast(":gemini".count)), .gemini)
        }
        if key.hasSuffix(":claude") {
            return (String(key.dropLast(":claude".count)), .claude)
        }
        if key.hasSuffix(":argon") {
            return (String(key.dropLast(":argon".count)), .argon)
        }
        return nil
    }

    public static func vendor(forInstanceKey key: String) -> VendorIdentifier? {
        guard let parsed = parsePoolInstanceKey(key) else { return nil }
        switch parsed.allowance {
        case .gemini: return .gemini
        case .claude: return .antigravityClaude
        case .argon:  return .antigravityArgon
        }
    }
}

/// Only safe account descriptors and nicknames are stored here. Tokens remain
/// in their existing credential sources. Tests pass a private preference suite.
public enum AntigravityAccountStore {
    static let accountsKey = "QuotaBarAntigravityAccounts"
    static let nicknamesKey = "QuotaBarAntigravityAccountNicknames"
    static let badgesKey = "QuotaBarAntigravityAccountBadges"
    static let aliasesKey = "QuotaBarAntigravityAccountHistoryAliases"

    public static func all(
        in defaults: UserDefaults = CredentialStore.preferences
    ) -> [AntigravityAccount] {
        guard let data = defaults.data(forKey: accountsKey),
              let accounts = try? JSONDecoder().decode([AntigravityAccount].self, from: data)
        else { return [] }
        let names = defaults.dictionary(forKey: nicknamesKey) as? [String: String] ?? [:]
        let aliases = defaults.dictionary(forKey: aliasesKey) as? [String: [String]] ?? [:]
        return accounts.map { account in
            var copy = account
            copy.nickname = names[account.id]
            copy.historyAliases = aliases[account.id] ?? account.historyAliases
            return copy
        }
    }

    public static func setNickname(
        _ name: String, for id: String,
        in defaults: UserDefaults = CredentialStore.preferences
    ) {
        guard id.hasPrefix(AntigravityAccount.instancePrefix) else { return }
        var names = defaults.dictionary(forKey: nicknamesKey) as? [String: String] ?? [:]
        names[id] = name.trimmed.nilIfEmpty
        defaults.set(names, forKey: nicknamesKey)
        NotificationCenter.default.post(name: .frugalbarProviderPreferencesDidChange, object: nil)
    }

    /// Discovery order is stable even if the proxy changes its auth-file order.
    /// The primary local account stays first when present; badges survive
    /// removal and rediscovery, and a nickname never changes id.
    static func saveDiscovered(
        _ accounts: [AntigravityAccount], in defaults: UserDefaults
    ) -> [AntigravityAccount] {
        let previous = all(in: defaults)
        var badges = defaults.dictionary(forKey: badgesKey) as? [String: String] ?? [:]
        var aliases = defaults.dictionary(forKey: aliasesKey) as? [String: [String]] ?? [:]
        var names = defaults.dictionary(forKey: nicknamesKey) as? [String: String] ?? [:]
        var next = (badges.values.compactMap(Int.init).max() ?? 0) + 1
        let sortedInput = accounts.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.id < rhs.id
        }
        let result = sortedInput.map { account in
            if badges[account.id] == nil { badges[account.id] = String(next); next += 1 }
            let badge = badges[account.id]!
            aliases[account.id] = Set(aliases[account.id] ?? []).union(account.historyAliases).sorted()
            for alias in aliases[account.id] ?? [] {
                if names[account.id] == nil { names[account.id] = names[alias] }
                names[alias] = nil
            }
            let fallback = previous.first { $0.id == account.id }?.fallbackName
                ?? (account.fallbackName == "This Mac" ? "This Mac" : "Account \(badge)")
            return AntigravityAccount(
                id: account.id,
                badge: badge,
                sourceLabel: account.sourceLabel,
                fallbackName: fallback,
                planName: account.planName,
                isPrimary: account.isPrimary,
                historyAliases: aliases[account.id] ?? []
            )
        }.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return (Int(lhs.badge) ?? 0) < (Int(rhs.badge) ?? 0)
        }
        let changed: Bool
        if let data = try? JSONEncoder().encode(result), defaults.data(forKey: accountsKey) != data {
            defaults.set(data, forKey: accountsKey)
            changed = true
        } else {
            changed = false
        }
        defaults.set(badges, forKey: badgesKey)
        defaults.set(aliases, forKey: aliasesKey)
        defaults.set(names, forKey: nicknamesKey)
        if changed {
            NotificationCenter.default.post(name: .frugalbarAntigravityAccountsDidChange, object: nil)
        }
        return all(in: defaults)
    }

    public static func displayName(
        forInstanceKey key: String,
        in defaults: UserDefaults = CredentialStore.preferences
    ) -> String? {
        let accounts = all(in: defaults)
        if let parsed = AntigravityAccount.parsePoolInstanceKey(key) {
            guard let account = accounts.first(where: {
                $0.poolHistoryKeys(for: parsed.allowance).contains(key)
            }) else { return nil }
            let poolLabel = AntigravityAccount.vendor(forInstanceKey: key)?.displayName ?? "Antigravity"
            return "\(poolLabel) · \(account.name)"
        }
        if let vendor = VendorIdentifier(rawValue: key),
           AntigravityAccount.allowance(for: vendor) != nil,
           let primary = accounts.first(where: \.isPrimary) {
            return "\(vendor.displayName) · \(primary.name)"
        }
        return nil
    }

    public static func position(
        ofInstanceKey key: String,
        in defaults: UserDefaults = CredentialStore.preferences
    ) -> Int? {
        let accounts = all(in: defaults)
        if let parsed = AntigravityAccount.parsePoolInstanceKey(key) {
            return accounts.firstIndex { $0.poolHistoryKeys(for: parsed.allowance).contains(key) }
        }
        if let vendor = VendorIdentifier(rawValue: key),
           AntigravityAccount.allowance(for: vendor) != nil {
            return accounts.firstIndex(where: \.isPrimary)
        }
        return nil
    }

    public static func historyKeys(
        forInstanceKey key: String,
        in defaults: UserDefaults = CredentialStore.preferences
    ) -> [String] {
        let accounts = all(in: defaults)
        if let parsed = AntigravityAccount.parsePoolInstanceKey(key),
           let account = accounts.first(where: { $0.id == parsed.accountID }) {
            return account.poolHistoryKeys(for: parsed.allowance)
        }
        if let account = accounts.first(where: { $0.id == key }) {
            return [account.id] + account.historyAliases
        }
        return [key]
    }

    public static func canonicalInstanceKey(
        _ key: String,
        in defaults: UserDefaults = CredentialStore.preferences
    ) -> String {
        let accounts = all(in: defaults)
        if let parsed = AntigravityAccount.parsePoolInstanceKey(key),
           let account = accounts.first(where: { $0.poolHistoryKeys(for: parsed.allowance).contains(key) }) {
            return account.poolInstanceID(for: parsed.allowance)
        }
        if let vendor = VendorIdentifier(rawValue: key),
           let allowance = AntigravityAccount.allowance(for: vendor),
           let primary = accounts.first(where: \.isPrimary) {
            return primary.poolInstanceID(for: allowance)
        }
        return key
    }
}

public extension Notification.Name {
    static let frugalbarAntigravityAccountsDidChange = Notification.Name("frugalbarAntigravityAccountsDidChange")
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
