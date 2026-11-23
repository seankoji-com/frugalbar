import Foundation
import LocalAuthentication
import Security

// MARK: - Vault schema & status

/// Single encrypted JSON document stored under `com.quotabar.keys` / `vault.v1`.
///
/// Consolidates all FrugalBar-owned provider, workspace, Gemini OAuth, CLI Proxy,
/// and Sync secrets into one Keychain item so an ad-hoc rebuild invalidating ACLs
/// prompts at most once instead of once per credential.
public struct VaultDocument: Codable, Sendable, Equatable {
    public var version: Int
    public var keys: [String: String]
    public var sync: [String: String]
    public var deletedLegacyKeys: Set<String>
    public var deletedLegacySyncKeys: Set<String>

    public init(
        version: Int = 1,
        keys: [String: String] = [:],
        sync: [String: String] = [:],
        deletedLegacyKeys: Set<String> = [],
        deletedLegacySyncKeys: Set<String> = []
    ) {
        self.version = version
        self.keys = keys
        self.sync = sync
        self.deletedLegacyKeys = deletedLegacyKeys
        self.deletedLegacySyncKeys = deletedLegacySyncKeys
    }

    public var isEmpty: Bool {
        keys.isEmpty && sync.isEmpty && deletedLegacyKeys.isEmpty && deletedLegacySyncKeys.isEmpty
    }
}

public enum VaultNamespace: String, Sendable, Hashable {
    case keys
    case sync
}

/// Why a vault read could not confirm presence or absence of a secret.
///
/// Every case here is recoverable (unlike confirmed absence): callers such as
/// Sync must pause and retry rather than treating a locked, corrupt, or
/// partially migrated vault as "signed out".
public enum VaultUnavailableReason: Error, Sendable, Equatable {
    case notLoaded
    case lockedOrDenied(OSStatus)
    case corrupt
    case pendingLegacy
    case legacyScanFailed

    public var userDescription: String {
        switch self {
        case .notLoaded:
            "Keychain vault has not finished loading"
        case .lockedOrDenied(let status):
            KeychainError.unknown(status).localizedDescription
        case .corrupt:
            "Saved Keychain vault data could not be read"
        case .pendingLegacy:
            "Some legacy Keychain credentials still need access"
        case .legacyScanFailed:
            "Could not scan legacy Keychain items"
        }
    }
}

/// Non-secret summary of the vault's current state for Settings and diagnostics.
public enum VaultHealthState: Sendable, Equatable {
    case unloaded
    case loaded
    case empty
    case lockedOrDenied(OSStatus)
    case corrupt
}

/// Outcome of a non-blocking deferred background write (such as Gemini OAuth
/// token renewal).
public enum DeferredWriteOutcome: Sendable, Equatable {
    /// Persisted to `vault.v1` immediately without blocking or prompting.
    case persisted
    /// Kept in memory because the lockfile was contended or Keychain was locked;
    /// will flush on explicit Unlock or Save unless superseded.
    case deferred
    /// Dropped because a newer explicit edit, deletion, or cross-process change
    /// already replaced the expected baseline value.
    case superseded
}

public struct VaultStatusSnapshot: Sendable, Equatable {
    public let state: VaultHealthState
    public let pendingLegacyKeys: Set<String>
    public let pendingLegacySyncKeys: Set<String>
    public let legacyScanSucceeded: Bool
    public let deferredWriteCount: Int

    public init(
        state: VaultHealthState,
        pendingLegacyKeys: Set<String> = [],
        pendingLegacySyncKeys: Set<String> = [],
        legacyScanSucceeded: Bool = false,
        deferredWriteCount: Int = 0
    ) {
        self.state = state
        self.pendingLegacyKeys = pendingLegacyKeys
        self.pendingLegacySyncKeys = pendingLegacySyncKeys
        self.legacyScanSucceeded = legacyScanSucceeded
        self.deferredWriteCount = deferredWriteCount
    }

    public var isCorrupt: Bool { state == .corrupt }

    public var isLockedOrDenied: Bool {
        if case .lockedOrDenied = state { return true }
        return false
    }

    public var hasPendingLegacyItems: Bool {
        !pendingLegacyKeys.isEmpty || !pendingLegacySyncKeys.isEmpty
    }

    public var hasPendingWrites: Bool { deferredWriteCount > 0 }

    /// Whether explicit Unlock is needed to read or finish migrating credentials.
    public var needsUnlock: Bool {
        if isLockedOrDenied || hasPendingLegacyItems { return true }
        switch state {
        case .loaded, .empty:
            return !legacyScanSucceeded
        case .unloaded, .lockedOrDenied, .corrupt:
            return false
        }
    }
}

// MARK: - Raw Keychain backend

/// Low-level, single-item Keychain operations.
///
/// Used directly by `--doctor` (without touching the vault) and by `KeychainVault`
/// for `vault.v1` and legacy migration. Tests inject an in-memory implementation
/// so they never touch the user's login Keychain.
public protocol KeychainBackend: Sendable {
    /// Returns `nil` ONLY on `errSecItemNotFound`. Any other status throws `KeychainError`.
    func read(service: String, account: String, allowsPrompt: Bool) throws -> Data?
    func write(_ data: Data, service: String, account: String, label: String?, allowsPrompt: Bool) throws
    func delete(service: String, account: String, allowsPrompt: Bool) throws
    /// Lists all generic-password account names in `service` without reading secret data.
    /// Returns `[]` on `errSecItemNotFound`. Any other status throws `KeychainError`.
    func listAccounts(service: String) throws -> [String]
}

/// Real macOS Security.framework backend.
public struct SystemKeychainBackend: KeychainBackend {
    public static let shared = SystemKeychainBackend()

    public init() {}

