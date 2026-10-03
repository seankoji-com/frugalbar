import Foundation

/// Turns poll transitions and external sources into recorded `AIEvent`s.
///
/// Owns the one deduplication point: every candidate goes through
/// `QuotaHistoryStore.recordEvents`, and only what that call reports as newly
/// inserted is returned. Callers notify on the return value and nothing else,
/// so a restart, a re-poll, or a source that re-serves an item can never post
/// the same banner twice.
///
/// Three external sources, each on its own cadence, independent of the
/// 2-minute quota poll that drives this:
///
/// - Official status pages, every `statusPollInterval`: an outage is only
///   worth knowing about while it is happening.
/// - Community reset trackers, every `trackerPollInterval`.
/// - Each account's own model list, every `modelPollInterval`. These calls
///   carry the user's credential, like the quota poll itself.
public actor AIEventEngine {

    public static let statusPollInterval: TimeInterval = 10 * 60
    public static let trackerPollInterval: TimeInterval = 60 * 60
    public static let modelPollInterval: TimeInterval = 60 * 60
    /// When a source answered nothing (launch before Wi-Fi is up, say), its
    /// next attempt comes this soon rather than a full interval later.
    public static let failedPollRetryInterval: TimeInterval = 5 * 60
    /// How often old events are pruned.
    public static let pruneInterval: TimeInterval = 6 * 3600
    /// Events are small and stay useful for a long time — "when did OpenAI
    /// last reset limits?" is a question about months, not days.
    public static let eventRetentionInterval: TimeInterval = 365 * 86_400

    enum Source: String, CaseIterable, Sendable {
        case status, trackers, models

        var interval: TimeInterval {
            switch self {
            case .status:   AIEventEngine.statusPollInterval
            case .trackers: AIEventEngine.trackerPollInterval
            case .models:   AIEventEngine.modelPollInterval
            }
        }
    }

    private let store: QuotaHistoryStore
    private let trackerWatcher: ResetTrackerWatcher
    private let statusWatcher: StatusIncidentWatcher
    private let modelWatcher: AccountModelWatcher
    private let isTrackingEnabled: @Sendable () -> Bool
    private var nextPoll: [Source: Date] = [:]

    /// - Parameters:
    ///   - trackerFetcher / statusFetcher / modelLister: injectable so tests
    ///     never touch the network and can assert whether a fetch happened.
    ///   - isTrackingEnabled: read on every external poll, so flipping the
    ///     Settings toggle takes effect without a relaunch.
    public init(
        store: QuotaHistoryStore,
        trackerFetcher: @escaping ResetTrackerWatcher.Fetcher = ResetTrackerWatcher.liveFetch,
        statusFetcher: @escaping StatusIncidentWatcher.Fetcher = StatusIncidentWatcher.liveFetch,
        modelLister: @escaping AccountModelWatcher.Lister = AccountModelLister.live,
        trackers: [ResetTracker] = ResetTracker.all,
        statusPages: [StatusPage] = StatusPage.all,
        modelVendors: [VendorIdentifier] = AccountModelLister.supportedVendors,
        isTrackingEnabled: @escaping @Sendable () -> Bool = { CredentialStore.isEventTrackingEnabled }
    ) {
        self.store = store
        self.trackerWatcher = ResetTrackerWatcher(trackers: trackers, fetch: trackerFetcher)
        self.statusWatcher = StatusIncidentWatcher(pages: statusPages, fetch: statusFetcher)
        self.modelWatcher = AccountModelWatcher(vendors: modelVendors, list: modelLister)
        self.isTrackingEnabled = isTrackingEnabled
    }

    /// Records the events derived from one quota poll and returns the new ones.
    public func recordPollEvents(
        resets: [QuotaResetEvent],
        restores: [UsageRestoredEvent],
        creditGrants: [ResetCreditGrantedEvent],
        now: Date
    ) async -> [AIEvent] {
        let candidates = resets.compactMap { Self.event(for: $0, now: now) }
            + restores.map { Self.event(for: $0, now: now) }
            + creditGrants.map { Self.event(for: $0, now: now) }
        return await record(candidates)
    }

    /// Polls whichever external sources are due, records what they produced,
    /// prunes old events, and returns the new ones.
    ///
    /// - Parameter vendors: the vendors the user has configured. A reset or
    ///   outage for a product they do not use is not recorded at all.
    ///
    /// With tracking off nothing is fetched and no schedule advances, so
    /// switching tracking on polls every source on the very next call.
    public func pollExternalSources(now: Date, vendors: Set<VendorIdentifier>) async -> [AIEvent] {
        // Retention is independent of tracking: poll-derived events (resets,
        // restores, credits) are recorded whether or not anything external
        // is polled, so they must age out either way.
        await pruneIfDue(now: now)

        guard isTrackingEnabled(), !vendors.isEmpty else { return [] }
        let due = Source.allCases.filter { nextPoll[$0].map { now >= $0 } ?? true }
        guard !due.isEmpty else { return [] }

        var fresh: [AIEvent] = []
        for source in due {
            let pending: PendingPoll
            switch source {
            case .status:   pending = await statusWatcher.prepare(vendors: vendors, now: now)
            case .trackers: pending = await trackerWatcher.prepare(vendors: vendors, now: now)
            case .models:   pending = await modelWatcher.prepare(store: store, vendors: vendors, now: now)
            }
            guard pending.fetched else {
                // Nothing answered: retry soon rather than a full interval on.
                nextPoll[source] = now.addingTimeInterval(min(source.interval, Self.failedPollRetryInterval))
                continue
            }
            // Events first, checkpoint second. A checkpoint written before its
            // events were stored loses them for good — see `PendingPoll`.
            do {
                fresh += try await store.recordEvents(pending.events)
            } catch {
                // Not recorded: retry soon, like a source that answered nothing,
                // rather than waiting out a full interval.
                NSLog("frugalbar: failed to record \(source.rawValue) events; they will be re-derived next poll: \(error)")
                nextPoll[source] = now.addingTimeInterval(min(source.interval, Self.failedPollRetryInterval))
                continue
            }
            nextPoll[source] = now.addingTimeInterval(source.interval)
            do {
                try await pending.commit()
            } catch {
                NSLog("frugalbar: failed to store the \(source.rawValue) checkpoint: \(error)")
            }
        }
        return fresh
    }

    private var lastPrune: Date?

    /// Prunes events past `eventRetentionInterval` every `pruneInterval`,
    /// whatever the tracking toggle says.
    private func pruneIfDue(now: Date) async {
        if let lastPrune, now.timeIntervalSince(lastPrune) < Self.pruneInterval { return }
        lastPrune = now
        do {
            try await store.pruneEvents(before: now.addingTimeInterval(-Self.eventRetentionInterval))
        } catch {
            NSLog("frugalbar: failed to prune AI events: \(error)")
        }
    }

    private func record(_ candidates: [AIEvent]) async -> [AIEvent] {
        guard !candidates.isEmpty else { return [] }
        do {
            return try await store.recordEvents(candidates)
        } catch {
            // Unrecorded means un-notified: a banner for an event that is not
            // in the log would be the only trace of it, and would repeat.
            NSLog("frugalbar: failed to record AI events: \(error)")
            return []
        }
    }

    // MARK: - Event builders

    /// nil when the reset carries no reset time: without it the event has no
    /// identity, and keying it on the poll time would re-announce it.
    static func event(for reset: QuotaResetEvent, now: Date) -> AIEvent? {
        guard let resetsAt = reset.resetsAt else { return nil }
        return AIEvent(
            id: AIEvent.makeID(
                kind: .usageReset, vendorId: reset.vendorId,
                components: [reset.barLabel, "\(Int(resetsAt.timeIntervalSince1970))"]),
            kind: .usageReset,
            vendorId: reset.vendorId,
            title: "\(reset.displayName) \(reset.barLabel) window reset",
            detail: nil,
            occurredAt: now,
            observedAt: now,
            source: .quotaPoll
        )
    }

    static func event(for restore: UsageRestoredEvent, now: Date) -> AIEvent {
        let before = percent(restore.previousFraction)
        let after = percent(restore.currentFraction)
        return AIEvent(
            // The measured facts: which window, which published reset, and
            // the two readings. A second restore in the same window to a
            // different figure is a different event.
            id: AIEvent.makeID(
                kind: .usageRestored, vendorId: restore.vendorId,
                components: [restore.barLabel, "\(Int(restore.resetsAt.timeIntervalSince1970))",
                             "\(before)", "\(after)"]),
            kind: .usageRestored,
            vendorId: restore.vendorId,
            title: "\(restore.displayName) \(restore.barLabel) usage restored",
            detail: restore.windowRestarted
                ? "Used fell from \(before)% to \(after)% and the window restarted early; the new reset is \(remaining(until: restore.resetsAt, now: now)) away"
                : "Used fell from \(before)% to \(after)% with \(remaining(until: restore.resetsAt, now: now)) left before the published reset",
            occurredAt: now,
            observedAt: now,
            source: .quotaPoll
        )
    }

    static func event(for grant: ResetCreditGrantedEvent, now: Date) -> AIEvent {
        let count = grant.currentCount
        return AIEvent(
            // The detector is edge-triggered, so the poll time is what tells
            // a second grant (after one was redeemed) from a re-derivation.
            id: AIEvent.makeID(
                kind: .resetCreditGranted, vendorId: grant.vendorId,
                components: ["\(grant.previousCount ?? 0)", "\(count)", "\(Int(now.timeIntervalSince1970))"]),
            kind: .resetCreditGranted,
            vendorId: grant.vendorId,
            title: "\(grant.displayName) granted a usage reset credit",
            detail: "\(count) banked reset\(count == 1 ? "" : "s") available — \(redeemHint(for: grant.vendorId))",
            occurredAt: now,
            observedAt: now,
            source: .quotaPoll
        )
    }

    /// Where the vendor lets the user spend a banked reset. Only vendors
    /// known to publish one get a specific hint; anything else gets none.
    static func redeemHint(for vendor: VendorIdentifier) -> String {
        switch vendor {
        case .openai: "redeem in Codex to refill both windows"
        case .claude: "redeem on claude.ai under Settings → Usage"
        default:      "redeem with the vendor"
        }
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    /// "4 days", "3 hours", "12 minutes" — whole units, from an explicit `now`.
    static func remaining(until date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        if seconds >= 86_400 { return unit(Int(seconds / 86_400), "day") }
        if seconds >= 3600 { return unit(Int(seconds / 3600), "hour") }
        return unit(max(1, Int(seconds / 60)), "minute")
    }
}
