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
        #expect(!flushedWhileLocked)
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
        #expect(!vault.writeDeferred("stale-renewal", namespace: .keys, account: "gemini.oauth.session"))
        #expect(vault.statusSnapshot().hasPendingWrites)

        // Explicit replacement supersedes deferred write.
        try vault.write("explicit-new", namespace: .keys, account: "gemini.oauth.session", allowsPrompt: true)
        #expect(!vault.statusSnapshot().hasPendingWrites)
        #expect(try vault.read(namespace: .keys, account: "gemini.oauth.session") == "explicit-new")

        // Deferred write followed by explicit delete: delete wins even after Unlock.
        #expect(!vault.writeDeferred("stale-renewal-2", namespace: .keys, account: "gemini.oauth.session"))
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
