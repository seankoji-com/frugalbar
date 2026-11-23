import Foundation
import Security
import Testing
@testable import QuotaBarCore

// MARK: - Hermetic In-Memory Keychain Backend

final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    struct ItemKey: Hashable {
        let service: String
        let account: String
    }

    struct Call: Equatable {
        enum Kind: Equatable { case read, write, delete, list }
        let kind: Kind
        let service: String
        let account: String?
        let allowsPrompt: Bool?
    }

    private let lock = NSLock()
    private var storage: [ItemKey: Data] = [:]
    private var deniedReads: [ItemKey: OSStatus] = [:]
    private var deniedWrites: [ItemKey: OSStatus] = [:]
    private var failListServices: [String: OSStatus] = [:]
    private var failNonInteractiveWrites = false
    private(set) var calls: [Call] = []

    func seed(service: String, account: String, value: String) {
        lock.withLock { storage[ItemKey(service: service, account: account)] = Data(value.utf8) }
    }

    func seedRaw(service: String, account: String, data: Data) {
        lock.withLock { storage[ItemKey(service: service, account: account)] = data }
    }

    func rawData(service: String, account: String) -> Data? {
        lock.withLock { storage[ItemKey(service: service, account: account)] }
    }

    func setReadDenied(service: String, account: String, status: OSStatus?) {
        lock.withLock {
            let key = ItemKey(service: service, account: account)
            if let status { deniedReads[key] = status } else { deniedReads.removeValue(forKey: key) }
        }
    }

    func setWriteDenied(service: String, account: String, status: OSStatus?) {
        lock.withLock {
            let key = ItemKey(service: service, account: account)
            if let status { deniedWrites[key] = status } else { deniedWrites.removeValue(forKey: key) }
        }
    }

    func setFailNonInteractiveWrites(_ fail: Bool) {
        lock.withLock { failNonInteractiveWrites = fail }
    }

    func setListFailure(service: String, status: OSStatus?) {
        lock.withLock {
            if let status { failListServices[service] = status } else { failListServices.removeValue(forKey: service) }
        }
    }

    func promptCallCount() -> Int {
        lock.withLock { calls.filter { $0.allowsPrompt == true }.count }
    }

    func recordedCalls() -> [Call] {
        lock.withLock { calls }
    }

    func resetCalls() {
        lock.withLock { calls.removeAll() }
    }

    func read(service: String, account: String, allowsPrompt: Bool) throws -> Data? {
        try lock.withLock {
            calls.append(Call(kind: .read, service: service, account: account, allowsPrompt: allowsPrompt))
            let key = ItemKey(service: service, account: account)
            if let status = deniedReads[key] {
                throw KeychainError.unknown(status)
            }
            return storage[key]
        }
    }

    func write(_ data: Data, service: String, account: String, label: String?, allowsPrompt: Bool) throws {
        try lock.withLock {
            calls.append(Call(kind: .write, service: service, account: account, allowsPrompt: allowsPrompt))
            let key = ItemKey(service: service, account: account)
            if !allowsPrompt && failNonInteractiveWrites {
                throw KeychainError.unknown(errSecInteractionNotAllowed)
            }
            if let status = deniedWrites[key] {
                throw KeychainError.unknown(status)
            }
            storage[key] = data
        }
    }

    func delete(service: String, account: String, allowsPrompt: Bool) throws {
        lock.withLock {
            calls.append(Call(kind: .delete, service: service, account: account, allowsPrompt: allowsPrompt))
            storage.removeValue(forKey: ItemKey(service: service, account: account))
        }
    }

    func listAccounts(service: String) throws -> [String] {
        try lock.withLock {
            calls.append(Call(kind: .list, service: service, account: nil, allowsPrompt: nil))
            if let status = failListServices[service] {
                throw KeychainError.unknown(status)
            }
            return storage.keys.filter { $0.service == service }.map(\.account).sorted()
        }
    }
}

private func makeTempLockURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("frugalbar-vault-test-\(UUID().uuidString).lock")
}

// MARK: - Vault, Locking, Migration & Doctor Tests

@Suite("KeychainVault")
struct KeychainVaultTests {