    public func read(service: String, account: String, allowsPrompt: Bool) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false,
        ]
        if !allowsPrompt {
            query[kSecUseAuthenticationContext as String] = Self.nonPromptingAuthContext()
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
        guard let data = result as? Data else { throw KeychainError.invalidData }
        return data
    }

    public func write(
        _ data: Data,
        service: String,
        account: String,
        label: String? = nil,
        allowsPrompt: Bool
    ) throws {
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: false,
        ]
        if !allowsPrompt {
            query[kSecUseAuthenticationContext as String] = Self.nonPromptingAuthContext()
        }
        var attributes: [String: Any] = [
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let label {
            attributes[kSecAttrLabel as String] = label
        }

        var addQuery = query
        for (k, v) in attributes { addQuery[k] = v }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unknown(updateStatus)
            }
        default:
            throw KeychainError.unknown(addStatus)
        }
    }

    public func delete(service: String, account: String, allowsPrompt: Bool) throws {
        var query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: false,
        ]
        if !allowsPrompt {
            query[kSecUseAuthenticationContext as String] = Self.nonPromptingAuthContext()
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
    }

    public func listAccounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String:   true,
            kSecMatchLimit as String:         kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: Self.nonPromptingAuthContext(),
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// `LAContext` with `interactionNotAllowed = true`. Attached via
    /// `kSecUseAuthenticationContext`, it returns `errSecInteractionNotAllowed`
    /// instead of presenting a SecurityAgent prompt.
    public static func nonPromptingAuthContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

// MARK: - Cross-process lockfile

enum VaultLockError: Error {
    case wouldBlock
    case failed(Int32)
}

/// Serializes vault read-merge-commit across both threads in this process and
/// concurrent FrugalBar processes using `NSLock` + POSIX `flock`.
final class VaultFileLock: @unchecked Sendable {
    private let inProcessLock = NSLock()
    let lockFileURL: URL

    init(lockFileURL: URL) {
        self.lockFileURL = lockFileURL
    }

    func withLock<T>(blocking: Bool, _ body: () throws -> T) throws -> T {
        if blocking {
            inProcessLock.lock()
        } else {
            guard inProcessLock.try() else { throw VaultLockError.wouldBlock }
        }
        defer { inProcessLock.unlock() }

        let dir = lockFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw VaultLockError.failed(errno) }
        defer { close(fd) }

        let operation = blocking ? LOCK_EX : (LOCK_EX | LOCK_NB)
        if flock(fd, operation) != 0 {
            let err = errno
            if !blocking && err == EWOULDBLOCK {
                throw VaultLockError.wouldBlock
            }
            throw VaultLockError.failed(err)
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try body()
    }

    static func defaultLockFileURL(forService service: String) -> URL {
        let sanitized = service.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_") ? ch : "_"
        }
        let filename = "vault-\(String(sanitized)).lock"
        if TestHost.isActive {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("frugalbar-test-locks", isDirectory: true)
                .appendingPathComponent(filename)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("FrugalBar", isDirectory: true)
            .appendingPathComponent(filename)
    }
}

/// In-memory Keychain backend used solely by `KeychainVault.shared` when
/// `TestHost.isActive` is true, so tests that read through `.shared` can never
/// migrate or mutate the host Mac's live login Keychain.
private final class EphemeralTestKeychainBackend: KeychainBackend, @unchecked Sendable {
    private struct ItemKey: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var storage: [ItemKey: Data] = [:]

    func read(service: String, account: String, allowsPrompt: Bool) throws -> Data? {
        lock.withLock { storage[ItemKey(service: service, account: account)] }
    }

    func write(_ data: Data, service: String, account: String, label: String?, allowsPrompt: Bool) throws {
        lock.withLock { storage[ItemKey(service: service, account: account)] = data }
    }

    func delete(service: String, account: String, allowsPrompt: Bool) throws {
        lock.withLock { _ = storage.removeValue(forKey: ItemKey(service: service, account: account)) }
    }

    func listAccounts(service: String) throws -> [String] {
        lock.withLock { storage.keys.filter { $0.service == service }.map(\.account) }
    }
}

// MARK: - KeychainVault

/// Encrypted single-item JSON vault cached in memory, with legacy item migration,
/// tombstone deletion ordering, non-blocking deferred background writes, and
/// coalesced async warm-up.
public final class KeychainVault: @unchecked Sendable {

    public static let vaultAccount = "vault.v1"
    public static let defaultKeysService = "com.quotabar.keys"
    public static let defaultSyncService = "com.quotabar.sync"
    public static let doctorProbeAccount = "com.quotabar.doctor.probe"

    public static let shared: KeychainVault = {
        if TestHost.isActive {
            return KeychainVault(
                keysService: "\(defaultKeysService).testhost",
                syncService: "\(defaultSyncService).testhost",
                backend: EphemeralTestKeychainBackend(),
                lockFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("quotabar-testhost-vault-\(ProcessInfo.processInfo.processIdentifier).lock")
            )
        }
        return KeychainVault()
    }()

    public let keysService: String
    public let syncService: String
    private let backend: any KeychainBackend
    private let fileLock: VaultFileLock

    /// Optional test hook invoked after committing tombstones to `vault.v1` and
    /// before deleting legacy items, to verify crash/interruption safety.
    var afterCommitBeforeLegacyDelete: (@Sendable () throws -> Void)?

    private struct VaultKey: Hashable {
        let namespace: VaultNamespace
        let account: String
    }

    private struct DeferredWrite {
        let value: String
        let seq: UInt64
        /// Optional compare-and-swap baseline captured before an async refresh
        /// (e.g. Gemini OAuth renewal). When non-nil, flushing under `flock`
        /// only applies the deferred write if the durable vault still holds
        /// this exact value for the account; otherwise a newer explicit edit,
        /// deletion, or cross-process update wins and the stale write is dropped.
        let expectedPreviousValue: String?
    }

    private enum InternalState {
        case unloaded
        case loaded(VaultDocument)
        case empty
        case lockedOrDenied(OSStatus)
        case corrupt

        var health: VaultHealthState {
            switch self {
            case .unloaded: .unloaded
            case .loaded: .loaded
            case .empty: .empty
            case .lockedOrDenied(let s): .lockedOrDenied(s)
            case .corrupt: .corrupt
            }
        }
    }

