import Foundation
import Synchronization

/// Where a sync session is in its life. `off` is a Mac that never turned
/// sync on; `stopped` is one that turned it off and finished cleaning up.
public enum SyncPhase: String, Codable, Sendable {
    case off
    case active
    case stopping
    case stopped
}

/// The steps of the Stop protocol after its first atomic write (D§2.2.C).
public enum SyncStopStep: String, Codable, Sendable, CaseIterable {
    /// Cancel or await the in-flight upload.
    case settleInFlight
    /// Delete the file if it carries this session's `publisherId`.
    case deleteOwn
    /// Re-list at +2 min and delete this session's files.
    case relistFirst
    /// Re-list at +10 min, likewise.
    case relistSecond
    /// Delete the refresh token. Then one atomic write sets `stopped`.
    case deleteToken
}

/// Written atomically with `stopping`, before any network call. Holds what
/// cleanup needs to finish after a crash: the session's id, the account, the
/// Keychain item to delete and the two re-list deadlines.
public struct SyncCleanupRecord: Codable, Sendable, Equatable {
    public var publisherId: String
    public var account: SyncAccount?
    public var refreshTokenAccount: String
    public var relistAt: [Date]
    public var completed: [SyncStopStep]
    /// The refresh token failed terminally: cleanup waits for "Sign in to
    /// finish cleanup" or "Finish without deleting".
    public var authLost: Bool
    /// The session confirmed an upload, so the file it deletes is the one
    /// that account's notice was about.
    public var publishedThisSession: Bool

    public func isDone(_ step: SyncStopStep) -> Bool { completed.contains(step) }
}

/// "FrugalBar couldn't delete its sync data from <email>": persisted when the
/// owner chooses "Finish without deleting".
public struct SyncAbandonedData: Codable, Sendable, Equatable {
    public var account: SyncAccount
}

/// Who else is writing the canonical file.
public enum SyncOwnership: Codable, Sendable, Equatable {
    /// Another session wrote it less than an hour ago; this Mac has not
    /// published to it. "Another Mac (label) is syncing — Take over?"
    case otherMacSyncing(label: String?)
    /// This session had been publishing and found another id: it stops.
    /// "Another Mac took over syncing".
    case tookOver(label: String?)
}

/// Everything sync keeps between launches, apart from the two Keychain
/// items. One JSON file, written atomically, so each transition is a single
/// write.
public struct SyncPersistentState: Codable, Sendable, Equatable {
    public var phase: SyncPhase = .off
    public var account: SyncAccount?
    /// Terminal refresh failure while active: publishing stops, nothing
    /// retries, Settings says "Sign in again".
    public var needsSignIn = false
    public var ownership: SyncOwnership?
    public var fileId: String?
    public var lastSuccessfulPublishAt: Date?
    public var lastError: String?
    /// An upload's outcome was uncertain: the next publishes are forced and
    /// verified until a verification read matches.
    public var repairPending = false
    /// Forced publishes in the current repair run (at most 3).
    public var forcedPublishes = 0
    public var cleanup: SyncCleanupRecord?
    public var abandoned: SyncAbandonedData?

    public init() {}
}

public protocol SyncStateStore: Sendable {
    func load() throws -> SyncPersistentState
    /// One atomic write.
    func save(_ state: SyncPersistentState) throws
}

/// `~/Library/Application Support/FrugalBar/sync-state.json`, mode 0600.
public struct FileSyncStateStore: SyncStateStore {
    public let file: URL

    public init(file: URL = FileSyncStateStore.defaultFile) { self.file = file }

    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrugalBar", isDirectory: true)
            .appendingPathComponent("sync-state.json")
    }

    public func load() throws -> SyncPersistentState {
        guard FileManager.default.fileExists(atPath: file.path) else { return SyncPersistentState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncPersistentState.self, from: Data(contentsOf: file))
    }

    public func save(_ state: SyncPersistentState) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// A state store held in memory, for previews and tests.
public final class InMemorySyncStateStore: SyncStateStore {
    private let value: Mutex<SyncPersistentState>
    public init(_ initial: SyncPersistentState = SyncPersistentState()) { value = Mutex(initial) }
    public func load() throws -> SyncPersistentState { value.withLock { $0 } }
    public func save(_ state: SyncPersistentState) throws { value.withLock { $0 = state } }
}