    @Test("two writers sharing a lockfile and backend preserve both keys")
    func twoWritersMergeWithoutLoss() throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let writerA = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        let writerB = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)

        try writerA.write("sk-claude", namespace: .keys, account: "claude", allowsPrompt: true)
        try writerB.write("sk-openai", namespace: .keys, account: "openai", allowsPrompt: true)

        let reader = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        _ = reader.warmUpSync(interactive: false)
        #expect(try reader.read(namespace: .keys, account: "claude") == "sk-claude")
        #expect(try reader.read(namespace: .keys, account: "openai") == "sk-openai")
    }

    @Test("interruption after tombstone commit and before legacy deletion cannot restore a cleared key")
    func tombstonePreventsResurrectionAfterCrash() throws {
        struct SimulatedCrash: Error {}
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        backend.seed(service: "test.keys", account: "claude", value: "old-secret")

        let vault1 = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        vault1.afterCommitBeforeLegacyDelete = { throw SimulatedCrash() }

        #expect(throws: SimulatedCrash.self) {
            try vault1.delete(namespace: .keys, account: "claude", allowsPrompt: true)
        }
        // Legacy item is still present in the backend because delete was interrupted!
        #expect(backend.rawData(service: "test.keys", account: "claude") != nil)

        // Fresh process warms up: tombstone must block resurrection and clean up legacy item.
        let vault2 = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        _ = vault2.warmUpSync(interactive: false)
        #expect(try vault2.read(namespace: .keys, account: "claude") == nil)
        #expect(backend.rawData(service: "test.keys", account: "claude") == nil)
    }

    @Test("sync-only clear preserves provider secrets")
    func syncOnlyClearPreservesProviderKeys() throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        try vault.write("sk-provider", namespace: .keys, account: "openrouter", allowsPrompt: true)
        try vault.write("rt-sync", namespace: .sync, account: SyncSecretAccount.refreshToken, allowsPrompt: true)
        try vault.write("pub-123", namespace: .sync, account: SyncSecretAccount.publisherId, allowsPrompt: true)

        try vault.clearSync(allowsPrompt: true)

        let fresh = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        _ = fresh.warmUpSync(interactive: false)
        #expect(try fresh.read(namespace: .keys, account: "openrouter") == "sk-provider")
        #expect(try fresh.read(namespace: .sync, account: SyncSecretAccount.refreshToken) == nil)
        #expect(try fresh.read(namespace: .sync, account: SyncSecretAccount.publisherId) == nil)
    }

    @Test("corrupt vault and failed legacy enumeration never return nil as confirmed absence")
    func corruptAndFailedScanNeverReturnNil() throws {
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        // 1. Corrupt vault
        let corruptBackend = InMemoryKeychainBackend()
        let garbage = Data("{not valid json".utf8)
        corruptBackend.seedRaw(service: "test.keys", account: KeychainVault.vaultAccount, data: garbage)
        let corruptVault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: corruptBackend, lockFileURL: lockURL)
        let corruptStatus = corruptVault.warmUpSync(interactive: false)
        #expect(corruptStatus.isCorrupt)
        #expect(throws: KeychainError.vaultUnavailable(.corrupt)) {
            _ = try corruptVault.read(namespace: .sync, account: SyncSecretAccount.refreshToken)
        }
        // Corrupt data must not be overwritten.
        #expect(corruptBackend.rawData(service: "test.keys", account: KeychainVault.vaultAccount) == garbage)

        // 2. Failed legacy enumeration
        let scanFailBackend = InMemoryKeychainBackend()
        scanFailBackend.setListFailure(service: "test.sync", status: errSecAuthFailed)
        let scanFailVault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: scanFailBackend, lockFileURL: lockURL)
        let scanStatus = scanFailVault.warmUpSync(interactive: false)
        #expect(!scanStatus.legacyScanSucceeded)
        #expect(scanStatus.needsUnlock)
        #expect(throws: KeychainError.vaultUnavailable(.legacyScanFailed)) {
            _ = try scanFailVault.read(namespace: .sync, account: SyncSecretAccount.refreshToken)
        }
    }

    @Test("FB-R3-01: deferred write stays non-blocking when lock or Keychain is unavailable, flushes on Unlock even from .loaded, and yields to explicit write or delete")
    func deferredWriteLifecycleAndPrecedence() throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        try vault.write("initial", namespace: .keys, account: "gemini.oauth.session", allowsPrompt: true)
        _ = vault.warmUpSync(interactive: false)
        #expect(vault.statusSnapshot().state == .loaded)

        // Contended lockfile: hold LOCK_EX externally so writeDeferred cannot block.
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)
        let flushedWhileLocked = vault.writeDeferred("renewed-token", namespace: .keys, account: "gemini.oauth.session")
        #expect(flushedWhileLocked == .deferred)
        #expect(vault.cachedValue(namespace: .keys, account: "gemini.oauth.session") == "renewed-token")
        #expect(vault.statusSnapshot().hasPendingWrites)
        _ = flock(fd, LOCK_UN)
        close(fd)

        // Unlock from .loaded must flush the deferred write!
        let statusAfterUnlock = vault.warmUpSync(interactive: true)
        #expect(!statusAfterUnlock.hasPendingWrites)
        let reader = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        _ = reader.warmUpSync(interactive: false)
        #expect(try reader.read(namespace: .keys, account: "gemini.oauth.session") == "renewed-token")

        // Now test non-interactive write denial + explicit replacement/deletion superseding deferred write.
        backend.setFailNonInteractiveWrites(true)
        #expect(vault.writeDeferred("stale-renewal", namespace: .keys, account: "gemini.oauth.session") == .deferred)
        #expect(vault.statusSnapshot().hasPendingWrites)

        // Explicit replacement supersedes deferred write.
        try vault.write("explicit-new", namespace: .keys, account: "gemini.oauth.session", allowsPrompt: true)
        #expect(!vault.statusSnapshot().hasPendingWrites)
        #expect(try vault.read(namespace: .keys, account: "gemini.oauth.session") == "explicit-new")

        // Deferred write followed by explicit delete: delete wins even after Unlock.
        #expect(vault.writeDeferred("stale-renewal-2", namespace: .keys, account: "gemini.oauth.session") == .deferred)
        try vault.delete(namespace: .keys, account: "gemini.oauth.session", allowsPrompt: true)
        backend.setFailNonInteractiveWrites(false)
        _ = vault.warmUpSync(interactive: true)
        #expect(try vault.read(namespace: .keys, account: "gemini.oauth.session") == nil)
    }

    @Test("doctor probe uses raw non-interactive backend for set, get, and deferred delete without touching vault.v1")
    func doctorProbeUsesRawNonInteractiveBackend() {
        let backend = InMemoryKeychainBackend()
        let result = CLIArguments.keychainRoundTripResult(
            label: "com.quotabar.doctor.probe.test",
            service: "test.keys",
            backend: backend
        )
        switch result {
        case .success: break
        case .failure(let error): Issue.record("expected doctor probe success, got \(error)")
        }

        let calls = backend.recordedCalls()
        #expect(calls.count == 3)
        #expect(calls[0] == .init(kind: .write, service: "test.keys", account: "com.quotabar.doctor.probe.test", allowsPrompt: false))
        #expect(calls[1] == .init(kind: .read, service: "test.keys", account: "com.quotabar.doctor.probe.test", allowsPrompt: false))
        #expect(calls[2] == .init(kind: .delete, service: "test.keys", account: "com.quotabar.doctor.probe.test", allowsPrompt: false))
        #expect(backend.rawData(service: "test.keys", account: KeychainVault.vaultAccount) == nil)
    }

    @Test("partial migration with denied refreshToken pauses Sync without needsSignIn and resumes on unlock")
    func syncPausesOnDeniedRefreshTokenAndResumesOnUnlock() async throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        backend.seed(service: "test.sync", account: SyncSecretAccount.refreshToken, value: "rt-live")
        backend.seed(service: "test.sync", account: SyncSecretAccount.publisherId, value: "pub-live")
        backend.setReadDenied(service: "test.sync", account: SyncSecretAccount.refreshToken, status: errSecAuthFailed)

        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        let initialStatus = vault.warmUpSync(interactive: false)
        #expect(initialStatus.pendingLegacySyncKeys.contains(SyncSecretAccount.refreshToken))
        #expect(initialStatus.needsUnlock)

        let secrets = KeychainSyncSecretStore(service: "test.sync", vault: vault)
        let stateStore = InMemorySyncStateStore()
        let clock = FakeSyncClock()
        let transport = ScriptedSyncTransport()

        // Seed active state directly so we simulate a cold restart with an active sync session.
        var active = SyncPersistentState()
        active.phase = .active
        active.account = SyncAccount(permissionId: "perm-1", email: "user@example.com")
        try stateStore.save(active)

        let restarted = SyncPublisher(
            configuration: SyncClientConfiguration(clientID: "cid", clientSecret: "csec"),
            transport: transport,
            secrets: secrets,
            stateStore: stateStore,
            clock: clock,
            label: { "TestMac" }
        )
        await restarted.submit(SyncExportSource(snapshots: []))
        await restarted.tick()

        // Must NOT persist needsSignIn = true!
        let pausedStatus = await restarted.status()
        #expect(!pausedStatus.needsSignIn)
        #expect(pausedStatus.phase == SyncPhase.active)
        #expect(try stateStore.load().needsSignIn == false)

        // Lift denial and unlock vault: refreshToken migrates and publish can proceed.
        backend.setReadDenied(service: "test.sync", account: SyncSecretAccount.refreshToken, status: nil)
        _ = await vault.unlock()
        #expect(try secrets.read(SyncSecretAccount.refreshToken) == "rt-live")
        await restarted.vaultDidUnlock()
        #expect(await restarted.status().needsSignIn == false)
    }

    @Test("partial migration with denied publisherId preserves real publisherId during Stop and completes after unlock")
    func stopPreservesRealPublisherIdWhenDenied() async throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        backend.seed(service: "test.sync", account: SyncSecretAccount.refreshToken, value: "rt-live")
        backend.seed(service: "test.sync", account: SyncSecretAccount.publisherId, value: "pub-real-id")
        backend.setReadDenied(service: "test.sync", account: SyncSecretAccount.publisherId, status: errSecAuthFailed)

        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        _ = vault.warmUpSync(interactive: false)
        let secrets = KeychainSyncSecretStore(service: "test.sync", vault: vault)

        let stateStore = InMemorySyncStateStore()
        var active = SyncPersistentState()
        active.phase = .active
        active.account = SyncAccount(permissionId: "perm-1", email: "user@example.com")
        try stateStore.save(active)

        let publisher = SyncPublisher(
            configuration: SyncClientConfiguration(clientID: "cid", clientSecret: "csec"),
            transport: ScriptedSyncTransport(),
            secrets: secrets,
            stateStore: stateStore,
            clock: FakeSyncClock(),
            label: { "TestMac" }
        )

        await publisher.stop()
        // Must NOT have persisted an empty publisherId!
        let persisted = try stateStore.load()
        #expect(persisted.phase == .active)
        #expect(persisted.cleanup == nil)

        // Unlock vault: now stop() reads the real publisherId and enters .stopping with it.
        backend.setReadDenied(service: "test.sync", account: SyncSecretAccount.publisherId, status: nil)
        _ = await vault.unlock()
        await publisher.vaultDidUnlock()
        await publisher.setStopCheckpoint { gap in
            if gap == .afterStoppingWrite { throw CancellationError() }
        }
        await publisher.tick()

        let stoppingState = try stateStore.load()
        #expect(stoppingState.phase == .stopping)
        #expect(stoppingState.cleanup?.publisherId == "pub-real-id")
    }

    @Test("unfinished Stop on corrupt vault or locked refreshToken never sets cleanup.authLost = true")
    func unfinishedStopNeverMarksAuthLostOnUnavailableVault() async throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        backend.seedRaw(service: "test.keys", account: KeychainVault.vaultAccount, data: Data("corrupt".utf8))
        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        _ = vault.warmUpSync(interactive: false)

        let stateStore = InMemorySyncStateStore()
        var stopping = SyncPersistentState()
        stopping.phase = .stopping
        stopping.account = SyncAccount(permissionId: "perm-1", email: "user@example.com")
        stopping.cleanup = SyncCleanupRecord(
            publisherId: "pub-1",
            account: stopping.account,
            refreshTokenAccount: SyncSecretAccount.refreshToken,
            relistAt: [Date(), Date()],
            completed: [],
            authLost: false,
            publishedThisSession: true
        )
        try stateStore.save(stopping)

        let publisher = SyncPublisher(
            configuration: SyncClientConfiguration(clientID: "cid", clientSecret: "csec"),
            transport: ScriptedSyncTransport(),
            secrets: KeychainSyncSecretStore(service: "test.sync", vault: vault),
            stateStore: stateStore,
            clock: FakeSyncClock(),
            label: { "TestMac" }
        )

        await publisher.resume()
        let status = await publisher.status()
        #expect(status.phase == SyncPhase.stopping)
        #expect(!status.cleanupNeedsSignIn)
        #expect(try stateStore.load().cleanup?.authLost == false)
    }

    @Test("warm-up delayed beyond perProviderTimeout does not time out discovery or providers")
    func warmUpOutsideDiscoveryAndProviderDeadlines() async {
        let warmUpCompleted = LockedFlag()
        let policy = CachePolicy(
            cacheTTL: 60,
            backgroundRefreshInterval: 120,
            perProviderTimeout: 0.15,
            minPollInterval: 0
        )
        let manager = QuotaManager(
            cachePolicy: policy,
            providerFactory: {
                [FastMeasuredProvider(vendorId: .openrouter, checkWarmUp: { warmUpCompleted.value })]
            },
            claudeProviderFactory: {
                [FastMeasuredProvider(vendorId: .claude, checkWarmUp: { warmUpCompleted.value })]
            },
            vaultWarmUp: { _ in
                try? await Task.sleep(for: .milliseconds(250))
                warmUpCompleted.set()
            }
        )

        let result = await manager.refresh()
        #expect(warmUpCompleted.value)
        #expect(result[VendorIdentifier.openrouter.rawValue]?.status == .healthy)
        #expect(result[VendorIdentifier.claude.rawValue]?.status == .healthy)
    }

    @Test("FB-R3-03: forceRefresh defaults to non-interactive unlock while explicit flag carries interactive intent")
    func interactiveUnlockSeparatedFromForceRefresh() async {
        let recorded = RecordedBools()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { [] },
            vaultWarmUp: { interactive in
                recorded.append(interactive)
            }
        )

        _ = await manager.forceRefresh()
        _ = await manager.forceRefresh(allowInteractiveUnlock: false)
        _ = await manager.forceRefresh(allowInteractiveUnlock: true)

        #expect(recorded.values == [false, false, true])
    }

    @Test("R1-01: warming a fresh vault sharing keysService/syncService never deletes vault.v1")
    func reopenCustomSyncVaultPreservesVault() throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        // Even if someone constructs a vault where keysService == syncService,
        // vault.v1 must be excluded from legacy sync scans and deletions.
        let writer = KeychainVault(keysService: "custom.svc", syncService: "custom.svc", backend: backend, lockFileURL: lockURL)
        try writer.write("rt-1", namespace: .sync, account: SyncSecretAccount.refreshToken)

        let reopened = KeychainVault(keysService: "custom.svc", syncService: "custom.svc", backend: backend, lockFileURL: lockURL)
        _ = reopened.warmUpSync(interactive: false)
        #expect(try reopened.read(namespace: .sync, account: SyncSecretAccount.refreshToken) == "rt-1")
        #expect(backend.rawData(service: "custom.svc", account: KeychainVault.vaultAccount) != nil)

        // And KeychainSyncSecretStore with a custom service separates vault and legacy services.
        let customStore = KeychainSyncSecretStore(service: "com.quotabar.sync.custom-test")
        #expect(customStore.vault.keysService != customStore.vault.syncService)
    }

    @Test("R1-02: failed migration commit keeps uncommitted legacy accounts pending across later saves")
    func failedMigrationCommitKeepsLegacyAccountsPending() throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        backend.seed(service: "test.sync", account: SyncSecretAccount.publisherId, value: "pub-legacy")
        backend.seedRaw(service: "test.keys", account: "bad-utf8", data: Data([0xFF, 0xFE]))
        backend.setWriteDenied(service: "test.keys", account: KeychainVault.vaultAccount, status: errSecInteractionNotAllowed)

        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        let status = vault.warmUpSync(interactive: false)
        #expect(status.pendingLegacySyncKeys.contains(SyncSecretAccount.publisherId))
        #expect(status.pendingLegacyKeys.contains("bad-utf8"))

        // Lift vault write denial and save an unrelated key: publisherId must STILL be pending, not nil!
        backend.setWriteDenied(service: "test.keys", account: KeychainVault.vaultAccount, status: nil)
        try vault.write("sk-other", namespace: .keys, account: "openrouter")
        #expect(throws: KeychainError.vaultUnavailable(.pendingLegacy)) {
            _ = try vault.read(namespace: .sync, account: SyncSecretAccount.publisherId)
        }
    }

    @Test("R1-03: late deferred renewal with stale expectedPreviousValue yields to newer explicit or cross-process edit")
    func lateDeferredWriteYieldsToNewerEdit() throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let vaultA = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        let vaultB = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)

        try vaultA.write("session-v1", namespace: .keys, account: "gemini-oauth")
        _ = vaultB.warmUpSync(interactive: false)

        // Another process replaces the session with session-v2 while vaultA's refresh was in flight.
        try vaultB.write("session-v2", namespace: .keys, account: "gemini-oauth")

        // vaultA's late deferred renewal carries expectedPreviousValue: "session-v1" and must be dropped.
        _ = vaultA.writeDeferred("session-renewed-from-v1", namespace: .keys, account: "gemini-oauth", expectedPreviousValue: "session-v1")

        let verifier = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        _ = verifier.warmUpSync(interactive: false)
        #expect(try verifier.read(namespace: .keys, account: "gemini-oauth") == "session-v2")
    }

    @Test("R1-04: clearSync fails closed when legacy sync enumeration fails")
    func clearSyncFailsClosedOnEnumerationError() throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        backend.seed(service: "test.sync", account: SyncSecretAccount.refreshToken, value: "rt-live")
        backend.setListFailure(service: "test.sync", status: errSecAuthFailed)

        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        #expect(throws: KeychainError.vaultUnavailable(.legacyScanFailed)) {
            try vault.clearSync()
        }
    }

    @Test("R1-05: SyncPublisher retries non-interactively after Keychain denial clears without manual Unlock")
    func syncPublisherRecoversOnRetryTickAfterDenialClears() async throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        backend.seed(service: "test.sync", account: SyncSecretAccount.refreshToken, value: "rt-live")
        backend.seed(service: "test.sync", account: SyncSecretAccount.publisherId, value: "pub-real")
        backend.setReadDenied(service: "test.sync", account: SyncSecretAccount.publisherId, status: errSecAuthFailed)

        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        _ = vault.warmUpSync(interactive: false)
        let secrets = KeychainSyncSecretStore(service: "test.sync", vault: vault)

        let stateStore = InMemorySyncStateStore()
        var active = SyncPersistentState()
        active.phase = .active
        active.account = SyncAccount(permissionId: "perm-1", email: "user@example.com")
        try stateStore.save(active)

        let clock = FakeSyncClock()
        let publisher = SyncPublisher(
            configuration: SyncClientConfiguration(clientID: "cid", clientSecret: "csec"),
            transport: ScriptedSyncTransport(),
            secrets: secrets,
            stateStore: stateStore,
            clock: clock,
            label: { "TestMac" }
        )

        // Stop fails because publisherId is denied; stays active with stopRequested.
        await publisher.stop()
        #expect(try stateStore.load().phase == .active)

        // Lift denial WITHOUT calling vault.unlock(); advance clock past backoff and tick.
        backend.setReadDenied(service: "test.sync", account: SyncSecretAccount.publisherId, status: nil)
        await publisher.setStopCheckpoint { gap in
            if gap == .afterStoppingWrite { throw CancellationError() }
        }
        clock.advance(by: 120)
        await publisher.tick()

        let persisted = try stateStore.load()
        #expect(persisted.phase == .stopping)
        #expect(persisted.cleanup?.publisherId == "pub-real")
    }

    @Test("R1-06: passive forceRefresh(allowInteractiveUnlock: false) disables security CLI and never triggers startupWarmUp")
    func passiveForceRefreshStaysNonInteractive() async {
        let startupCalls = RecordedBools()
        let securityCLIFlags = RecordedBools()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: {
                [SecurityCLIObservingProvider(onFetch: { securityCLIFlags.append($0) })]
            },
            vaultWarmUp: { _ in },
            startupWarmUp: { startupCalls.append(true) }
        )

        // Passive forceRefresh must NOT invoke startupWarmUp and must set allowsSecurityCLI = false.
        _ = await manager.forceRefresh(allowInteractiveUnlock: false)
        #expect(startupCalls.values.isEmpty)
        #expect(securityCLIFlags.values == [false])

        // Explicit interactive forceRefresh sets allowsSecurityCLI = true.
        _ = await manager.forceRefresh(allowInteractiveUnlock: true)
        #expect(securityCLIFlags.values == [false, true])
    }

    @Test("R2-01: passive refresh suppresses /usr/bin/security across credentialQueue GCD hop")
    func passiveRefreshSuppressesSecurityCLIAcrossGCDHop() async {
        let invoked = RecordedStrings()
        let hook: @Sendable (String) -> Data? = { service in
            invoked.append(service)
            return nil
        }

        // Enable CLI discovery via task-local override so parallel suites never race UserDefaults.
        await CredentialStore.$cliDiscoveryOverride.withValue(true) {
            // Across credentialQueue.async, allowsSecurityCLI == false must suppress the subprocess hook.
            await CredentialStore.$securityCLISubprocessHook.withValue(hook) {
                await CredentialStore.$allowsSecurityCLI.withValue(false) {
                    _ = await CredentialStore.apiKeyAsync(for: .muse)
                    _ = await CredentialStore.claudePlanNameAsync()
                }
            }
            #expect(invoked.values.isEmpty)

            // When allowsSecurityCLI == true (and CLI discovery enabled), the hook is reachable across the GCD hop.
            await CredentialStore.$securityCLISubprocessHook.withValue(hook) {
                await CredentialStore.$allowsSecurityCLI.withValue(true) {
                    _ = await CredentialStore.apiKeyAsync(for: .muse)
                }
            }
            #expect(invoked.values.contains("ai.meta.dev.credentials"))
        }
    }

    @Test("R2-02: superseded deferred write returns .superseded and refreshes in-memory cache from durable vault")
    func supersededDeferredWriteRefreshesCacheAndReportsOutcome() throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let vaultA = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        let vaultB = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)

        try vaultA.write("session-v1", namespace: .keys, account: "gemini-oauth")
        _ = vaultB.warmUpSync(interactive: false)
        // Another process replaces the session with session-v2.
        try vaultB.write("session-v2", namespace: .keys, account: "gemini-oauth")

        // vaultA's stale cache still holds session-v1 until its deferred write runs under flock.
        let outcome = vaultA.writeDeferred(
            "session-renewed-from-v1",
            namespace: .keys,
            account: "gemini-oauth",
            expectedPreviousValue: "session-v1"
        )
        #expect(outcome == .superseded)
        // vaultA's in-memory cache must immediately reflect the winning session-v2!
        #expect(vaultA.cachedValue(namespace: .keys, account: "gemini-oauth") == "session-v2")
        #expect(try vaultA.read(namespace: .keys, account: "gemini-oauth") == "session-v2")

        // And when another process deletes the key, a stale renewal also reports .superseded and clears cache.
        try vaultB.delete(namespace: .keys, account: "gemini-oauth")
        let deletedOutcome = vaultA.writeDeferred(
            "session-renewed-from-v2",
            namespace: .keys,
            account: "gemini-oauth",
            expectedPreviousValue: "session-v2"
        )
        #expect(deletedOutcome == .superseded)
        #expect(vaultA.cachedValue(namespace: .keys, account: "gemini-oauth") == nil)
    }

    @Test("R2-03 & R3-05: interactive refresh arriving during a queued passive follow-up runs before activeTask releases")
    func interactiveEscalationDuringPassiveFollowUpDrainsBeforeRelease() async {
        let warmUps = RecordedBools()
        let pass1Started = CoreAsyncSignal()
        let releasePass1 = CoreAsyncSignal()
        let passiveStarted = CoreAsyncSignal()
        let releasePassive = CoreAsyncSignal()
        let passCounter = AtomicCounter()

        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 5, minPollInterval: 0),
            providerFactory: { [] },
            vaultWarmUp: { interactive in
                let n = passCounter.increment()
                warmUps.append(interactive)
                if n == 1 {
                    pass1Started.signal()
                    await releasePass1.wait()
                } else if n == 2 {
                    passiveStarted.signal()
                    await releasePassive.wait()
                }
            }
        )

        let autoTask = Task { await manager.refresh() }
        // Deterministically wait for pass 1 to start, queue passive follow-up, then release pass 1.
        await pass1Started.wait()
        let queuedPassive = await manager.queueUserRefreshIfActive(allowInteractiveUnlock: false)
        #expect(queuedPassive)
        releasePass1.signal()

        // Deterministically wait for passive follow-up to start, escalate with interactive click, then release.
        await passiveStarted.wait()
        let queuedInteractive = await manager.queueUserRefreshIfActive(allowInteractiveUnlock: true)
        #expect(queuedInteractive)
        releasePassive.signal()

        _ = await autoTask.value
        #expect(warmUps.values == [false, false, true])

        // A subsequent unrelated automatic refresh must stay non-interactive.
        _ = await manager.refresh()
        #expect(warmUps.values == [false, false, true, false])
    }

    @Test("R3-03: chained renewal of a deferred token succeeds once contention clears")
    func chainedDeferredRenewalPreservesDurableBaseline() throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = makeTempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        try vault.write("session-v1", namespace: .keys, account: "gemini-oauth")

        // Hold flock externally so renewal 1 (v1 -> v2) is deferred.
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)
        let firstOutcome = vault.writeDeferred(
            "session-v2",
            namespace: .keys,
            account: "gemini-oauth",
            expectedPreviousValue: "session-v1"
        )
        #expect(firstOutcome == .deferred)
        #expect(try vault.read(namespace: .keys, account: "gemini-oauth") == "session-v2")

        // Release flock; renewal 2 starts from the pending v2 and writes v3.
        _ = flock(fd, LOCK_UN)
        close(fd)
        let secondOutcome = vault.writeDeferred(
            "session-v3",
            namespace: .keys,
            account: "gemini-oauth",
            expectedPreviousValue: "session-v2"
        )
        #expect(secondOutcome == .persisted)

        let verifier = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        _ = verifier.warmUpSync(interactive: false)
        #expect(try verifier.read(namespace: .keys, account: "gemini-oauth") == "session-v3")
    }

    @Test("R3-04: passive credential miss retaining a measured snapshot does not throttle an interactive retry")
    func passiveCredentialMissDoesNotThrottleInteractiveRetry() async {
        let fetchCount = AtomicCounter()
        let provider = InteractiveCredentialProvider(onFetch: { _ = fetchCount.increment() })
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 5, minPollInterval: 30),
            providerFactory: { [provider] },
            vaultWarmUp: { _ in }
        )

        // 1. Initial refresh succeeds (measured).
        _ = await manager.refresh()
        #expect(fetchCount.current == 1)

        // 2. Passive forceRefresh misses credential (allowsSecurityCLI == false -> .notConfigured),
        //    retaining the measured snapshot with staleReading.reason == .notConfigured.
        let passiveResult = await manager.forceRefresh(allowInteractiveUnlock: false)
        #expect(fetchCount.current == 2)
        #expect(passiveResult[VendorIdentifier.muse.rawValue]?.staleReading?.reason == .notConfigured)

        // 3. Interactive forceRefresh within minPollInterval=30s MUST bypass the floor and re-fetch!
        let interactiveResult = await manager.forceRefresh(allowInteractiveUnlock: true)
        #expect(fetchCount.current == 3)
        #expect(interactiveResult[VendorIdentifier.muse.rawValue]?.staleReading == nil)
    }
}