    private let stateLock = NSLock()
    private var internalState: InternalState = .unloaded
    private var pendingLegacyKeys: Set<String> = []
    private var pendingLegacySyncKeys: Set<String> = []
    private var legacyScanSucceeded = false
    private var nextSeq: UInt64 = 0
    private var explicitSeq: [VaultKey: UInt64] = [:]
    private var staleDeferredSeq: [VaultKey: UInt64] = [:]
    private var deferredWrites: [VaultKey: DeferredWrite] = [:]

    /// Coalesced warm-up tasks so startup fetch and sync share one vault read.
    private var nextWarmUpID: UInt64 = 0
    private var inFlightWarmUp: (id: UInt64, task: Task<VaultStatusSnapshot, Never>, interactive: Bool)?
    /// Background queue for blocking Keychain / flock operations in async APIs.
    private let ioQueue = DispatchQueue(label: "com.quotabar.vault.io", qos: .userInitiated)

    public init(
        keysService: String = KeychainVault.defaultKeysService,
        syncService: String = KeychainVault.defaultSyncService,
        backend: any KeychainBackend = SystemKeychainBackend.shared,
        lockFileURL: URL? = nil
    ) {
        self.keysService = keysService
        self.syncService = syncService
        self.backend = backend
        self.fileLock = VaultFileLock(
            lockFileURL: lockFileURL ?? VaultFileLock.defaultLockFileURL(forService: keysService)
        )
    }

    // MARK: - Status & Cache-Only Reads (Non-blocking, Zero Prompts)

    public func statusSnapshot() -> VaultStatusSnapshot {
        stateLock.withLock {
            VaultStatusSnapshot(
                state: internalState.health,
                pendingLegacyKeys: pendingLegacyKeys,
                pendingLegacySyncKeys: pendingLegacySyncKeys,
                legacyScanSucceeded: legacyScanSucceeded,
                deferredWriteCount: deferredWrites.count
            )
        }
    }

    /// Reads ONLY from the in-memory cache and deferred-write buffer.
    /// Never touches macOS Keychain, never blocks on `flock`, never prompts.
    public func cachedValue(namespace: VaultNamespace, account: String) -> String? {
        stateLock.withLock {
            let key = VaultKey(namespace: namespace, account: account)
            if let deferred = deferredWrites[key] {
                return deferred.value
            }
            guard case .loaded(let doc) = internalState else { return nil }
            switch namespace {
            case .keys: return doc.keys[account]
            case .sync: return doc.sync[account]
            }
        }
    }

    /// Returns all currently cached key/value pairs in `namespace` (including
    /// in-memory deferred writes). Never touches macOS Keychain or prompts.
    public func cachedEntries(namespace: VaultNamespace) -> [String: String] {
        stateLock.withLock {
            var result: [String: String]
            if case .loaded(let doc) = internalState {
                result = namespace == .keys ? doc.keys : doc.sync
            } else {
                result = [:]
            }
            for (k, deferred) in deferredWrites where k.namespace == namespace {
                result[k.account] = deferred.value
            }
            return result
        }
    }

    // MARK: - Warm-up & Unlock

    /// Coalesced async warm-up. Startup `QuotaManager` and `SyncController.start()`
    /// both await this before starting provider deadlines or resuming Stop.
    ///
    /// - Parameter interactive: `false` never presents a Keychain prompt; `true`
    ///   allows macOS SecurityAgent to prompt once for `vault.v1` (and any
    ///   unmigrated legacy items), and flushes deferred writes even when already `.loaded`.
    @discardableResult
    public func warmUp(interactive: Bool) async -> VaultStatusSnapshot {
        if !interactive {
            let current = statusSnapshot()
            if case .corrupt = current.state {
                return current
            }
        }

        let taskToAwait: Task<VaultStatusSnapshot, Never> = stateLock.withLock {
            if let existing = inFlightWarmUp {
                // If an interactive warm-up is already running, everyone can join it.
                // If a non-interactive warm-up is running and caller also wants
                // non-interactive, join it.
                if existing.interactive || !interactive {
                    return existing.task
                }
            }
            let previous = inFlightWarmUp?.task
            nextWarmUpID += 1
            let myID = nextWarmUpID
            let newTask = Task<VaultStatusSnapshot, Never> { [self] in
                if let previous {
                    _ = await previous.value
                }
                return await withCheckedContinuation { continuation in
                    self.ioQueue.async {
                        let status = self.performWarmUpSync(interactive: interactive)
                        self.stateLock.withLock {
                            if self.inFlightWarmUp?.id == myID {
                                self.inFlightWarmUp = nil
                            }
                        }
                        continuation.resume(returning: status)
                    }
                }
            }
            inFlightWarmUp = (myID, newTask, interactive)
            return newTask
        }
        return await taskToAwait.value
    }

    /// Startup warm-up: runs an interactive warm-up ONCE when the vault is
    /// `.unloaded` (coalesced across startup quota fetch and `SyncController.start()`).
    /// Once warm-up has run (even if the user denied access), subsequent calls
    /// return the current status without re-prompting.
    @discardableResult
    public func warmUpForStartup() async -> VaultStatusSnapshot {
        let current = statusSnapshot()
        if current.state != .unloaded {
            return current
        }
        return await warmUp(interactive: true)
    }

    /// Explicit interactive unlock: reads/migrates vault with prompt allowed,
    /// retries pending legacy items and failed scans, and flushes any deferred
    /// writes even if the vault is already `.loaded`.
    @discardableResult
    public func unlock() async -> VaultStatusSnapshot {
        await warmUp(interactive: true)
    }

    /// Synchronous warm-up for non-async callers and tests.
    @discardableResult
    public func warmUpSync(interactive: Bool) -> VaultStatusSnapshot {
        performWarmUpSync(interactive: interactive)
    }

    // MARK: - Reads

