import Foundation
import Security
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("SettingsVault & SyncController")
struct SettingsVaultTests {

    @Test("SettingsCredentialMerge preserves dirty edits when async load finishes")
    func asyncLoadPreservesDirtyEdits() {
        let slots: [VendorIdentifier] = [.claude, .openai, .openrouter]
        let merged = SettingsCredentialMerge.merge(
            slots: slots,
            currentLoaded: [.claude: "", .openai: "", .openrouter: "old-or"],
            currentEntered: [.claude: "user-typed-claude", .openai: "", .openrouter: "old-or"],
            freshLoaded: [.claude: "vault-claude", .openai: "vault-openai", .openrouter: "vault-or"],
            currentLoadedGeminiClientID: "",
            currentEnteredGeminiClientID: "dirty-client-id",
            freshGeminiClientID: "vault-client-id"
        )

        // Dirty fields keep user's typed text while `loaded` updates to vault value.
        #expect(merged.entered[.claude] == "user-typed-claude")
        #expect(merged.loaded[.claude] == "vault-claude")
        #expect(merged.enteredGeminiClientID == "dirty-client-id")
        #expect(merged.loadedGeminiClientID == "vault-client-id")

        // Untouched fields adopt the freshly loaded vault values.
        #expect(merged.entered[.openai] == "vault-openai")
        #expect(merged.entered[.openrouter] == "vault-or")
    }

    @Test("SettingsVaultBannerPresentation covers locked, pending legacy, pending writes, corrupt, and healthy states")
    func vaultBannerPresentationStates() {
        let healthy = VaultStatusSnapshot(state: .loaded, legacyScanSucceeded: true, deferredWriteCount: 0)
        #expect(SettingsVaultBannerPresentation.make(from: healthy) == nil)

        let locked = VaultStatusSnapshot(state: .lockedOrDenied(errSecInteractionNotAllowed))
        #expect(SettingsVaultBannerPresentation.make(from: locked)?.kind == .locked)
        #expect(SettingsVaultBannerPresentation.make(from: locked)?.actionTitle == "Unlock Keychain")

        let pendingLegacy = VaultStatusSnapshot(
            state: .loaded,
            pendingLegacySyncKeys: [SyncSecretAccount.refreshToken],
            legacyScanSucceeded: true
        )
        #expect(SettingsVaultBannerPresentation.make(from: pendingLegacy)?.kind == .locked)

        let pendingWrites = VaultStatusSnapshot(
            state: .loaded,
            legacyScanSucceeded: true,
            deferredWriteCount: 1
        )
        #expect(SettingsVaultBannerPresentation.make(from: pendingWrites)?.kind == .pendingWrites)
        #expect(SettingsVaultBannerPresentation.make(from: pendingWrites)?.actionTitle == "Save pending changes")

        let corrupt = VaultStatusSnapshot(state: .corrupt)
        #expect(SettingsVaultBannerPresentation.make(from: corrupt)?.kind == .corrupt)
    }

    @Test("R10-03: a background unlock or migrated legacy item reloads credential controls; a deferred write alone does not")
    func vaultReloadRule() {
        let locked = VaultStatusSnapshot(state: .lockedOrDenied(errSecInteractionNotAllowed))
        let loaded = VaultStatusSnapshot(state: .loaded, legacyScanSucceeded: true, deferredWriteCount: 0)
        let loadedWithPendingWrite = VaultStatusSnapshot(state: .loaded, legacyScanSucceeded: true, deferredWriteCount: 1)
        let pendingLegacy = VaultStatusSnapshot(
            state: .loaded,
            pendingLegacyKeys: ["openai"],
            legacyScanSucceeded: true
        )

        #expect(SettingsVaultReload.shouldReloadCredentials(previous: locked, current: loaded))
        #expect(SettingsVaultReload.shouldReloadCredentials(previous: pendingLegacy, current: loaded))
        #expect(!SettingsVaultReload.shouldReloadCredentials(previous: loaded, current: loadedWithPendingWrite))
        #expect(!SettingsVaultReload.shouldReloadCredentials(previous: loaded, current: loaded))
    }

    @Test("R11-03: a cleared but unsaved key survives a background denial followed by unlock")
    func clearedKeySurvivesDenialThenUnlock() {
        let denied = VaultStatusSnapshot(state: .lockedOrDenied(errSecAuthFailed))
        let scanFailed = VaultStatusSnapshot(state: .loaded, legacyScanSucceeded: false)
        let pending = VaultStatusSnapshot(state: .loaded, pendingLegacyKeys: ["openai"], legacyScanSucceeded: true)
        let healthy = VaultStatusSnapshot(state: .loaded, legacyScanSucceeded: true)
        #expect(SettingsVaultReload.freshValue(label: "openai", cached: nil, in: denied) == nil)
        #expect(SettingsVaultReload.freshValue(label: "openai", cached: nil, in: scanFailed) == nil)
        #expect(SettingsVaultReload.freshValue(label: "openai", cached: "sk", in: scanFailed) == "sk")
        #expect(SettingsVaultReload.freshValue(label: "openai", cached: nil, in: pending) == nil)
        #expect(SettingsVaultReload.freshValue(label: "openai", cached: nil, in: healthy) == "")

        // The user cleared the saved OpenAI key and the Gemini client ID without saving.
        let slots: [VendorIdentifier] = [.openai]
        let duringDenial = SettingsCredentialMerge.merge(
            slots: slots,
            currentLoaded: [.openai: "sk-saved"],
            currentEntered: [.openai: ""],
            freshLoaded: [:],
            currentLoadedGeminiClientID: "client-saved",
            currentEnteredGeminiClientID: "",
            freshGeminiClientID: "",
            unreadableSlots: [.openai],
            geminiClientIDUnreadable: true
        )
        let afterUnlock = SettingsCredentialMerge.merge(
            slots: slots,
            currentLoaded: duringDenial.loaded,
            currentEntered: duringDenial.entered,
            freshLoaded: [.openai: "sk-saved"],
            currentLoadedGeminiClientID: duringDenial.loadedGeminiClientID,
            currentEnteredGeminiClientID: duringDenial.enteredGeminiClientID,
            freshGeminiClientID: "client-saved"
        )
        #expect(afterUnlock.entered[.openai] == "")
        #expect(afterUnlock.loaded[.openai] == "sk-saved")
        #expect(afterUnlock.enteredGeminiClientID == "")
        #expect(afterUnlock.loadedGeminiClientID == "client-saved")
    }

