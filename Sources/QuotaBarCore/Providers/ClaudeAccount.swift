import Foundation
import CryptoKit

/// Non-secret identity and presentation for one Claude subscription. Names and
/// source labels never contain credentials or guessed account email addresses.
public struct ClaudeAccount: Codable, Sendable, Equatable, Identifiable {
    public static let instancePrefix = "claude-account:"
    public let id: String
    public let badge: String
    public let sourceLabel: String
    public let fallbackName: String
    public var nickname: String?
    public var planName: String?
    public var name: String { nickname?.trimmed.nilIfEmpty ?? fallbackName }

    public init(id: String, badge: String, sourceLabel: String, fallbackName: String,
                nickname: String? = nil, planName: String? = nil) {
        self.id = id
        self.badge = badge
        self.sourceLabel = sourceLabel
        self.fallbackName = fallbackName
        self.nickname = nickname
        self.planName = planName
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func instanceID(identity: String) -> String { instancePrefix + digest(identity) }
}

/// A read-only credential file for a separately signed-in Claude Code profile.
/// The source id survives renaming or correcting its path. It stores no token.
public struct ClaudeProfileSource: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var path: String
    public var nickname: String?
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, path: String, nickname: String? = nil,
                isEnabled: Bool = true) {
        self.id = id; self.path = path; self.nickname = nickname; self.isEnabled = isEnabled
    }
}

/// Only safe account descriptors and nicknames are stored here. Tokens remain
/// in their existing credential sources. Tests pass a private preference suite.
public enum ClaudeAccountStore {
    static let accountsKey = "QuotaBarClaudeAccounts"
    static let nicknamesKey = "QuotaBarClaudeAccountNicknames"
    static let badgesKey = "QuotaBarClaudeAccountBadges"
    static let profilesKey = "QuotaBarClaudeProfileSources"

    public static func profileSources(in defaults: UserDefaults = CredentialStore.preferences) -> [ClaudeProfileSource] {
        guard let data = defaults.data(forKey: profilesKey) else { return [] }
        return (try? JSONDecoder().decode([ClaudeProfileSource].self, from: data)) ?? []
    }

    public static func setProfileSources(_ sources: [ClaudeProfileSource],
                                         in defaults: UserDefaults = CredentialStore.preferences) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        defaults.set(data, forKey: profilesKey)
        NotificationCenter.default.post(name: .frugalbarProviderPreferencesDidChange, object: nil)
    }

    @discardableResult
    public static func addProfile(path: String, nickname: String?,
                                  in defaults: UserDefaults = CredentialStore.preferences) -> Bool {
        guard !path.trimmed.isEmpty else { return false }
        let normalized = URL(fileURLWithPath: NSString(string: path.trimmed).expandingTildeInPath)
            .standardizedFileURL.path
        var sources = profileSources(in: defaults)
        guard !sources.contains(where: { $0.path == normalized }) else { return false }
        sources.append(ClaudeProfileSource(path: normalized, nickname: nickname?.trimmed.nilIfEmpty))
        setProfileSources(sources, in: defaults)
        return true
    }

    public static func all(in defaults: UserDefaults = CredentialStore.preferences) -> [ClaudeAccount] {
        guard let data = defaults.data(forKey: accountsKey),
              let accounts = try? JSONDecoder().decode([ClaudeAccount].self, from: data) else { return [] }
        let names = defaults.dictionary(forKey: nicknamesKey) as? [String: String] ?? [:]
        return accounts.map { account in
            var copy = account
            copy.nickname = names[account.id] ?? account.nickname
            return copy
        }
    }

    public static func setNickname(_ name: String, for id: String,
                                   in defaults: UserDefaults = CredentialStore.preferences) {
        guard id.hasPrefix(ClaudeAccount.instancePrefix) else { return }
        var names = defaults.dictionary(forKey: nicknamesKey) as? [String: String] ?? [:]
        names[id] = name.trimmed.nilIfEmpty
        defaults.set(names, forKey: nicknamesKey)
        NotificationCenter.default.post(name: .frugalbarProviderPreferencesDidChange, object: nil)
    }

    /// Discovery order is stable even if the proxy changes its auth-file order.
    /// Badges survive removal and rediscovery, and a nickname never changes id.
    static func saveDiscovered(_ accounts: [ClaudeAccount], in defaults: UserDefaults) -> [ClaudeAccount] {
        var badges = defaults.dictionary(forKey: badgesKey) as? [String: String] ?? [:]
        var next = (badges.values.compactMap(Int.init).max() ?? 0) + 1
        let result = accounts.sorted { $0.id < $1.id }.map { account in
            if badges[account.id] == nil { badges[account.id] = String(next); next += 1 }
            let badge = badges[account.id]!
            return ClaudeAccount(id: account.id, badge: badge, sourceLabel: account.sourceLabel,
                fallbackName: account.fallbackName == "This Mac" ? "This Mac" : "Account \(badge)",
                nickname: account.nickname, planName: account.planName)
        }.sorted { (Int($0.badge) ?? 0) < (Int($1.badge) ?? 0) }
        if let data = try? JSONEncoder().encode(result), defaults.data(forKey: accountsKey) != data {
            defaults.set(data, forKey: accountsKey)
        }
        defaults.set(badges, forKey: badgesKey)
        return all(in: defaults)
    }

    public static func displayName(forInstanceKey key: String) -> String? {
        all().first { $0.id == key }?.name
    }

    public static func position(ofInstanceKey key: String) -> Int? {
        all().firstIndex { $0.id == key }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