    /// Reads one secret from the vault.
    ///
    /// Returns `nil` ONLY on confirmed absence (vault `.loaded` or `.empty`,
    /// `legacyScanSucceeded == true`, and account not in pending legacy sets).
    /// Throws `KeychainError.vaultUnavailable(_)` whenever the vault is locked,
    /// denied, corrupt, unloaded, has a pending legacy item for this account, or
    /// failed legacy enumeration.
    public func read(
        namespace: VaultNamespace,
        account: String,
        allowsPrompt: Bool = false
    ) throws -> String? {
        // Check deferred writes and loaded cache first.
        let fastResult: Result<String?, KeychainError>? = stateLock.withLock {
            let key = VaultKey(namespace: namespace, account: account)
            if let deferred = deferredWrites[key] {
                return .success(deferred.value)
            }
            switch internalState {
            case .loaded(let doc):
                let dict = namespace == .keys ? doc.keys : doc.sync
                if let value = dict[account] {
                    return .success(value)
                }
                let deleted = namespace == .keys ? doc.deletedLegacyKeys : doc.deletedLegacySyncKeys
                if deleted.contains(account) {
                    return .success(nil)
                }
                let pending = namespace == .keys ? pendingLegacyKeys : pendingLegacySyncKeys
                if pending.contains(account) {
                    return allowsPrompt ? nil : .failure(.vaultUnavailable(.pendingLegacy))
                }
                if !legacyScanSucceeded {
                    return allowsPrompt ? nil : .failure(.vaultUnavailable(.legacyScanFailed))
                }
                return .success(nil)
            case .empty:
                let pending = namespace == .keys ? pendingLegacyKeys : pendingLegacySyncKeys
                if pending.contains(account) {
                    return allowsPrompt ? nil : .failure(.vaultUnavailable(.pendingLegacy))
                }
                if !legacyScanSucceeded {
                    return allowsPrompt ? nil : .failure(.vaultUnavailable(.legacyScanFailed))
                }
                return .success(nil)
            case .corrupt:
                return allowsPrompt ? nil : .failure(.vaultUnavailable(.corrupt))
            case .lockedOrDenied(let status):
                return allowsPrompt ? nil : .failure(.vaultUnavailable(.lockedOrDenied(status)))
            case .unloaded:
                return nil
            }
        }

        if let fastResult {
            return try fastResult.get()
        }

        // Load/migrate synchronously (interactive only if caller explicitly asked).
        _ = performWarmUpSync(interactive: allowsPrompt)

        return try stateLock.withLock {
            let key = VaultKey(namespace: namespace, account: account)
            if let deferred = deferredWrites[key] {
                return deferred.value
            }
            switch internalState {
            case .loaded(let doc):
                let dict = namespace == .keys ? doc.keys : doc.sync
                if let value = dict[account] { return value }
                let deleted = namespace == .keys ? doc.deletedLegacyKeys : doc.deletedLegacySyncKeys
                if deleted.contains(account) { return nil }
                let pending = namespace == .keys ? pendingLegacyKeys : pendingLegacySyncKeys
                if pending.contains(account) { throw KeychainError.vaultUnavailable(.pendingLegacy) }
                if !legacyScanSucceeded { throw KeychainError.vaultUnavailable(.legacyScanFailed) }
                return nil
            case .empty:
                let pending = namespace == .keys ? pendingLegacyKeys : pendingLegacySyncKeys
                if pending.contains(account) { throw KeychainError.vaultUnavailable(.pendingLegacy) }
                if !legacyScanSucceeded { throw KeychainError.vaultUnavailable(.legacyScanFailed) }
                return nil
            case .corrupt:
                throw KeychainError.vaultUnavailable(.corrupt)
            case .lockedOrDenied(let status):
                throw KeychainError.vaultUnavailable(.lockedOrDenied(status))
            case .unloaded:
                throw KeychainError.vaultUnavailable(.notLoaded)
            }
        }
    }

    // MARK: - Explicit Writes & Deletes

    /// Explicit write (e.g. Settings Save, OAuth sign-in, Sync activation).
    /// Supersedes any older deferred write for the same key once committed,
    /// acquires the lockfile, re-reads and merges the latest vault, commits,
    /// and flushes eligible deferred writes.
    public func write(
        _ value: String,
        namespace: VaultNamespace,
        account: String,
        allowsPrompt: Bool = true
    ) throws {
        let key = VaultKey(namespace: namespace, account: account)
        try mutateVaultBlocking(allowsPrompt: allowsPrompt, supersedingKeys: [key]) { doc, pendingKeys, pendingSync in
            switch namespace {
            case .keys:
                doc.keys[account] = value
                doc.deletedLegacyKeys.remove(account)
                pendingKeys.remove(account)
            case .sync:
                doc.sync[account] = value
                doc.deletedLegacySyncKeys.remove(account)
                pendingSync.remove(account)
            }
            return [(namespace, account)]
        }
    }

    /// Explicit delete. Records a tombstone in `vault.v1` and commits BEFORE
    /// deleting the legacy item, so an interruption in between cannot resurrect
    /// the cleared secret.
    public func delete(
        namespace: VaultNamespace,
        account: String,
        allowsPrompt: Bool = true
    ) throws {
        let key = VaultKey(namespace: namespace, account: account)
        try mutateVaultBlocking(allowsPrompt: allowsPrompt, supersedingKeys: [key]) { doc, pendingKeys, pendingSync in
            switch namespace {
            case .keys:
                doc.keys.removeValue(forKey: account)
                doc.deletedLegacyKeys.insert(account)
                pendingKeys.remove(account)
            case .sync:
                doc.sync.removeValue(forKey: account)
                doc.deletedLegacySyncKeys.insert(account)
                pendingSync.remove(account)
            }
            return [(namespace, account)]
        }
    }