    @Test("FB-R3-02: SyncController.start() awaits shared vault warm-up before resuming unfinished Stop")
    @MainActor
    func syncControllerWaitsForWarmUpBeforeResume() async throws {
        let events = EventLog()
        let secretReadReached = AsyncSignal()
        let stateStore = BlockingStateStore(onLoad: {
            var stopping = SyncPersistentState()
            stopping.phase = .stopping
            stopping.account = SyncAccount(permissionId: "p1", email: "a@b.com")
            stopping.cleanup = SyncCleanupRecord(
                publisherId: "pub-1",
                account: stopping.account,
                refreshTokenAccount: SyncSecretAccount.refreshToken,
                relistAt: [Date.distantPast, Date.distantPast],
                completed: [],
                authLost: false,
                publishedThisSession: true
            )
            return stopping
        })
        let secretStore = LoggingSecretStore(onRead: { account in
            events.append("secret.read:\(account)")
            secretReadReached.signal()
            return "tok"
        })
        let publisher = SyncPublisher(
            configuration: SyncClientConfiguration(clientID: "cid", clientSecret: "csec"),
            transport: DummySyncTransport(),
            secrets: secretStore,
            stateStore: stateStore,
            label: { "Mac" }
        )
        let flow = SyncSignInFlow(
            configuration: SyncClientConfiguration(clientID: "cid", clientSecret: "csec"),
            transport: DummySyncTransport(),
            secrets: secretStore
        )
        let controller = SyncController(
            publisher: publisher,
            flow: flow,
            eventsLoader: { [] },
            vaultWarmUp: {
                events.append("warmup.start")
                try? await Task.sleep(for: .milliseconds(25))
                events.append("warmup.done")
            },
            macLabel: "Mac"
        )

        controller.start()
        await secretReadReached.wait()

        let log = events.all()
        let warmUpStart = log.firstIndex(of: "warmup.start")
        let warmUpDone = log.firstIndex(of: "warmup.done")
        let firstSecretRead = log.firstIndex(where: { $0.hasPrefix("secret.read:") })
        #expect(warmUpStart != nil)
        #expect(warmUpDone != nil)
        #expect(firstSecretRead != nil)
        if let start = warmUpStart, let done = warmUpDone, let read = firstSecretRead {
            #expect(start < done)
            #expect(done < read)
        }
    }

    @Test("FB-R3-03: QuotaStore.applyProviderPreferences stays non-interactive while explicit forceRefresh carries interactive intent")
    @MainActor
    func quotaStoreInteractiveUnlockSeparation() async {
        let intents = IntentRecorder()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { [] },
            vaultWarmUp: { interactive in intents.record(interactive) }
        )
        let store = QuotaStore(manager: manager)

        await store.applyProviderPreferences()
        await store.forceRefresh()
        await store.forceRefresh(allowInteractiveUnlock: true)

        #expect(intents.values == [false, false, true])
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ s: String) { lock.withLock { entries.append(s) } }
    func all() -> [String] { lock.withLock { entries } }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !signaled else { return [] }
            signaled = true
            let list = waiters
            waiters.removeAll()
            return list
        }
        for c in toResume { c.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let already: Bool = lock.withLock {
                if signaled { return true }
                waiters.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }
}

private final class IntentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    var values: [Bool] { lock.withLock { items } }
    func record(_ b: Bool) { lock.withLock { items.append(b) } }
}

private final class BlockingStateStore: SyncStateStore, @unchecked Sendable {
    let onLoad: @Sendable () -> SyncPersistentState
    init(onLoad: @escaping @Sendable () -> SyncPersistentState) { self.onLoad = onLoad }
    func load() throws -> SyncPersistentState { onLoad() }
    func save(_ state: SyncPersistentState) throws {}
}

private final class LoggingSecretStore: SyncSecretStore, @unchecked Sendable {
    let onRead: @Sendable (String) -> String?
    init(onRead: @escaping @Sendable (String) -> String?) { self.onRead = onRead }
    func read(_ account: String) throws -> String? { onRead(account) }
    func write(_ value: String, account: String) throws {}
    func delete(_ account: String) throws {}
}

private struct DummySyncTransport: SyncTransport {
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        SyncHTTPResponse(status: 200, headers: [:], body: Data())
    }
}
