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

/// Sync secret storage backed by `KeychainVault`'s `sync` namespace.
///
/// Legacy items under `com.quotabar.sync` are migrated automatically into
/// `vault.v1`'s `sync` dictionary on warm-up, while `delete` and `clearSync`
/// modify only the `sync` namespace and never touch provider credentials.
public struct KeychainSyncSecretStore: SyncSecretStore {
    public static let defaultService = KeychainVault.defaultSyncService
    public let service: String
    public let vault: KeychainVault

    public init(
        service: String = KeychainSyncSecretStore.defaultService,
        vault: KeychainVault? = nil
    ) {
        self.service = service
        if let vault {
            self.vault = vault
        } else if service == Self.defaultService {
            self.vault = .shared
        } else {
            self.vault = KeychainVault(keysService: service, syncService: service)
        }
    }

    /// The identity of one legacy item: also the query that finds it.
    static func itemQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Everything a legacy `write` added: kept for compatibility with existing
    /// attribute unit tests.
    static func addAttributes(service: String, account: String, value: String) -> [String: Any] {
        var attributes = itemQuery(service: service, account: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "FrugalBar sync (\(account))"
        return attributes
    }

    public func read(_ account: String) throws -> String? {
        try vault.read(namespace: .sync, account: account, allowsPrompt: false)
    }

    public func write(_ value: String, account: String) throws {
        try vault.write(value, namespace: .sync, account: account, allowsPrompt: true)
    }

    public func delete(_ account: String) throws {
        try vault.delete(namespace: .sync, account: account, allowsPrompt: true)
    }
}