    /// Compare-and-delete under `flock`: deletes `account` ONLY if the durable
    /// vault value still equals `expectedValue`. Prevents a stale background
    /// revocation (e.g. a rejected refresh token from an earlier sign-in) from
    /// deleting a newer credential saved by another process.
    @discardableResult
    public func deleteIfMatching(
        _ expectedValue: String,
        namespace: VaultNamespace,
        account: String,
        allowsPrompt: Bool = false
    ) throws -> Bool {
        let key = VaultKey(namespace: namespace, account: account)
        return try fileLock.withLock(blocking: true) {
            let rawVault = try backend.read(
                service: keysService,
                account: Self.vaultAccount,
                allowsPrompt: allowsPrompt
            )
            var doc: VaultDocument
            if let rawVault {
                guard let decoded = try? JSONDecoder().decode(VaultDocument.self, from: rawVault) else {
                    stateLock.withLock { internalState = .corrupt }
                    throw KeychainError.vaultUnavailable(.corrupt)
                }
                doc = decoded
            } else {
                doc = VaultDocument()
            }

            let durableCurrent = namespace == .keys ? doc.keys[account] : doc.sync[account]
            guard durableCurrent == expectedValue else {
                stateLock.withLock {
                    internalState = (rawVault != nil || !doc.isEmpty) ? .loaded(doc) : .empty
                }
                return false
            }

            switch namespace {
            case .keys:
                doc.keys.removeValue(forKey: account)
                doc.deletedLegacyKeys.insert(account)
            case .sync:
                doc.sync.removeValue(forKey: account)
                doc.deletedLegacySyncKeys.insert(account)
            }

            let encoded = try JSONEncoder().encode(doc)
            try backend.write(
                encoded,
                service: keysService,
                account: Self.vaultAccount,
                label: "FrugalBar credential vault",
                allowsPrompt: allowsPrompt
            )

            stateLock.withLock {
                nextSeq += 1
                explicitSeq[key] = nextSeq
                deferredWrites.removeValue(forKey: key)
                if namespace == .keys {
                    pendingLegacyKeys.remove(account)
                } else {
                    pendingLegacySyncKeys.remove(account)
                }
                internalState = .loaded(doc)
            }

            try afterCommitBeforeLegacyDelete?()
            let svc = namespace == .keys ? keysService : syncService
            try? backend.delete(service: svc, account: account, allowsPrompt: allowsPrompt)
            return true
        }
    }

    /// Clears only the `sync` namespace (and records tombstones for any sync
    /// accounts), leaving provider `keys` untouched.
    ///
    /// Enumerates legacy sync items under `flock` and throws
    /// `.vaultUnavailable(.legacyScanFailed)` if enumeration fails so a clear
    /// never reports success while leaving an untombstoned legacy token behind.
    public func clearSync(allowsPrompt: Bool = true) throws {
        try fileLock.withLock(blocking: true) {
            let legacySyncAccounts: [String]
            do {
                legacySyncAccounts = try backend.listAccounts(service: syncService)
                    .filter { $0 != Self.vaultAccount && $0 != Self.doctorProbeAccount }
            } catch {
                stateLock.withLock { legacyScanSucceeded = false }
                throw KeychainError.vaultUnavailable(.legacyScanFailed)
            }

            let rawVault = try backend.read(
                service: keysService,
                account: Self.vaultAccount,
                allowsPrompt: allowsPrompt
            )
            var doc: VaultDocument
            if let rawVault {
                guard let decoded = try? JSONDecoder().decode(VaultDocument.self, from: rawVault) else {
                    stateLock.withLock { internalState = .corrupt }
                    throw KeychainError.vaultUnavailable(.corrupt)
                }
                doc = decoded
            } else {
                doc = VaultDocument()
            }

            let allSync: Set<String> = stateLock.withLock {
                var set = Set(legacySyncAccounts)
                set.formUnion(doc.sync.keys)
                if case .loaded(let cached) = internalState {
                    set.formUnion(cached.sync.keys)
                }
                set.formUnion(pendingLegacySyncKeys)
                for (k, _) in deferredWrites where k.namespace == .sync {
                    set.insert(k.account)
                }
                return set
            }

            var toDelete: [(VaultNamespace, String)] = []
            for acct in allSync {
                doc.sync.removeValue(forKey: acct)
                doc.deletedLegacySyncKeys.insert(acct)
                toDelete.append((.sync, acct))
            }

            // Commit vault + tombstones FIRST
            let encoded = try JSONEncoder().encode(doc)
            try backend.write(
                encoded,
                service: keysService,
                account: Self.vaultAccount,
                label: "FrugalBar credential vault",
                allowsPrompt: allowsPrompt
            )

            stateLock.withLock {
                nextSeq += 1
                let seq = nextSeq
                for acct in allSync {
                    let k = VaultKey(namespace: .sync, account: acct)
                    explicitSeq[k] = seq
                    deferredWrites.removeValue(forKey: k)
                }
                pendingLegacySyncKeys.subtract(allSync)
                internalState = .loaded(doc)
            }

            try afterCommitBeforeLegacyDelete?()

            for (ns, acct) in toDelete where acct != Self.vaultAccount {
                let svc = ns == .keys ? keysService : syncService
                try? backend.delete(service: svc, account: acct, allowsPrompt: allowsPrompt)
            }
        }
    }

    // MARK: - Non-blocking Deferred Background Writes (FB-R3-01)

    /// Records a background update (such as Gemini OAuth token renewal) in memory
    /// immediately and attempts a non-blocking, non-interactive persist
    /// (`LOCK_EX | LOCK_NB`, `LAContext.interactionNotAllowed = true`).
    ///
    /// Never blocks a provider deadline and never prompts. If the lock is
    /// contended or Keychain is locked, the write remains in memory and is
    /// flushed on the next explicit Unlock or Save — unless superseded by a newer
    /// explicit write, deletion, or cross-process change (`expectedPreviousValue`).
    @discardableResult
    public func writeDeferred(
        _ value: String,
        namespace: VaultNamespace,
        account: String,
        expectedPreviousValue: String? = nil
    ) -> DeferredWriteOutcome {
        let key = VaultKey(namespace: namespace, account: account)
        let queuedSeq: UInt64? = stateLock.withLock {
            let existingDeferred = deferredWrites[key]
            if let expected = expectedPreviousValue {
                let current: String?
                if let existingDeferred {
                    current = existingDeferred.value
                } else if case .loaded(let doc) = internalState {
                    current = namespace == .keys ? doc.keys[account] : doc.sync[account]
                } else {
                    current = nil
                }
                if current != expected {
                    return nil
                }
            }
            nextSeq += 1
            let seq = nextSeq
            // Preserve the original durable baseline across chained deferred
            // renewals (e.g. durable v1 -> deferred v2 -> deferred v3) so the
            // eventual flock CAS compares against v1, not v2.
            let durableBaseline = existingDeferred?.expectedPreviousValue ?? expectedPreviousValue
            deferredWrites[key] = DeferredWrite(
                value: value,
                seq: seq,
                expectedPreviousValue: durableBaseline
            )
            return seq
        }
        guard let seq = queuedSeq else { return .superseded }
        return flushDeferredNonBlockingOutcome(tracking: (key, seq))
    }

