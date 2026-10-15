import Foundation
import Security

/// The two sync items kept in the Keychain.
public enum SyncSecretAccount {
    /// The Drive refresh token.
    public static let refreshToken = "refreshToken"
    /// The active session's opaque `publisherId` (REQ-MAC-FILE e).
    public static let publisherId = "publisherId"
}

/// Where sync keeps its refresh token and session id. Values are never
/// logged or shown.
public protocol SyncSecretStore: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(_ account: String) throws
}

/// Generic-password items under their own service, so a sync reset can never
/// touch a provider credential.
///
/// Every item is non-synchronizable and written with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. A bare, unsigned binary
/// writes to the legacy file keychain, which neither records nor enforces
/// that attribute; it is set for when FrugalBar ships as a signed `.app`
/// (D§2.2.B, D§2.2.N). `kSecUseDataProtectionKeychain` is deliberately absent:
/// without an entitlement it fails every write with -34018 (see
/// `KeychainManager`).
public struct KeychainSyncSecretStore: SyncSecretStore {
    public static let defaultService = "com.quotabar.sync"
    public let service: String

    public init(service: String = KeychainSyncSecretStore.defaultService) {
        self.service = service
    }

    /// The identity of one item: also the query that finds it.
    static func itemQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Everything `write` adds: the item's identity, its value and its
    /// accessibility. Pure, so the attributes are asserted without trusting
    /// what the legacy keychain chooses to report back.
    static func addAttributes(service: String, account: String, value: String) -> [String: Any] {
        var attributes = itemQuery(service: service, account: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "FrugalBar sync (\(account))"
        return attributes
    }

    public func read(_ account: String) throws -> String? {
        var query = Self.itemQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    /// Delete, then add: an update would keep whatever accessibility an older
    /// item was written with.
    public func write(_ value: String, account: String) throws {
        try delete(account)
        let status = SecItemAdd(Self.addAttributes(service: service, account: account, value: value) as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(Self.itemQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unknown(status) }
    }
}