private struct InteractiveCredentialProvider: QuotaProvider {
    let vendorId: VendorIdentifier = .muse
    var displayName: String { "Muse" }
    var category: MetricCategory { .aiSubscriptions }
    let onFetch: @Sendable () -> Void

    func fetchSnapshot() async -> QuotaSnapshot {
        onFetch()
        if !CredentialStore.allowsSecurityCLI {
            return QuotaSnapshot(
                id: vendorId.rawValue,
                vendorId: vendorId,
                displayName: displayName,
                category: category,
                metric: .percentage(usedFraction: 0, displayDetails: nil),
                status: .unavailable(.notConfigured),
                resetsAt: nil,
                lastUpdated: Date(),
                auxiliaryInfo: nil
            )
        }
        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .percentage(usedFraction: 0.4, displayDetails: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil
        )
    }
}

private final class RecordedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var values: [String] { lock.withLock { items } }
    func append(_ v: String) { lock.withLock { items.append(v) } }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var current: Int { lock.withLock { count } }
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class CoreAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let list: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !signaled else { return [] }
            signaled = true
            let copy = waiters
            waiters.removeAll()
            return copy
        }
        for c in list { c.resume() }
    }

    func wait() async {
        await withCheckedContinuation { cont in
            let done: Bool = lock.withLock {
                if signaled { return true }
                waiters.append(cont)
                return false
            }
            if done { cont.resume() }
        }
    }
}

