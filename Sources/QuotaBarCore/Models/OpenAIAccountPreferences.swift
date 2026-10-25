import CryptoKit
import Foundation

/// Account facts entered by the user when the usage endpoint publishes only
/// a balance and a generic plan. These never change the measured quota.
public struct OpenAIAccountPreferences: Codable, Equatable, Sendable {
    public enum ProTier: String, Codable, CaseIterable, Sendable {
        case pro100 = "Pro 100"
        case pro200 = "Pro 200"
    }

    public var proTier: ProTier?
    public var creditGrant: OpenAICreditGrant?

    public init(proTier: ProTier? = nil, creditGrant: OpenAICreditGrant? = nil) {
        self.proTier = proTier
        self.creditGrant = creditGrant
    }

    public func planName(reported: String?) -> String? {
        // An explicit vendor tier or a changed subscription wins over the
        // user's refinement of the otherwise ambiguous "pro" identifier.
        guard reported?.lowercased() == "pro", let proTier else { return reported?.capitalized }
        return proTier.rawValue
    }

    public static func accountKey(for accountID: String?) -> String? {
        guard let accountID, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static let defaultsKey = "QuotaBarOpenAIAccountPreferences"
    nonisolated(unsafe) public static let changeSender = NSObject()

    public static func load(accountKey: String, preferences: UserDefaults = CredentialStore.preferences) -> Self? {
        guard let data = preferences.dictionary(forKey: defaultsKey)?[accountKey] as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public static func save(_ value: Self?, accountKey: String, preferences: UserDefaults = CredentialStore.preferences) {
        var accounts = preferences.dictionary(forKey: defaultsKey) ?? [:]
        accounts[accountKey] = value.flatMap { try? JSONEncoder().encode($0) }
        preferences.set(accounts, forKey: defaultsKey)
        NotificationCenter.default.post(name: .frugalbarProviderPreferencesDidChange,
                                        object: changeSender)
    }
}

/// Original allowance and expiry confirmed by the account holder. Never a
/// global default, recurring quota, or conversion from dollars to credits.
public struct OpenAICreditGrant: Codable, Equatable, Sendable {
    public let total: Decimal
    public let expiresAt: Date?

    public static func parseTotal(_ text: String) -> Decimal? {
        OpenAIQuotaProvider.creditCount(text).flatMap { $0 > 0 ? $0 : nil }
    }

    public init?(total: Decimal, expiresAt: Date? = nil) {
        guard !total.isNaN, total > 0,
              expiresAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { return nil }
        self.total = total
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case total, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let total = try c.decode(Decimal.self, forKey: .total)
        let end = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        guard let grant = Self(total: total, expiresAt: end) else {
            throw DecodingError.dataCorruptedError(forKey: .total, in: c, debugDescription: "Invalid credit grant")
        }
        self = grant
    }
}
