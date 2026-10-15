import Foundation

/// What one publish is built from: the poll's visible snapshots in Mac
/// order, the recorded events, and the Mac's notification choices.
public struct SyncExportSource: Sendable {
    public var snapshots: [QuotaSnapshot]
    public var events: [AIEvent]
    public var notificationPrefs: SnapshotExportNotificationPrefs

    public init(
        snapshots: [QuotaSnapshot],
        events: [AIEvent] = [],
        notificationPrefs: SnapshotExportNotificationPrefs = SnapshotExportNotificationPrefs()
    ) {
        self.snapshots = snapshots
        self.events = events
        self.notificationPrefs = notificationPrefs
    }

    /// The exported form of the Mac's notification settings: the event kinds
    /// switched off, and the vendors whose resets alert.
    public static func notificationPrefs(
        enabledKinds: Set<AIEventKind>,
        resetAlertVendors: Set<VendorIdentifier>
    ) -> SnapshotExportNotificationPrefs {
        SnapshotExportNotificationPrefs(
            disabledKinds: CredentialStore.defaultEventNotificationKinds.subtracting(enabledKinds),
            resetAlertVendors: resetAlertVendors)
    }

    /// The same, read from the preferences Settings writes.
    public static func currentNotificationPrefs() -> SnapshotExportNotificationPrefs {
        notificationPrefs(
            enabledKinds: CredentialStore.eventNotificationKinds,
            resetAlertVendors: CredentialStore.resetAlertVendors)
    }
}

/// What Mac Settings shows about sync.
public struct SyncStatus: Sendable, Equatable {
    public var phase: SyncPhase = .off
    public var account: SyncAccount?
    /// "Sign in again": a terminal refresh failure stopped publishing.
    public var needsSignIn = false
    public var ownership: SyncOwnership?
    public var lastSuccessfulPublishAt: Date?
    public var lastError: String?
    /// The exporter's own line: an unmapped row, an identity collision, or
    /// providers that did not fit.
    public var exportMessage: String?
    /// Cleanup paused on a terminal auth failure: offer "Sign in to finish
    /// cleanup" and "Finish without deleting".
    public var cleanupNeedsSignIn = false
    /// The "couldn't delete its sync data" notice, or nil while it is hidden.
    public var abandoned: SyncAbandonedData?
    /// The saved sync state exists but could not be read. Nothing is known
    /// about the last session, so sync cannot be turned on until it reads.
    public var stateUnreadable = false

    public init() {}

    /// "Sync to phone & watch" can be turned on.
    public var canStart: Bool { (phase == .off || phase == .stopped) && !stateUnreadable }
}

/// The places the Stop protocol can be interrupted, one after each persisted
/// step. Tests "crash" at each one.
enum SyncStopGap: CaseIterable, Sendable {
    case afterStoppingWrite
    case afterSettle
    case afterDeleteOwn
    case afterFirstRelist
    case afterSecondRelist
    case afterTokenDelete
}

public enum SyncActivationError: Error, Equatable, Sendable {
    /// Sync is on, Stop is still cleaning up, or the saved state can't be read.
    case unavailable
    case keychain
    /// The sync state file could not be written: nothing changed.
    case stateNotSaved
}

/// A save was refused because the state file on disk could not be read.
struct SyncStateUnreadable: Error {}