    /// Attempts to flush pending deferred writes without blocking (`LOCK_EX | LOCK_NB`)
    /// and without prompting (`allowsPrompt: false`). Returns `true` if flushed.
    @discardableResult
    public func flushDeferredNonBlocking() -> Bool {
        flushDeferredNonBlockingOutcome(tracking: nil) != .deferred
    }

    private func flushDeferredNonBlockingOutcome(
        tracking: (VaultKey, UInt64)?
    ) -> DeferredWriteOutcome {
        let snapshot: [VaultKey: DeferredWrite] = stateLock.withLock { deferredWrites }
        if snapshot.isEmpty {
            if let (trackedKey, trackedSeq) = tracking {
                let superseded = stateLock.withLock { isTrackedSeqSupersededLocked(trackedKey, seq: trackedSeq) }
                return superseded ? .superseded : .persisted
            }
            return .persisted
        }

        do {
            return try fileLock.withLock(blocking: false) {
                let raw = try backend.read(service: keysService, account: Self.vaultAccount, allowsPrompt: false)
                var doc: VaultDocument
                if let raw {
                    guard let decoded = try? JSONDecoder().decode(VaultDocument.self, from: raw) else {
                        stateLock.withLock { internalState = .corrupt }
                        return .deferred
                    }
                    doc = decoded
                } else {
                    doc = VaultDocument()
                }

                // Re-check under stateLock which deferred writes are still eligible
                // (not superseded by a newer explicit write or delete).
                let eligible: [VaultKey: DeferredWrite] = stateLock.withLock {
                    var out: [VaultKey: DeferredWrite] = [:]
                    for (k, dw) in deferredWrites {
                        if dw.seq > (explicitSeq[k] ?? 0) {
                            out[k] = dw
                        }
                    }
                    return out
                }
                if eligible.isEmpty {
                    if let (trackedKey, trackedSeq) = tracking {
                        let superseded = stateLock.withLock { isTrackedSeqSupersededLocked(trackedKey, seq: trackedSeq) }
                        return superseded ? .superseded : .persisted
                    }
                    return .persisted
                }

                var appliedDeferred: [VaultKey: DeferredWrite] = [:]
                var staleKeys: [VaultKey: UInt64] = [:]
                for (k, dw) in eligible {
                    let durableCurrent = k.namespace == .keys ? doc.keys[k.account] : doc.sync[k.account]
                    if let expected = dw.expectedPreviousValue, durableCurrent != expected {
                        staleKeys[k] = dw.seq
                        continue
                    }
                    switch k.namespace {
                    case .keys:
                        doc.keys[k.account] = dw.value
                        doc.deletedLegacyKeys.remove(k.account)
                    case .sync:
                        doc.sync[k.account] = dw.value
                        doc.deletedLegacySyncKeys.remove(k.account)
                    }
                    appliedDeferred[k] = dw
                }

                if !appliedDeferred.isEmpty {
                    let encoded = try JSONEncoder().encode(doc)
                    try backend.write(
                        encoded,
                        service: keysService,
                        account: Self.vaultAccount,
                        label: "FrugalBar credential vault",
                        allowsPrompt: false
                    )
                }

                stateLock.withLock {
                    reconcileCommittedDeferredWritesLocked(appliedDeferred)
                    for (k, seq) in staleKeys {
                        staleDeferredSeq[k] = max(staleDeferredSeq[k] ?? 0, seq)
                        if deferredWrites[k]?.seq == seq {
                            deferredWrites.removeValue(forKey: k)
                        }
                    }
                    // Always refresh the in-memory document from the durable read
                    // whenever any write applied OR any deferred write was rejected
                    // as stale, so another process's winning edit or deletion is
                    // reflected immediately on subsequent reads.
                    if !appliedDeferred.isEmpty || !staleKeys.isEmpty {
                        internalState = (raw != nil || !doc.isEmpty) ? .loaded(doc) : .empty
                    }
                }
                if let (trackedKey, trackedSeq) = tracking {
                    if staleKeys[trackedKey] == trackedSeq {
                        return .superseded
                    }
                    let superseded = stateLock.withLock {
                        isTrackedSeqSupersededLocked(trackedKey, seq: trackedSeq)
                    }
                    if superseded {
                        return .superseded
                    }
                }
                return .persisted
            }
        } catch {
            // Contended lock (wouldBlock) or locked Keychain (errSecInteractionNotAllowed):
            // recheck whether an explicit write, delete, or stale rejection already
            // superseded this entry; otherwise keep deferred writes in memory.
            if let (trackedKey, trackedSeq) = tracking {
                let superseded = stateLock.withLock {
                    isTrackedSeqSupersededLocked(trackedKey, seq: trackedSeq)
                }
                if superseded {
                    return .superseded
                }
            }
            return .deferred
        }
    }

    /// Returns true if `seq` for `key` was superseded by an explicit mutation
    /// or rejected as stale by any flush path. Caller must hold `stateLock`.
    private func isTrackedSeqSupersededLocked(_ key: VaultKey, seq: UInt64) -> Bool {
        (explicitSeq[key] ?? 0) >= seq || (staleDeferredSeq[key] ?? 0) >= seq
    }

