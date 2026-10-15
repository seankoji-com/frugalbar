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

    public init() {}

    /// "Sync to phone & watch" can be turned on.
    public var canStart: Bool { phase == .off || phase == .stopped }
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
    /// Sync is on, or Stop is still cleaning up.
    case unavailable
    case keychain
}

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
///   a mismatch forces another, up to 3 in a run, then the heartbeat takes over.
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
    /// Start of the last publish attempt: the 2-minute floor counts from it.
    private var lastAttemptAt: Date?
    private var failures = 0
    private var retryAt: Date?
    private var exportState = SnapshotExportState()
    private var clockTrust = SyncClockTrust()
    private var clockSample: (offsetMs: Int?, sampledAt: Date?) = (nil, nil)
    private var publisherIdCache: String?
    private var publishedThisRun = false
    private var takeOverRequested = false
    private var publishTask: Task<Void, Never>?
    private var publishing = false
    private var cleaning = false

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
        let tokens = SyncAccessTokens(
            endpoint: SyncTokenEndpoint(configuration: configuration, transport: transport, clock: clock),
            secrets: secrets, clock: clock)
        self.tokens = tokens
        self.drive = SyncDriveClient(transport: transport, tokens: tokens, clock: clock)
        self.state = (try? stateStore.load()) ?? SyncPersistentState()
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
        status.lastError = state.lastError
        status.exportMessage = exportState.settingsMessage
        status.cleanupNeedsSignIn = state.phase == .stopping && (state.cleanup?.authLost ?? false)
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
        clockDiscontinuities += 1
        if let source { submit(source) }
    }

    // MARK: Scheduling

    /// When `tick()` next has work, or nil when nothing is scheduled.
    public func nextWakeup() -> Date? {
        switch state.phase {
        case .active: return nextPublishDue()
        case .stopping: return nextCleanupDue()
        case .off, .stopped: return nil
        }
    }

    func nextPublishDue() -> Date? {
        guard state.phase == .active, !state.needsSignIn, state.ownership == nil, source != nil else { return nil }
        let now = clock.now()
        let slot = lastAttemptAt.map { $0.addingTimeInterval(Self.minimumInterval) } ?? now
        let forced = state.repairPending && state.forcedPublishes < Self.maxForcedPublishes
        let material = publishedMaterial == nil || sourceMaterial != publishedMaterial
        var due: Date
        if forced || material {
            due = slot
        } else {
            let heartbeat = (state.lastSuccessfulPublishAt ?? .distantPast).addingTimeInterval(Self.heartbeatInterval)
            due = max(slot, heartbeat)
        }
        if let retryAt { due = max(due, retryAt) }
        return due
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
    /// active. One run at a time.
    public func tick() async {
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
        if state.phase == .stopping { await runCleanup() }
    }

    // MARK: Session

    /// Turns sync on after a sign-in stored its refresh token. Every session
    /// gets a fresh `publisherId`, kept in the Keychain until Stop finishes.
    public func activate(account: SyncAccount) throws {
        guard state.canStart else { throw SyncActivationError.unavailable }
        let publisherId = UUID().uuidString.lowercased()
        do {
            try secrets.write(publisherId, account: SyncSecretAccount.publisherId)
            guard try secrets.read(SyncSecretAccount.publisherId) == publisherId else { throw SyncActivationError.keychain }
        } catch {
            throw SyncActivationError.keychain
        }
        var fresh = SyncPersistentState()
        fresh.phase = .active
        fresh.account = account
        fresh.abandoned = state.abandoned
        state = fresh
        persist()
        publisherIdCache = publisherId
        source = nil
        sourceMaterial = nil
        publishedMaterial = nil
        lastAttemptAt = nil
        failures = 0
        retryAt = nil
        publishedThisRun = false
        takeOverRequested = false
        clockTrust = SyncClockTrust()
        clockSample = (nil, nil)
        exportState = SnapshotExportState()
    }

    /// A sign-in for the same account restored access: "Sign in again" while
    /// active, or "Sign in to finish cleanup" while stopping. Publishing
    /// stays forbidden during cleanup and the cleanup keeps its own
    /// `publisherId`.
    public func reauthorized(account: SyncAccount) throws {
        let expected = state.phase == .stopping ? state.cleanup?.account : state.account
        guard expected?.permissionId == account.permissionId else { throw SyncSignInError.wrongAccount }
        failures = 0
        retryAt = nil
        switch state.phase {
        case .active:
            state.needsSignIn = false
            state.lastError = nil
        case .stopping:
            state.cleanup?.authLost = false
            state.lastError = nil
        case .off, .stopped:
            return
        }
        persist()
    }

    /// "Take over": the next upload writes this Mac's id over the other one.
    public func takeOver() {
        guard state.phase == .active, state.ownership != nil else { return }
        state.ownership = nil
        takeOverRequested = true
        persist()
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

    private func publish() async {
        guard state.phase == .active, let source else { return }
        let version = sourceVersion
        let started = clock.now()
        lastAttemptAt = started

        // An export failure withholds the publish before Google is contacted;
        // the last good remote document stays in place.
        guard exportState.prepare(exportInput(source, publishedAt: started)) != nil else { return }

        if state.repairPending && state.forcedPublishes < Self.maxForcedPublishes {
            state.forcedPublishes += 1
        }
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
                    if publishedThisRun {
                        state.ownership = .tookOver(label: await foreignLabel(fileId))
                        persist()
                        return
                    }
                    if let modified = metadata.modifiedTime,
                       clock.now().timeIntervalSince(modified) < Self.foreignWindow {
                        state.ownership = .otherMacSyncing(label: await foreignLabel(fileId))
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

            guard let document = exportState.prepare(exportInput(source, publishedAt: sampledAt)) else { return }
            let bytes = document.data
            let request = fileId.map { drive.updateRequest(fileId: $0, content: bytes, publisherId: publisherId) }
                ?? drive.createRequest(content: bytes, publisherId: publisherId)
            let outcome = await upload(request)
            // Stop arrived meanwhile: no verification and no repair.
            guard state.phase == .active else { return }

            switch outcome {
            case .confirmed(let id):
                state.fileId = id
                state.lastSuccessfulPublishAt = clock.now()
                state.lastError = nil
                failures = 0
                retryAt = nil
                takeOverRequested = false
                publishedThisRun = true
                publishedMaterial = SyncMaterial.key(bytes)
                if version == sourceVersion { sourceMaterial = publishedMaterial }
                if state.repairPending {
                    let remote = try await drive.download(fileId: id)
                    guard state.phase == .active else { return }
                    if SyncDriveClient.sha256(remote) == SyncDriveClient.sha256(bytes) {
                        state.repairPending = false
                        state.forcedPublishes = 0
                    } else {
                        state.lastError = "Older sync data reached Drive; publishing again"
                    }
                }
            case .uncertain:
                state.repairPending = true
                state.lastError = "The last upload's outcome is unknown; publishing again"
            case .failed(let error):
                throw error
            }
            persist()
        } catch {
            failed(error)
        }
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
        } catch SyncDriveError.notFound {
            // The file went away (a takeover's Stop): rediscover next time.
            state.fileId = nil
            return .failed(SyncDriveError.notFound)
        } catch {
            return .failed(error)
        }
    }

    private func failed(_ error: Error) {
        guard state.phase == .active else { return }
        if case SyncAuthError.refresh(let failure) = error, failure.isTerminal {
            state.needsSignIn = true
            state.lastError = "Google stopped accepting FrugalBar's sign-in"
            retryAt = nil
        } else if case SyncAuthError.notSignedIn = error {
            state.needsSignIn = true
            state.lastError = "Google stopped accepting FrugalBar's sign-in"
            retryAt = nil
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

    private func persist() {
        do {
            try stateStore.save(state)
        } catch {
            state.lastError = "Couldn't save sync state"
        }
    }

    // MARK: Stop (REQ-MAC-STOP)

    /// "Stop syncing". Step 1 is one atomic write of `stopping` and the
    /// cleanup record, before any network call; from then on nothing
    /// publishes or repairs. The rest runs now and on later ticks.
    public func stop() async {
        switch state.phase {
        case .active:
            let publisherId = (try? sessionPublisherId()) ?? ""
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
                try stateStore.save(next)
            } catch {
                state.lastError = "Couldn't save sync state"
                return
            }
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

    /// "Finish without deleting": stop now, leave the data, and keep a notice
    /// naming the account so the owner can delete it in Drive.
    public func finishWithoutDeleting() {
        guard state.phase == .stopping, let record = state.cleanup, record.authLost else { return }
        try? secrets.delete(record.refreshTokenAccount)
        try? secrets.delete(SyncSecretAccount.publisherId)
        var next = state
        next.phase = .stopped
        next.cleanup = nil
        next.fileId = nil
        next.lastError = nil
        if let account = record.account { next.abandoned = SyncAbandonedData(account: account) }
        state = next
        publisherIdCache = nil
        persist()
    }

    private func runCleanup() async {
        guard state.phase == .stopping, !cleaning, let initial = state.cleanup, !initial.authLost else { return }
        if let retryAt, retryAt > clock.now() { return }
        cleaning = true
        defer { cleaning = false }
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
            try stateStore.save(next)
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
        try stateStore.save(next)
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
}