/// Publishes the snapshot document to Drive's app-data folder (D§2.2.C–D).
///
/// Tick-driven: `submit` only records the newest input and returns, so the
/// poll path never waits on Google; a driver calls `tick()` when
/// `nextWakeup()` comes due. Every cadence rule reads `clock`, so tests run
/// them under a fake clock.
///
/// - Material changes publish at most once every 2 minutes; with none, a
///   heartbeat re-uploads the full document once the last successful publish
///   is 15 minutes old.
/// - One upload at a time; a newer input replaces any queued one.
/// - Before every upload: discover the canonical file, delete duplicates,
///   read its metadata (the clock sample comes from that response's `Date`
///   header) and check its `publisherId`.
/// - An uncertain upload (timeout, cancel, lost connection, 5xx) forces the
///   next publish at the next 2-minute slot, followed by a verification read;
///   a mismatch or another uncertain outcome forces another, up to 3 in a run.
///   Then only the heartbeat publishes, material change or not, until a
///   verification read matches.
/// - The 2-minute floor, the repair run and whether this session has
///   published are all persisted, so a relaunch keeps them.
/// - Durable state fails closed. Activation, Take over, re-sign-in, Stop and
///   the checkpoint before each attempt must reach disk before they take
///   effect; an attempt whose checkpoint can't be saved does not contact
///   Google. An outcome Google already gave is applied at once, but if its
///   write fails the publisher is behind its disk: nothing contacts Google
///   until a write of the whole state lands, and every tick retries it. A
///   state file that exists but can't be read is never taken for `off` or
///   written over.
/// - Every request passes `GatedSyncTransport`, which asks `permits(_:)`
///   immediately before sending. A publish request needs an active session
///   with no Stop pending, no "Sign in again", no ownership prompt and disk
///   level with runtime; a cleanup request needs `stopping` with auth intact.
/// - Stop persists `stopping` and a cleanup record before any network call,
///   then settles the in-flight upload, deletes this session's file, re-lists
///   at +2 and +10 minutes, deletes the token and sets `stopped`. It resumes
///   from the first incomplete step after a crash.
public actor SyncPublisher {
    public static let minimumInterval: TimeInterval = 120
    public static let heartbeatInterval: TimeInterval = 15 * 60
    public static let requestTimeout: TimeInterval = 20
    public static let foreignWindow: TimeInterval = 3600
    public static let maxForcedPublishes = 3
    public static let relistDelays: [TimeInterval] = [2 * 60, 10 * 60]
    static let backoffBase: TimeInterval = 120
    static let backoffCap: TimeInterval = 15 * 60
    /// How often an unreadable state file is read again, and a lost write
    /// is written again.
    static let stateRetryInterval: TimeInterval = 60
    static let stateNotSavedMessage = "Couldn't save sync state on this Mac"

    private let secrets: any SyncSecretStore
    private let stateStore: any SyncStateStore
    private let clock: any SyncClock
    private let label: @Sendable () -> String
    private let tokens: SyncAccessTokens
    private let drive: SyncDriveClient

    private var state: SyncPersistentState
    /// The newest input, replaced by every submit.
    private var source: SyncExportSource?
    private var sourceVersion = 0
    /// The material key of the newest input, and of the last confirmed upload.
    private var sourceMaterial: Data?
    private var publishedMaterial: Data?
    private var failures = 0
    private var retryAt: Date?
    private var exportState = SnapshotExportState()
    private var clockTrust = SyncClockTrust()
    private var clockSample: (offsetMs: Int?, sampledAt: Date?) = (nil, nil)
    private var publisherIdCache: String?
    private var takeOverRequested = false
    private var publishTask: Task<Void, Never>?
    private var publishing = false
    private var cleaning = false
    /// The state file exists but did not read: nothing is saved over it and
    /// nothing starts until a later read succeeds.
    private var stateUnreadable = false
    /// When the state file was last read: an unreadable one is read again a
    /// minute later.
    private var stateReadAt: Date
    /// Stop was pressed but its `stopping` write failed: nothing publishes,
    /// and the write is retried.
    private var stopRequested = false
    /// `state` holds an outcome whose write failed, so disk is behind it.
    /// Nothing contacts Google until a later save lands; each tick retries.
    private var durableBehind = false
    /// When the lost write is next retried.
    private var durableRetryAt: Date?

    /// Called after each persisted Stop step. Tests throw from it to stop the
    /// protocol there, as a crash would.
    var stopCheckpoint: (@Sendable (SyncStopGap) throws -> Void)?
    /// How many clock discontinuities were applied; tests wait on it.
    private(set) var clockDiscontinuities = 0

    public init(
        configuration: SyncClientConfiguration,
        transport: any SyncTransport = URLSessionSyncTransport(),
        secrets: any SyncSecretStore = KeychainSyncSecretStore(),
        stateStore: any SyncStateStore = FileSyncStateStore(),
        clock: any SyncClock = SystemSyncClock(),
        label: @escaping @Sendable () -> String
    ) {
        self.secrets = secrets
        self.stateStore = stateStore
        self.clock = clock
        self.label = label
        let gated = GatedSyncTransport(transport)
        let tokens = SyncAccessTokens(
            endpoint: SyncTokenEndpoint(configuration: configuration, transport: gated, clock: clock),
            secrets: secrets, clock: clock)
        self.tokens = tokens
        self.drive = SyncDriveClient(transport: gated, tokens: tokens, clock: clock)
        stateReadAt = clock.now()
        do {
            state = SyncPersistentState.recovered(try stateStore.load(), now: clock.now())
        } catch {
            state = SyncPersistentState()
            stateUnreadable = true
        }
        gated.bind { [weak self] scope in await self?.permits(scope) ?? false }
    }

    /// Whether a request of `scope` may be sent now. Asked by the transport
    /// immediately before each request, so it reads the state as it is when
    /// the request would leave, not as it was when the step began.
    func permits(_ scope: SyncNetworkScope) -> Bool {
        guard !stateUnreadable, !durableBehind else { return false }
        switch scope {
        case .publish:
            return state.phase == .active && !stopRequested && !state.needsSignIn && state.ownership == nil
        case .cleanup:
            return state.phase == .stopping && state.cleanup.map { !$0.authLost } ?? false
        }
    }

    /// Reads the state file again after it could not be read. `tick` and
    /// `resume` call it; so does "Try Again".
    public func retryLoadingState() {
        guard stateUnreadable else { return }
        stateReadAt = clock.now()
        guard let loaded = try? stateStore.load() else { return }
        state = .recovered(loaded, now: clock.now())
        stateUnreadable = false
    }

    func setStopCheckpoint(_ checkpoint: (@Sendable (SyncStopGap) throws -> Void)?) {
        stopCheckpoint = checkpoint
    }

    // MARK: Status

    public func status() -> SyncStatus {
        var status = SyncStatus()
        status.phase = state.phase
        status.account = state.account
        status.needsSignIn = state.phase == .active && state.needsSignIn
        status.ownership = state.phase == .active ? state.ownership : nil
        status.lastSuccessfulPublishAt = state.lastSuccessfulPublishAt
        status.lastError = durableBehind ? Self.stateNotSavedMessage : state.lastError
        status.exportMessage = exportState.settingsMessage
        status.cleanupNeedsSignIn = state.phase == .stopping && (state.cleanup?.authLost ?? false)
        status.stateUnreadable = stateUnreadable
        // Hidden while this Mac publishes to that same account again:
        // following it would delete the new session's snapshot.
        if let abandoned = state.abandoned,
           !(state.phase == .active && state.account?.permissionId == abandoned.account.permissionId) {
            status.abandoned = abandoned
        }
        return status
    }

    // MARK: Input

    /// Records the newest input and returns at once. Off, stopping or
    /// stopped, it is dropped: nothing is published and nothing contacts
    /// Google.
    public func submit(_ source: SyncExportSource) {
        guard state.phase == .active else { return }
        self.source = source
        sourceVersion += 1
        if let document = exportState.prepare(exportInput(source, publishedAt: clock.now())) {
            sourceMaterial = SyncMaterial.key(document.data)
        }
    }

    /// `NSSystemClockDidChangeNotification`: every reading retained now is
    /// exported untrusted until it is measured again.
    public func clockDidChange() {
        clockTrust.discontinuity(retaining: source?.snapshots ?? [])
        state.clampAttemptTimes(to: clock.now())
        clockDiscontinuities += 1
        if let source { submit(source) }
    }

    // MARK: Scheduling

    /// When `tick()` next has work, or nil when nothing is scheduled.
    public func nextWakeup() -> Date? {
        if stateUnreadable { return stateReadAt.addingTimeInterval(Self.stateRetryInterval) }
        if stopRequested { return retryAt ?? clock.now() }
        if durableBehind { return durableRetryAt ?? clock.now() }
        switch state.phase {
        case .active: return nextPublishDue()
        case .stopping: return nextCleanupDue()
        case .off, .stopped: return nil
        }
    }

    func nextPublishDue() -> Date? {
        guard state.phase == .active, !stopRequested, !state.needsSignIn, state.ownership == nil, source != nil
        else { return nil }
        let slot = state.lastAttemptAt.map { $0.addingTimeInterval(Self.minimumInterval) } ?? clock.now()
        var due = publishWaitsForHeartbeat ? max(slot, heartbeatDue) : slot
        if let retryAt { due = max(due, retryAt) }
        return due
    }

    /// The 3 forced publishes of this repair run are spent.
    private var repairExhausted: Bool {
        state.repairPending && state.forcedPublishes >= Self.maxForcedPublishes
    }

    /// Neither a forced repair nor a material change is due, or the repair
    /// run is exhausted: then only the heartbeat publishes.
    private var publishWaitsForHeartbeat: Bool {
        if state.repairPending { return repairExhausted }
        return publishedMaterial != nil && sourceMaterial == publishedMaterial
    }

    /// 15 minutes after the last success, or after the last heartbeat whose
    /// outcome was uncertain.
    private var heartbeatDue: Date {
        max(state.lastSuccessfulPublishAt ?? .distantPast, state.lastHeartbeatAttemptAt ?? .distantPast)
            .addingTimeInterval(Self.heartbeatInterval)
    }

    private func nextCleanupDue() -> Date? {
        guard let record = state.cleanup, !record.authLost else { return nil }
        let now = clock.now()
        var due = now
        if record.isDone(.deleteOwn) {
            if !record.isDone(.relistFirst) {
                due = record.relistAt[0]
            } else if !record.isDone(.relistSecond) {
                due = record.relistAt[1]
            }
        }
        if let retryAt { due = max(due, retryAt) }
        return due
    }

    /// Does whatever is due now: cleanup while stopping, a publish while
    /// active. One run at a time. A pending Stop write, then a lost outcome
    /// write, is retried first; nothing else runs until it lands.
    public func tick() async {
        retryLoadingState()
        if stateUnreadable { return }
        if stopRequested {
            // Stop's write carries the whole state, so it also brings disk level.
            if (retryAt ?? .distantPast) <= clock.now() { await stop() }
            return
        }
        if durableBehind {
            guard !publishing, !cleaning else { return }
            persist()
            if durableBehind { return }
        }
        switch state.phase {
        case .stopping:
            await runCleanup()
        case .active:
            guard !publishing, let due = nextPublishDue(), due <= clock.now() else { return }
            publishing = true
            let task = Task { await self.publish() }
            publishTask = task
            await task.value
            publishTask = nil
            publishing = false
        case .off, .stopped:
            return
        }
    }

    /// At launch: an unfinished Stop resumes from its first incomplete step.
    public func resume() async {
        retryLoadingState()
        if !stateUnreadable, state.phase == .stopping { await runCleanup() }
    }

    // MARK: Session

    /// Turns sync on after a sign-in stored its refresh token. Every session
    /// gets a fresh `publisherId`, kept in the Keychain until Stop finishes.
    ///
    /// Sync is on only once the active record, with its account, is on disk:
    /// that record is what lets Stop find and delete this session's data
    /// after a relaunch. If it can't be saved, this throws, sync stays as it
    /// was, and the sign-in's Keychain items are removed again.
    public func activate(account: SyncAccount) throws {
        guard !stateUnreadable, state.canStart else { throw SyncActivationError.unavailable }
        let publisherId = UUID().uuidString.lowercased()
        do {
            try secrets.write(publisherId, account: SyncSecretAccount.publisherId)
            guard try secrets.read(SyncSecretAccount.publisherId) == publisherId else { throw SyncActivationError.keychain }
        } catch {
            discardSignIn()
            throw SyncActivationError.keychain
        }
        var fresh = SyncPersistentState()
        fresh.phase = .active
        fresh.account = account
        fresh.abandoned = state.abandoned
        do {
            try save(fresh)
        } catch {
            // A write can fail after the file was replaced; put back what it
            // held, and keep retrying that if it fails too.
            persist()
            discardSignIn()
            state.lastError = Self.stateNotSavedMessage
            throw SyncActivationError.stateNotSaved
        }
        state = fresh
        publisherIdCache = publisherId
        source = nil
        sourceMaterial = nil
        publishedMaterial = nil
        failures = 0
        retryAt = nil
        takeOverRequested = false
        clockTrust = SyncClockTrust()
        clockSample = (nil, nil)
        exportState = SnapshotExportState()
    }

    /// Removes what a sign-in stored when sync did not turn on with it. Off
    /// or stopped, no session needs either item.
    private func discardSignIn() {
        try? secrets.delete(SyncSecretAccount.publisherId)
        try? secrets.delete(SyncSecretAccount.refreshToken)
    }

    /// A sign-in for the same account restored access: "Sign in again" while
    /// active, or "Sign in to finish cleanup" while stopping. Publishing
    /// stays forbidden during cleanup and the cleanup keeps its own
    /// `publisherId`. Nothing resumes unless that is saved.
    public func reauthorized(account: SyncAccount) throws {
        guard !stateUnreadable else { throw SyncActivationError.unavailable }
        let expected = state.phase == .stopping ? state.cleanup?.account : state.account
        guard expected?.permissionId == account.permissionId else { throw SyncSignInError.wrongAccount }
        var next = state
        switch state.phase {
        case .active:
            next.needsSignIn = false
            next.lastError = nil
        case .stopping:
            next.cleanup?.authLost = false
            next.lastError = nil
        case .off, .stopped:
            return
        }
        do {
            try save(next)
        } catch {
            state.lastError = Self.stateNotSavedMessage
            throw SyncActivationError.stateNotSaved
        }
        state = next
        failures = 0
        retryAt = nil
    }

    /// "Take over": the next upload writes this Mac's id over the other one.
    /// The prompt stays until clearing it is saved.
    public func takeOver() {
        guard state.phase == .active, state.ownership != nil else { return }
        var next = state
        next.ownership = nil
        do {
            try save(next)
        } catch {
            state.lastError = Self.stateNotSavedMessage
            return
        }
        state = next
        takeOverRequested = true
    }

    /// Hands a sign-in's fresh access token to Drive calls.
    public func primeAccessToken(_ token: String, expiresIn: TimeInterval?) async {
        await tokens.prime(token, expiresIn: expiresIn)
    }

    // MARK: Publish

    private enum UploadOutcome {
        case confirmed(String)
        case uncertain
        case failed(Error)
    }

    /// Every request of the attempt carries the publish scope, so the
    /// transport can refuse it once the attempt may no longer contact Google.
    private func publish() async {
        await SyncNetworkScope.$current.withValue(.publish) { await publishAttempt() }
    }

    private func publishAttempt() async {
        guard permits(.publish), let source else { return }
        let version = sourceVersion
        let started = clock.now()
        let heartbeat = publishWaitsForHeartbeat
        let heartbeatBefore = state.lastHeartbeatAttemptAt

        // An export failure withholds the publish before Google is contacted;
        // the last good remote document stays in place.
        guard exportState.prepare(exportInput(source, publishedAt: started)) != nil else {
            state.lastAttemptAt = started
            return
        }

        // The floor, the repair count, a heartbeat's next deadline and the
        // open attempt are on disk before Google hears of this attempt, so a
        // relaunch mid-upload, or after its outcome was lost, cannot reset
        // them. If they can't be saved, Google is not contacted at all.
        var checkpoint = state
        checkpoint.lastAttemptAt = started
        checkpoint.uploadStartedAt = started
        if heartbeat { checkpoint.lastHeartbeatAttemptAt = started }
        if checkpoint.repairPending && checkpoint.forcedPublishes < Self.maxForcedPublishes {
            checkpoint.forcedPublishes += 1
        }
        do {
            try save(checkpoint)
        } catch {
            failures += 1
            retryAt = clock.now().addingTimeInterval(Self.backoff(failures))
            state.lastError = Self.stateNotSavedMessage
            return
        }
        state = checkpoint
        do {
            let publisherId = try sessionPublisherId()
            let discovery = try await drive.discover()
            guard state.phase == .active else { return }
            for duplicate in discovery.duplicates {
                try await drive.delete(fileId: duplicate.id)
                guard state.phase == .active else { return }
            }

            var serverDate = discovery.serverDate
            let fileId = discovery.canonical?.id
            if let fileId {
                let metadata = try await drive.metadata(fileId: fileId)
                guard state.phase == .active else { return }
                serverDate = metadata.serverDate
                if let foreign = metadata.publisherId, foreign != publisherId, !takeOverRequested {
                    // Drive's clock on both sides: the file's modifiedTime
                    // against this response's Date header. With either one
                    // missing the age is unknown, and the file is not taken.
                    let age = metadata.serverDate.flatMap { now in metadata.modifiedTime.map { now.timeIntervalSince($0) } }
                    if state.publishedThisSession || age.map({ $0 < Self.foreignWindow }) ?? true {
                        let label = await foreignLabel(fileId)
                        guard state.phase == .active else { return }
                        state.ownership = state.publishedThisSession
                            ? .tookOver(label: label) : .otherMacSyncing(label: label)
                        closeUnsentAttempt(heartbeatBefore: heartbeatBefore)
                        persist()
                        return
                    }
                }
            }

            // The clock sample: this response's `Date` header, exported in the
            // document uploaded right after. No header, no sample.
            let sampledAt = clock.now()
            let offset = serverDate.map { Int(($0.timeIntervalSince(sampledAt) * 1000).rounded()) }
            clockSample = (offset, offset == nil ? nil : sampledAt)
            if clockTrust.sample(offsetMs: offset, retaining: source.snapshots) { clockDiscontinuities += 1 }

            guard let document = exportState.prepare(exportInput(source, publishedAt: sampledAt)) else {
                closeUnsentAttempt(heartbeatBefore: heartbeatBefore)
                persist()
                return
            }
            let bytes = document.data
            let request = fileId.map { drive.updateRequest(fileId: $0, content: bytes, publisherId: publisherId) }
                ?? drive.createRequest(content: bytes, publisherId: publisherId)
            let outcome = await upload(request)
            // Stop arrived meanwhile: its cleanup owns the session now.
            guard state.phase == .active else { return }

            // If the outcome below fails to save, the checkpoint's
            // `uploadStartedAt` stays on disk and a relaunch treats this
            // upload as uncertain.
            switch outcome {
            case .confirmed(let id):
                state.uploadStartedAt = nil
                state.fileId = id
                state.lastSuccessfulPublishAt = clock.now()
                state.lastError = nil
                failures = 0
                retryAt = nil
                takeOverRequested = false
                publishedMaterial = SyncMaterial.key(bytes)
                if version == sourceVersion { sourceMaterial = publishedMaterial }
                persist()
                // The verification read is a request like any other: the
                // transport refuses it if the write above was lost or Stop
                // is pending, and the repair waits for the next publish.
                if state.repairPending {
                    let remote = try await drive.download(fileId: id)
                    guard state.phase == .active else { return }
                    if SyncDriveClient.sha256(remote) == SyncDriveClient.sha256(bytes) {
                        state.repairPending = false
                        state.forcedPublishes = 0
                    } else {
                        state.lastError = "Older sync data reached Drive; publishing again"
                    }
                    persist()
                }
            case .uncertain:
                state.uploadStartedAt = nil
                state.repairPending = true
                state.mayHavePublished = true
                state.lastError = "The last upload's outcome is unknown; publishing again"
                persist()
            case .failed(let error):
                throw error
            }
        } catch {
            failed(error, heartbeatBefore: heartbeatBefore)
        }
    }

    /// Nothing of the open attempt reached Drive: it is closed, and a
    /// heartbeat's deadline goes back to what it was before the checkpoint
    /// moved it.
    private func closeUnsentAttempt(heartbeatBefore: Date?) {
        guard state.uploadStartedAt != nil else { return }
        state.uploadStartedAt = nil
        state.lastHeartbeatAttemptAt = heartbeatBefore
    }

    /// Sends one upload with the 20 s timeout. A request that may have
    /// reached Drive without an answer is `uncertain`; one that cannot have
    /// (refused before sending, or rejected) is `failed`.
    private func upload(_ request: SyncHTTPRequest) async -> UploadOutcome {
        do {
            return .confirmed(try await drive.upload(request))
        } catch is SyncTimeoutError {
            return .uncertain
        } catch is CancellationError {
            return .uncertain
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .failed(error)
            default:
                return .uncertain
            }
        } catch SyncDriveError.http(let status) where (500...599).contains(status) {
            return .uncertain
        } catch SyncDriveError.malformed {
            // Drive answered 2xx, so the upload landed, but not with a file id.
            return .uncertain
        } catch SyncDriveError.notFound {
            // The file went away (a takeover's Stop): rediscover next time.
            state.fileId = nil
            return .failed(SyncDriveError.notFound)
        } catch {
            return .failed(error)
        }
    }

    private func failed(_ error: Error, heartbeatBefore: Date?) {
        guard state.phase == .active else { return }
        // Nothing of this attempt can have landed unconfirmed: the failure
        // came before the upload, the upload was refused or withheld, or it
        // was confirmed and that is already in `state`.
        closeUnsentAttempt(heartbeatBefore: heartbeatBefore)
        if case SyncAuthError.refresh(let failure) = error, failure.isTerminal {
            // The token is already deleted (`SyncAccessTokens`), so a lost
            // write of this cannot lead to it being sent again.
            state.needsSignIn = true
            state.lastError = "Google stopped accepting FrugalBar's sign-in"
            retryAt = nil
        } else if case SyncAuthError.notSignedIn = error {
            state.needsSignIn = true
            state.lastError = "Google stopped accepting FrugalBar's sign-in"
            retryAt = nil
        } else if error is SyncRequestWithheld || !permits(.publish) {
            // The gate closed (Stop pending, a lost write, a cancelled
            // attempt): not Google's failure, so no backoff and no message.
        } else {
            failures += 1
            retryAt = clock.now().addingTimeInterval(Self.backoff(failures))
            state.lastError = Self.describe(error)
        }
        persist()
    }

    /// 2, 4, 8 minutes, then 15.
    static func backoff(_ failures: Int) -> TimeInterval {
        min(backoffBase * pow(2, Double(max(failures, 1) - 1)), backoffCap)
    }

    /// A line for Settings. Never a URL, a token or raw error text.
    static func describe(_ error: Error) -> String {
        switch error {
        case SyncAuthError.refresh(.transient(.rateLimited)):
            return "Google is rate-limiting sign-in; retrying"
        case SyncAuthError.refresh(.transient):
            return "Couldn't reach Google sign-in; retrying"
        case is SyncTimeoutError:
            return "Google Drive timed out; retrying"
        case SyncDriveError.http(let status):
            return "Google Drive answered \(status); retrying"
        case SyncDriveError.notFound:
            return "The sync file went away; recreating it"
        case SyncDriveError.unauthorized:
            return "Google Drive refused access; retrying"
        case SyncDriveError.invalidPageTokenAfterRestart, SyncDriveError.malformed:
            return "Google Drive sent an unreadable answer; retrying"
        default:
            return "Couldn't reach Google Drive; retrying"
        }
    }

    /// The other publisher's label, read from its document; nil when it
    /// cannot be read.
    private func foreignLabel(_ fileId: String) async -> String? {
        guard let data = try? await drive.download(fileId: fileId),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let label = root["publisherLabel"] as? String, !label.isEmpty
        else { return nil }
        return label
    }

    private func sessionPublisherId() throws -> String {
        if let publisherIdCache { return publisherIdCache }
        guard let stored = try secrets.read(SyncSecretAccount.publisherId), !stored.isEmpty else {
            throw SyncAuthError.notSignedIn
        }
        publisherIdCache = stored
        return stored
    }

    private func exportInput(_ source: SyncExportSource, publishedAt: Date) -> SnapshotExportInput {
        SnapshotExportInput(
            publisherId: (try? sessionPublisherId()) ?? "",
            publisherLabel: label(),
            publishedAt: publishedAt,
            macClockOffsetMs: clockSample.offsetMs,
            macClockSampledAt: clockSample.sampledAt,
            snapshots: source.snapshots,
            untrustedInstanceIDs: clockTrust.untrustedIDs(in: source.snapshots),
            events: source.events,
            notificationPrefs: source.notificationPrefs)
    }

    /// Every write of the state file. Refused while the file on disk could
    /// not be read, so an unreadable record is never replaced. Each write is
    /// `state` plus the change being made, so one that lands brings disk
    /// level with runtime again.
    private func save(_ next: SyncPersistentState) throws {
        guard !stateUnreadable else { throw SyncStateUnreadable() }
        try stateStore.save(next)
        durableBehind = false
        durableRetryAt = nil
    }

    /// Writes an outcome already in `state`. If the write fails, disk is
    /// behind: `permits` refuses every request until a later save lands, and
    /// each tick retries this one. A relaunch meanwhile is a crash at this
    /// point, which the saved record keeps safe: the open attempt's
    /// checkpoint (uncertain upload, heartbeat deadline), a cleanup step that
    /// is retried, or a refresh token already deleted.
    private func persist() {
        do {
            try save(state)
        } catch {
            durableBehind = true
            durableRetryAt = clock.now().addingTimeInterval(Self.stateRetryInterval)
        }
    }

    // MARK: Stop (REQ-MAC-STOP)

    /// "Stop syncing". Step 1 is one atomic write of `stopping` and the
    /// cleanup record, before any network call; from then on nothing
    /// publishes or repairs. The rest runs now and on later ticks.
    ///
    /// If step 1 can't be written, or the session's `publisherId` can't be
    /// read for the record, nothing more is published and step 1 is retried.
    /// The durable state is still `active`, so a relaunch shows Stop again.
    public func stop() async {
        switch state.phase {
        case .active:
            let publisherId: String
            do {
                publisherId = try sessionPublisherId()
            } catch SyncAuthError.notSignedIn {
                // The session never stored one: nothing remote carries it.
                publisherId = ""
            } catch {
                stopNotSaved()
                return
            }
            let now = clock.now()
            var next = state
            next.phase = .stopping
            next.ownership = nil
            next.needsSignIn = false
            next.repairPending = false
            next.forcedPublishes = 0
            next.lastError = nil
            next.cleanup = SyncCleanupRecord(
                publisherId: publisherId,
                account: state.account,
                refreshTokenAccount: SyncSecretAccount.refreshToken,
                relistAt: Self.relistDelays.map { now.addingTimeInterval($0) },
                completed: [],
                authLost: false,
                publishedThisSession: state.fileId != nil && state.lastSuccessfulPublishAt != nil)
            do {
                try save(next)
            } catch {
                stopNotSaved()
                return
            }
            stopRequested = false
            state = next
            source = nil
            sourceMaterial = nil
            failures = 0
            retryAt = nil
            do { try stopCheckpoint?(.afterStoppingWrite) } catch { return }
        case .stopping:
            break
        case .off, .stopped:
            return
        }
        await runCleanup()
    }

    private func stopNotSaved() {
        stopRequested = true
        failures += 1
        retryAt = clock.now().addingTimeInterval(Self.backoff(failures))
        state.lastError = Self.stateNotSavedMessage
    }

    /// "Finish without deleting": stop now, leave the data, and keep a notice
    /// naming the account so the owner can delete it in Drive.
    ///
    /// As in cleanup, the token goes first and `stopped` with the notice is
    /// one write after it. Nothing shows `stopped` or offers Start until that
    /// write lands; if it fails, cleanup stays paused with both choices, and
    /// a relaunch finds the same.
    public func finishWithoutDeleting() {
        guard state.phase == .stopping, let record = state.cleanup, record.authLost else { return }
        var next = state
        next.phase = .stopped
        next.cleanup = nil
        next.fileId = nil
        next.lastError = nil
        if let account = record.account { next.abandoned = SyncAbandonedData(account: account) }
        do {
            try secrets.delete(record.refreshTokenAccount)
            try secrets.delete(SyncSecretAccount.publisherId)
            try save(next)
        } catch {
            state.lastError = Self.stateNotSavedMessage
            return
        }
        state = next
        publisherIdCache = nil
    }

    private func runCleanup() async {
        guard state.phase == .stopping, !cleaning, !durableBehind, let initial = state.cleanup, !initial.authLost
        else { return }
        if let retryAt, retryAt > clock.now() { return }
        cleaning = true
        defer { cleaning = false }
        await SyncNetworkScope.$current.withValue(.cleanup) { await cleanupSteps(initial) }
    }

    private func cleanupSteps(_ initial: SyncCleanupRecord) async {
        do {
            if !initial.isDone(.settleInFlight) {
                if let task = publishTask {
                    task.cancel()
                    await task.value
                }
                try complete(.settleInFlight, gap: .afterSettle)
            }
            if !(state.cleanup?.isDone(.deleteOwn) ?? true) {
                try await deleteOwnFiles()
                try complete(.deleteOwn, gap: .afterDeleteOwn)
            }
            for (index, step) in [SyncStopStep.relistFirst, .relistSecond].enumerated() {
                guard let record = state.cleanup, !record.isDone(step) else { continue }
                guard clock.now() >= record.relistAt[index] else { return }
                try await deleteOwnFiles()
                try complete(step, gap: index == 0 ? .afterFirstRelist : .afterSecondRelist)
            }
            guard let record = state.cleanup else { return }
            if !record.isDone(.deleteToken) {
                try secrets.delete(record.refreshTokenAccount)
                try secrets.delete(SyncSecretAccount.publisherId)
                try complete(.deleteToken, gap: .afterTokenDelete)
            }
            var next = state
            next.phase = .stopped
            next.cleanup = nil
            next.fileId = nil
            next.lastError = nil
            // This session overwrote that account's file and has now deleted
            // it, so the older notice no longer describes anything.
            if record.publishedThisSession, let abandoned = next.abandoned,
               abandoned.account.permissionId == record.account?.permissionId {
                next.abandoned = nil
            }
            try save(next)
            state = next
            publisherIdCache = nil
            failures = 0
            retryAt = nil
            await tokens.invalidate()
        } catch is SyncStopInterrupted {
            return
        } catch SyncAuthError.refresh(let failure) where failure.isTerminal {
            state.cleanup?.authLost = true
            retryAt = nil
            persist()
        } catch SyncAuthError.notSignedIn {
            state.cleanup?.authLost = true
            retryAt = nil
            persist()
        } catch {
            failures += 1
            retryAt = clock.now().addingTimeInterval(Self.backoff(failures))
            state.lastError = Self.describe(error)
            persist()
        }
    }

    /// Deletes every `snapshot.json` that carries this session's id; a file
    /// with any other id is never touched.
    private func deleteOwnFiles() async throws {
        guard let publisherId = state.cleanup?.publisherId, !publisherId.isEmpty else { return }
        for file in try await drive.discover().all where file.publisherId == publisherId {
            try await drive.delete(fileId: file.id)
        }
    }

    /// Persists one completed step, then passes the checkpoint after it.
    private func complete(_ step: SyncStopStep, gap: SyncStopGap) throws {
        var next = state
        next.cleanup?.completed.append(step)
        try save(next)
        state = next
        do {
            try stopCheckpoint?(gap)
        } catch {
            throw SyncStopInterrupted()
        }
    }
}

/// A Stop checkpoint threw: the protocol halts where a crash would.
struct SyncStopInterrupted: Error {}

extension SyncPersistentState {
    var canStart: Bool { phase == .off || phase == .stopped }

    /// The state as a launch finds it. An attempt whose outcome never reached
    /// disk is treated as an uncertain upload: it may have landed, so the
    /// next publish is forced and verified, and a foreign id found later is
    /// a takeover.
    static func recovered(_ loaded: SyncPersistentState, now: Date) -> SyncPersistentState {
        var state = loaded
        state.clampAttemptTimes(to: now)
        if state.phase == .active, state.uploadStartedAt != nil {
            state.uploadStartedAt = nil
            state.repairPending = true
            state.mayHavePublished = true
        }
        return state
    }

    /// An attempt time the wall clock has since gone back past counts from
    /// now, so it cannot hold publishing back indefinitely.
    mutating func clampAttemptTimes(to now: Date) {
        if let at = lastAttemptAt, at > now { lastAttemptAt = now }
        if let at = lastHeartbeatAttemptAt, at > now { lastHeartbeatAttemptAt = now }
    }
}