private struct SecurityCLIObservingProvider: QuotaProvider {
    let vendorId: VendorIdentifier = .claude
    var displayName: String { "Claude" }
    var category: MetricCategory { .aiSubscriptions }
    let onFetch: @Sendable (Bool) -> Void

    func fetchSnapshot() async -> QuotaSnapshot {
        onFetch(CredentialStore.allowsSecurityCLI)
        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .percentage(usedFraction: 0.1, displayDetails: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil
        )
    }
}

// MARK: - Local Test Helpers

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class RecordedBools: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    var values: [Bool] { lock.withLock { items } }
    func append(_ v: Bool) { lock.withLock { items.append(v) } }
}

private struct FastMeasuredProvider: QuotaProvider {
    let vendorId: VendorIdentifier
    let checkWarmUp: @Sendable () -> Bool
    var displayName: String { vendorId.displayName }
    var category: MetricCategory { .aiSubscriptions }

    func fetchSnapshot() async -> QuotaSnapshot {
        guard checkWarmUp() else {
            return QuotaSnapshot(
                id: vendorId.rawValue,
                vendorId: vendorId,
                displayName: displayName,
                category: category,
                metric: .percentage(usedFraction: 0, displayDetails: nil),
                status: .unavailable(.badResponse),
                resetsAt: nil,
                lastUpdated: Date(),
                auxiliaryInfo: nil
            )
        }
        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .percentage(usedFraction: 0.25, displayDetails: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil
        )
    }
}

private final class ScriptedSyncTransport: SyncTransport, @unchecked Sendable {
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        SyncHTTPResponse(status: 500, headers: [:], body: Data())
    }
}
