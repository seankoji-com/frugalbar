import Foundation

/// Turns poll transitions and external sources into recorded `AIEvent`s.
///
/// Owns the one deduplication point: every candidate goes through
/// `QuotaHistoryStore.recordEvents`, and only what that call reports as newly
/// inserted is returned. Callers notify on the return value and nothing else,
/// so a restart, a re-poll, or a feed that re-serves an item can never post the
/// same banner twice.
///
/// External sources (the OpenRouter catalog and vendor feeds) are polled at
/// most every `externalPollInterval`, independent of the 2-minute quota poll
/// that drives this: the catalog and the feeds change on the order of days,
/// and fetching a megabyte of catalog every two minutes would be rude to a
/// free, key-less endpoint.
public actor AIEventEngine {

    public static let externalPollInterval: TimeInterval = 6 * 3600
    /// Events are small and stay useful for a long time — "when did OpenAI
    /// last restore limits?" is a question about months, not days.
    public static let eventRetentionInterval: TimeInterval = 365 * 86_400

    private let store: QuotaHistoryStore
    private let catalogWatcher: OpenRouterCatalogWatcher
    private let feedWatcher: VendorFeedWatcher
    private let isTrackingEnabled: @Sendable () -> Bool
    private var lastExternalPoll: Date?

    /// - Parameters:
    ///   - catalogFetcher / feedFetcher: injectable so tests never touch the
    ///     network and can assert whether a fetch happened at all.
    ///   - isTrackingEnabled: read on every external poll, so flipping the
    ///     Settings toggle takes effect without a relaunch.
    public init(
        store: QuotaHistoryStore,
        catalogFetcher: @escaping OpenRouterCatalogWatcher.Fetcher = OpenRouterCatalogWatcher.liveFetch,
        feedFetcher: @escaping VendorFeedWatcher.Fetcher = VendorFeedWatcher.liveFetch,
        feeds: [VendorFeed] = VendorFeed.all,
        isTrackingEnabled: @escaping @Sendable () -> Bool = { CredentialStore.isEventTrackingEnabled }
    ) {
        self.store = store
        self.catalogWatcher = OpenRouterCatalogWatcher(fetch: catalogFetcher)
        self.feedWatcher = VendorFeedWatcher(feeds: feeds, fetch: feedFetcher)
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

    /// Polls the catalog and the feeds when due and tracking is on, records
    /// what they produced, prunes old events, and returns the new ones.
    ///
    /// With tracking off nothing is fetched and the cadence clock does not
    /// advance, so switching tracking on polls on the very next call.
    public func pollExternalSources(now: Date) async -> [AIEvent] {
        // Retention is independent of tracking: poll-derived events (resets,
        // restores, credits) are recorded whether or not the catalog and
        // feeds are polled, so they must age out either way.
        await pruneIfDue(now: now)

        guard isTrackingEnabled() else { return [] }
        if let lastExternalPoll, now.timeIntervalSince(lastExternalPoll) < Self.externalPollInterval {
            return []
        }
        lastExternalPoll = now

        let candidates = await catalogWatcher.poll(store: store, now: now)
            + feedWatcher.poll(store: store, now: now)
        return await record(candidates)
    }

    private var lastPrune: Date?

    /// Prunes events past `eventRetentionInterval` on the external-poll
    /// cadence, whatever the tracking toggle says.
    private func pruneIfDue(now: Date) async {
        if let lastPrune, now.timeIntervalSince(lastPrune) < Self.externalPollInterval { return }
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