    /// Reconciles `deferredWrites` after `applied` entries have been durably
    /// committed to `vault.v1`. Caller must hold `stateLock`.
    ///
    /// If a newer chained deferred write arrived for the same key while `flushed`
    /// was being committed, its `expectedPreviousValue` still references the old
    /// durable baseline; advance it to `flushed.value` so the next flush compares
    /// against the newly committed durable value instead of rejecting it as stale.
    private func reconcileCommittedDeferredWritesLocked(_ applied: [VaultKey: DeferredWrite]) {
        for (k, flushed) in applied {
            guard let current = deferredWrites[k] else { continue }
            if current.seq == flushed.seq {
                deferredWrites.removeValue(forKey: k)
            } else if current.seq > flushed.seq,
                      current.expectedPreviousValue == flushed.expectedPreviousValue {
                deferredWrites[k] = DeferredWrite(
                    value: current.value,
                    seq: current.seq,
                    expectedPreviousValue: flushed.value
                )
            }
        }
    }

    // MARK: - Internal Read-Merge-Commit

    private func performWarmUpSync(interactive: Bool) -> VaultStatusSnapshot {
        do {
            return try fileLock.withLock(blocking: true) {
                // 1. Read vault.v1
                let rawVault: Data?
                do {
                    rawVault = try backend.read(
                        service: keysService,
                        account: Self.vaultAccount,
                        allowsPrompt: interactive
                    )
                } catch let KeychainError.unknown(status) {
                    stateLock.withLock {
                        // On a passive refresh after the user already loaded the
                        // vault (e.g. via "Allow" once in SecurityAgent), an
                        // errSecInteractionNotAllowed denial means macOS requires
                        // another prompt to re-read — keep the loaded in-memory
                        // credentials instead of wiping them out.
                        if !interactive,
                           status == errSecInteractionNotAllowed,
                           case .loaded = internalState {
                            return
                        }
                        internalState = .lockedOrDenied(status)
                    }
                    return statusSnapshot()
                } catch {
                    stateLock.withLock { internalState = .lockedOrDenied(errSecAuthFailed) }
                    return statusSnapshot()
                }

                let hadExistingVault = rawVault != nil
                let baseDoc: VaultDocument
                if let rawVault {
                    guard let decoded = try? JSONDecoder().decode(VaultDocument.self, from: rawVault) else {
                        stateLock.withLock { internalState = .corrupt }
                        return statusSnapshot()
                    }
                    baseDoc = decoded
                } else {
                    baseDoc = VaultDocument()
                }
                var doc = baseDoc

                // 2. Enumerate legacy items in both services, always excluding
                // the vault itself and the doctor probe account. On passive
                // refreshes after a clean scan with no pending legacy items, skip
                // legacy enumeration while still refreshing `vault.v1` from disk.
                let skipLegacyScan = !interactive && stateLock.withLock {
                    legacyScanSucceeded && pendingLegacyKeys.isEmpty && pendingLegacySyncKeys.isEmpty
                }
                var scanOK = true
                var legacyKeyAccounts: [String] = []
                var legacySyncAccounts: [String] = []

                if !skipLegacyScan {
                    do {
                        legacyKeyAccounts = try backend.listAccounts(service: keysService)
                            .filter { $0 != Self.vaultAccount && $0 != Self.doctorProbeAccount }
                    } catch {
                        scanOK = false
                    }

                    do {
                        legacySyncAccounts = try backend.listAccounts(service: syncService)
                            .filter { $0 != Self.vaultAccount && $0 != Self.doctorProbeAccount }
                    } catch {
                        scanOK = false
                    }
                }

                // 3. Migrate legacy items
                var dirty = false
                var newPendingKeys: Set<String> = []
                var newPendingSync: Set<String> = []
                var migratedKeys: Set<String> = []
                var migratedSync: Set<String> = []
                var legacyToDelete: [(VaultNamespace, String)] = []

                for account in legacyKeyAccounts {
                    if doc.deletedLegacyKeys.contains(account) {
                        legacyToDelete.append((.keys, account))
                        continue
                    }
                    if doc.keys[account] != nil {
                        legacyToDelete.append((.keys, account))
                        continue
                    }
                    do {
                        if let data = try backend.read(service: keysService, account: account, allowsPrompt: interactive) {
                            if let str = String(data: data, encoding: .utf8) {
                                doc.keys[account] = str
                                migratedKeys.insert(account)
                                dirty = true
                                legacyToDelete.append((.keys, account))
                            } else {
                                newPendingKeys.insert(account)
                            }
                        }
                    } catch {
                        newPendingKeys.insert(account)
                    }
                }

                for account in legacySyncAccounts {
                    if doc.deletedLegacySyncKeys.contains(account) {
                        legacyToDelete.append((.sync, account))
                        continue
                    }
                    if doc.sync[account] != nil {
                        legacyToDelete.append((.sync, account))
                        continue
                    }
                    do {
                        if let data = try backend.read(service: syncService, account: account, allowsPrompt: interactive) {
                            if let str = String(data: data, encoding: .utf8) {
                                doc.sync[account] = str
                                migratedSync.insert(account)
                                dirty = true
                                legacyToDelete.append((.sync, account))
                            } else {
                                newPendingSync.insert(account)
                            }
                        }
                    } catch {
                        newPendingSync.insert(account)
                    }
                }

                // 4. Merge any surviving deferred writes (respecting CAS baseline)
                let eligibleDeferred: [VaultKey: DeferredWrite] = stateLock.withLock {
                    var out: [VaultKey: DeferredWrite] = [:]
                    for (k, dw) in deferredWrites {
                        if dw.seq > (explicitSeq[k] ?? 0) {
                            out[k] = dw
                        }
                    }
                    return out
                }
                var appliedDeferred: [VaultKey: DeferredWrite] = [:]
                var staleDeferred: [VaultKey: UInt64] = [:]
                for (k, dw) in eligibleDeferred {
                    let durableCurrent = k.namespace == .keys ? doc.keys[k.account] : doc.sync[k.account]
                    if let expected = dw.expectedPreviousValue, durableCurrent != expected {
                        staleDeferred[k] = dw.seq
                        continue
                    }
                    switch k.namespace {
                    case .keys:
                        doc.keys[k.account] = dw.value
                        doc.deletedLegacyKeys.remove(k.account)
                        newPendingKeys.remove(k.account)
                    case .sync:
                        doc.sync[k.account] = dw.value
                        doc.deletedLegacySyncKeys.remove(k.account)
                        newPendingSync.remove(k.account)
                    }
                    appliedDeferred[k] = dw
                    dirty = true
                }

                // 5. Commit vault BEFORE deleting legacy items
                var commitSucceeded = true
                if dirty {
                    do {
                        let encoded = try JSONEncoder().encode(doc)
                        try backend.write(
                            encoded,
                            service: keysService,
                            account: Self.vaultAccount,
                            label: "FrugalBar credential vault",
                            allowsPrompt: interactive
                        )
                    } catch {
                        commitSucceeded = false
                    }
                }

                if commitSucceeded {
                    // Best-effort hook for crash/interruption tests
                    if dirty {
                        try? afterCommitBeforeLegacyDelete?()
                    }
                    // Delete migrated or tombstoned legacy items only after commit succeeded
                    for (ns, acct) in legacyToDelete where acct != Self.vaultAccount {
                        let svc = ns == .keys ? keysService : syncService
                        try? backend.delete(service: svc, account: acct, allowsPrompt: interactive)
                    }
                } else {
                    // Commit failed: any newly migrated accounts are NOT durable in
                    // vault.v1 yet, so keep them pending and publish only the durable
                    // base document so a later unrelated save can never drop them
                    // into confirmed absence.
                    newPendingKeys.formUnion(migratedKeys)
                    newPendingSync.formUnion(migratedSync)
                }

                let publishedDoc = commitSucceeded ? doc : baseDoc

                stateLock.withLock {
                    for (k, seq) in staleDeferred {
                        staleDeferredSeq[k] = max(staleDeferredSeq[k] ?? 0, seq)
                        if deferredWrites[k]?.seq == seq {
                            deferredWrites.removeValue(forKey: k)
                        }
                    }
                    if commitSucceeded {
                        reconcileCommittedDeferredWritesLocked(appliedDeferred)
                    }
                    pendingLegacyKeys = newPendingKeys
                    pendingLegacySyncKeys = newPendingSync
                    legacyScanSucceeded = scanOK
                    if hadExistingVault || !publishedDoc.isEmpty {
                        internalState = .loaded(publishedDoc)
                    } else {
                        internalState = .empty
                    }
                }

                return statusSnapshot()
            }
        } catch {
            return statusSnapshot()
        }
    }

