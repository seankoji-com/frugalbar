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
    /// Non-interactive delete for background cleanup and token revocation so
    /// unattended Sync work never presents a macOS Keychain prompt.
    func deleteNonInteractively(_ account: String) throws
    /// Atomic compare-and-delete (non-interactive): deletes `account` only if
    /// the durable value still matches `expectedValue`.
    func deleteNonInteractivelyIfMatching(_ expectedValue: String, account: String) throws
    /// Optional non-interactive refresh before retrying after a recoverable
    /// secret-store failure so Sync recovers once the login Keychain unlocks.
    /// Returns whether the secrets are readable afterwards; a caller keeps
    /// retrying the refresh until it reports true.
    @discardableResult
    func refreshNonInteractively() async -> Bool
}

public extension SyncSecretStore {
    func deleteNonInteractively(_ account: String) throws {
        try delete(account)
    }

    func deleteNonInteractivelyIfMatching(_ expectedValue: String, account: String) throws {
        if (try read(account)) == expectedValue {
            try deleteNonInteractively(account)
        }
    }

    @discardableResult
    func refreshNonInteractively() async -> Bool { true }
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
            // Keep the custom vault service distinct from the legacy sync service
            // so `vault.v1` and legacy sync items never share a Keychain service.
            self.vault = KeychainVault(keysService: "\(service).vault", syncService: service)
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

    public func deleteNonInteractively(_ account: String) throws {
        try vault.delete(namespace: .sync, account: account, allowsPrompt: false)
    }

    public func deleteNonInteractivelyIfMatching(_ expectedValue: String, account: String) throws {
        _ = try vault.deleteIfMatching(expectedValue, namespace: .sync, account: account, allowsPrompt: false)
    }

    @discardableResult
    public func refreshNonInteractively() async -> Bool {
        let status = await vault.warmUp(interactive: false)
        switch status.state {
        case .loaded, .empty:
            return status.pendingLegacySyncKeys.isEmpty && status.legacyScanSucceeded
        default:
            return false
        }
    }
}
