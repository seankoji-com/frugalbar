import Foundation

/// What an external-source watcher derived from one fetch, with the durable
/// checkpoint it wants to write held back until the events are recorded.
///
/// The catalog watcher's checkpoint is the new baseline catalog; the feed
/// watcher's is the set of item ids it has now judged. Writing either before
/// the events were stored meant a crash or a failed insert in between lost
/// those events for good: the next poll diffed against the moved baseline
/// and never derived them again. `AIEventEngine` therefore records the
/// events first and calls `commit` only once that succeeded; if recording
/// fails, nothing moves and the next poll re-derives the same events, which
/// `recordEvents` deduplicates.
public struct PendingPoll: Sendable {
    /// Candidate events, not yet recorded.
    public let events: [AIEvent]
    /// True when at least one source actually answered. False means nothing
    /// was reachable, so the caller should retry sooner than its normal cadence.
    public let fetched: Bool
    /// Writes the checkpoint. Idempotent for the catalog (an upsert) and for
    /// feed items (`INSERT OR IGNORE`).
    public let commit: @Sendable () async throws -> Void

    public init(events: [AIEvent], fetched: Bool, commit: @escaping @Sendable () async throws -> Void) {
        self.events = events
        self.fetched = fetched
        self.commit = commit
    }

    public static let empty = PendingPoll(events: [], fetched: false, commit: {})
}