    private func mutateVaultBlocking(
        allowsPrompt: Bool,
        supersedingKeys: Set<VaultKey> = [],
        mutate: (inout VaultDocument, inout Set<String>, inout Set<String>) -> [(VaultNamespace, String)]
    ) throws {
        try fileLock.withLock(blocking: true) {
            let rawVault = try backend.read(
                service: keysService,
                account: Self.vaultAccount,
                allowsPrompt: allowsPrompt
            )
            var doc: VaultDocument
            if let rawVault {
                guard let decoded = try? JSONDecoder().decode(VaultDocument.self, from: rawVault) else {
                    stateLock.withLock { internalState = .corrupt }
                    throw KeychainError.vaultUnavailable(.corrupt)
                }
                doc = decoded
            } else {
                doc = VaultDocument()
            }

            // Merge surviving deferred writes for unrelated keys so explicit Save also flushes them
            let eligibleDeferred: [VaultKey: DeferredWrite] = stateLock.withLock {
                var out: [VaultKey: DeferredWrite] = [:]
                for (k, dw) in deferredWrites where !supersedingKeys.contains(k) {
                    if dw.seq > (explicitSeq[k] ?? 0) {
                        out[k] = dw
                    }
                }
                return out
            }
            var appliedDeferred: [VaultKey: DeferredWrite] = [:]
            var staleDeferred: [VaultKey: UInt64] = [:]
            for (k, dw) in eligibleDeferred {
                let durableCurrent = k.namespace == .keys ? doc.keys[k.account] : doc.sync[k.account]
                if let expected = dw.expectedPreviousValue, durableCurrent != expected {
                    staleDeferred[k] = dw.seq
                    continue
                }
                switch k.namespace {
                case .keys:
                    doc.keys[k.account] = dw.value
                    doc.deletedLegacyKeys.remove(k.account)
                case .sync:
                    doc.sync[k.account] = dw.value
                    doc.deletedLegacySyncKeys.remove(k.account)
                }
                appliedDeferred[k] = dw
            }

            var pendingKeysCopy = stateLock.withLock { pendingLegacyKeys }
            var pendingSyncCopy = stateLock.withLock { pendingLegacySyncKeys }
            let legacyToDelete = mutate(&doc, &pendingKeysCopy, &pendingSyncCopy)

            // Commit vault + tombstones FIRST
            let encoded = try JSONEncoder().encode(doc)
            try backend.write(
                encoded,
                service: keysService,
                account: Self.vaultAccount,
                label: "FrugalBar credential vault",
                allowsPrompt: allowsPrompt
            )

            // Update in-memory state and supersede deferred writes ONLY AFTER commit succeeds
            stateLock.withLock {
                for (k, seq) in staleDeferred {
                    staleDeferredSeq[k] = max(staleDeferredSeq[k] ?? 0, seq)
                    if deferredWrites[k]?.seq == seq {
                        deferredWrites.removeValue(forKey: k)
                    }
                }
                reconcileCommittedDeferredWritesLocked(appliedDeferred)
                if !supersedingKeys.isEmpty {
                    nextSeq += 1
                    let seq = nextSeq
                    for k in supersedingKeys {
                        explicitSeq[k] = seq
                        deferredWrites.removeValue(forKey: k)
                    }
                }
                pendingLegacyKeys = pendingKeysCopy
                pendingLegacySyncKeys = pendingSyncCopy
                internalState = .loaded(doc)
            }

            // Interruption hook (for crash-recovery tests)
            try afterCommitBeforeLegacyDelete?()

            // Delete legacy items AFTER commit
            for (ns, acct) in legacyToDelete {
                let svc = ns == .keys ? keysService : syncService
                try? backend.delete(service: svc, account: acct, allowsPrompt: allowsPrompt)
            }
        }
    }
}
