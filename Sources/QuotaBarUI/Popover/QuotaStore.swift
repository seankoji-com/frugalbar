import Foundation
import Observation
import QuotaBarCore

/// Observable view state for the popover and the menu bar.
///
/// Exists so that neither surface has to rebuild the other. The previous
/// revision rebuilt the popover's `NSHostingController` on every refresh —
/// destroying view state, re-triggering `onAppear`, and so kicking off another
/// refresh in a loop — and had two components racing to own a single
/// `BackgroundScheduler.onRefresh` closure.
@MainActor
@Observable
public final class QuotaStore {

    public private(set) var snapshots: [QuotaSnapshot] = []
    public private(set) var summary: SystemHealthSummary = .compute(from: [])
    public private(set) var isRefreshing = false
    /// True once a poll has completed. Lets the popover tell "still loading"
    /// from "loaded, and every provider is hidden".
    public private(set) var hasLoaded = false
    /// Recent-pace forecast per provider instance, from recorded history. Empty
    /// when no `readingsLoader` was given or history is too thin to fit a trend.
    /// Keyed by `snapshot.id`, so two OpenCode Go workspaces get their own
    /// forecast rather than one overwriting the other.
    public private(set) var forecasts: [String: BurnRateForecast] = [:]
    /// The most recent AI-platform events, newest first, for the popover's
    /// events section. Empty when no `eventsLoader` was given.
    public private(set) var recentEvents: [AIEvent] = []
    /// Recorded balance-over-time points per series id, for the popover's inline
    /// sparklines. Empty when no loader was given or a series has no history.
    /// A short window on purpose: the strip answers "which way is this moving",
    /// not "what did I hold a month ago" — the inspector reads the long window.
    public private(set) var balanceSeries: [String: [BalancePoint]] = [:]
    /// How far back the inline sparklines read.
    public static let balanceLookback: TimeInterval = 7 * 86_400
    /// The inline read's bucket width: hourly keeps a week under ~170 points,
    /// which is more than a 46pt strip can resolve.
    public static let balanceBucketSeconds = 3_600
    /// How many events `recentEvents` holds at most.
    public static let recentEventsLimit = 20

    /// Called on the main actor whenever `summary` changes.
    ///
    /// A plain callback rather than observation plumbing: there is exactly one
    /// owner (the AppDelegate, which redraws the status item), and it is set
    /// once at construction. This is not the shared-mutable-callback pattern
    /// that previously let the popover clobber the menu bar's refresh handler.
    public var onSummaryChange: (@MainActor (SystemHealthSummary) -> Void)?

    private let manager: QuotaManager
    private let historyRecorder: (@Sendable ([QuotaSnapshot]) async -> Void)?
    private let readingsLoader: (@Sendable (_ since: Date) async -> [QuotaHistoryStore.ReadingRecord])?
    private let vendorReadingsLoader: (@Sendable (_ vendor: VendorIdentifier, _ since: Date?) async -> [QuotaHistoryStore.ReadingRecord]?)?
    private let eventsLoader: (@Sendable (_ vendor: VendorIdentifier?, _ instanceId: String?, _ kinds: Set<AIEventKind>?, _ since: Date?, _ limit: Int?) async -> [AIEvent]?)?
    private let tokenUsageLoader: (@Sendable (_ since: Date, _ until: Date, _ bucketSeconds: Int, _ anchor: Date) async -> QuotaHistoryStore.TokenUsage?)?
    private let balanceSeriesLoader: (@Sendable (_ since: Date, _ until: Date, _ bucketSeconds: Int, _ seriesIds: [String]?) async -> [String: [BalancePoint]]?)?
    private let activityStatusLoader: (@Sendable () async -> ActivityIngestionEngine.Status?)?

    /// - Parameters:
    ///   - readingsLoader: every vendor's readings since a date, for the
    ///     recent-pace forecast computed on each reload.
    ///   - vendorReadingsLoader: one vendor's readings, for the detail
    ///     inspector's history and burndown charts. Fetched on demand, never
    ///     on the refresh path. Returns nil when the history could not be
    ///     read, which the inspector says rather than counting zero readings.
    ///   - eventsLoader: recorded AI-platform events, newest first, optionally
    ///     narrowed to one vendor and one instance. Used both for
    ///     `recentEvents` on each reload and on demand by the inspector.
    ///     Returns nil when the events could not be read.
    ///   - tokenUsageLoader: raw token consumption per source per time bucket,
    ///     for the desktop widget's Tokens layout. Returns nil when the
    ///     history could not be read, which the widget says rather than
    ///     drawing an empty chart.
    ///   - balanceSeriesLoader: recorded balance-over-time points per series id,
    ///     for the popover's inline sparklines and the inspector's balance
    ///     chart. `seriesIds` nil reads every series. Returns nil when the
    ///     history could not be read.
    ///   - activityStatusLoader: whether the local-activity ingestion has
    ///     finished its first pass. Without it an empty token chart cannot be
    ///     told from a chart that is still being filled.
    public init(
        manager: QuotaManager = .shared,
        historyRecorder: (@Sendable ([QuotaSnapshot]) async -> Void)? = nil,
        readingsLoader: (@Sendable (_ since: Date) async -> [QuotaHistoryStore.ReadingRecord])? = nil,
        vendorReadingsLoader: (@Sendable (_ vendor: VendorIdentifier, _ since: Date?) async -> [QuotaHistoryStore.ReadingRecord]?)? = nil,
        eventsLoader: (@Sendable (_ vendor: VendorIdentifier?, _ instanceId: String?, _ kinds: Set<AIEventKind>?, _ since: Date?, _ limit: Int?) async -> [AIEvent]?)? = nil,
        tokenUsageLoader: (@Sendable (_ since: Date, _ until: Date, _ bucketSeconds: Int, _ anchor: Date) async -> QuotaHistoryStore.TokenUsage?)? = nil,
        balanceSeriesLoader: (@Sendable (_ since: Date, _ until: Date, _ bucketSeconds: Int, _ seriesIds: [String]?) async -> [String: [BalancePoint]]?)? = nil,
        activityStatusLoader: (@Sendable () async -> ActivityIngestionEngine.Status?)? = nil
    ) {
        self.manager = manager
        self.historyRecorder = historyRecorder
        self.readingsLoader = readingsLoader
        self.vendorReadingsLoader = vendorReadingsLoader
        self.eventsLoader = eventsLoader
        self.tokenUsageLoader = tokenUsageLoader
        self.balanceSeriesLoader = balanceSeriesLoader
        self.activityStatusLoader = activityStatusLoader
    }

    /// One vendor's recorded readings since `since` (all of them when nil).
    /// Empty when no loader was injected; nil when the history could not be
    /// read — a failure to read, not an absence of readings.
    public func readings(for vendor: VendorIdentifier, since: Date?) async -> [QuotaHistoryStore.ReadingRecord]? {
        guard let vendorReadingsLoader else { return [] }
        return await vendorReadingsLoader(vendor, since)
    }

    /// How far the local-activity ingestion has got. nil when it cannot be
    /// said, which callers must not read as "complete".
    public func activityIngestionStatus() async -> ActivityIngestionEngine.Status? {
        guard let activityStatusLoader else { return nil }
        return await activityStatusLoader()
    }

    /// Raw token consumption per source per time bucket. nil when the history
    /// could not be read, or no loader was injected — a failure to read, not
    /// an absence of activity.
    public func tokenUsage(
        since: Date, until: Date, bucketSeconds: Int, anchor: Date
    ) async -> QuotaHistoryStore.TokenUsage? {
        guard let tokenUsageLoader else { return nil }
        return await tokenUsageLoader(since, until, bucketSeconds, anchor)
    }

    /// One balance series' points over `since ... until`, thinned to
    /// `bucketSeconds`-wide buckets. nil when no loader was injected or the
    /// history could not be read — a failure to read, which the inspector says
    /// rather than drawing an empty chart.
    public func balancePoints(
        seriesId: String, since: Date, until: Date, bucketSeconds: Int
    ) async -> [BalancePoint]? {
        guard let balanceSeriesLoader else { return nil }
        guard let series = await balanceSeriesLoader(since, until, bucketSeconds, [seriesId]) else {
            return nil
        }
        return series[seriesId] ?? []
    }

    /// Recorded events, newest first, optionally scoped to one vendor and one
    /// of its instances. Empty when no loader was injected; nil when the
    /// events could not be read.
    ///
    /// `instanceId` keeps two OpenCode Go workspaces from reading each other's
    /// resets and restores; the vendor's own events (no instance) are returned
    /// either way.
    public func events(
        for vendor: VendorIdentifier?,
        instanceId: String? = nil,
        kinds: Set<AIEventKind>? = nil,
        since: Date?,
        limit: Int?
    ) async -> [AIEvent]? {
        guard let eventsLoader else { return [] }
        return await eventsLoader(vendor, instanceId, kinds, since, limit)
    }

    /// The kinds the popover's card shows: resets, outages and newly
    /// selectable models. Scheduled rollovers are logged for every vendor
    /// and would otherwise take every one of the `recentEventsLimit` slots
    /// before the card filters them.
    public static let recentEventKinds: Set<AIEventKind> = Set(AIEventKind.surfaced)

    /// The vendors with a credential FrugalBar could use, whatever their last
    /// reading was. External sources (status pages, reset trackers, model
    /// lists) are only read for these: an outage on a product the user does
    /// not have is not their event.
    public var configuredVendors: Set<VendorIdentifier> {
        Set(snapshots.filter { $0.status.unavailableReason != .notConfigured }.map(\.vendorId))
    }

    /// Re-reads `recentEvents`. Called after every reload and by whoever
    /// records new events, so the popover section is never a poll behind.
    public func reloadRecentEvents() async {
        guard let eventsLoader else { return }
        recentEvents = await eventsLoader(nil, nil, Self.recentEventKinds, nil, Self.recentEventsLimit) ?? []
    }

    /// Loads from cache when fresh, otherwise fetches.
    public func load() async {
        await run { await self.manager.refresh() }
    }

    public func clearMonthlyCredit() async {
        await manager.clearMonthlyCredit()
        await reloadFromCache()
    }

    /// Explicit user action — bypasses the cache.
    public func forceRefresh() async {
        if isRefreshing {
            // Join the manager's pass while it can still select only skipped
            // or failed providers. Queuing a separate forced pass here would
            // re-fetch every provider the automatic pass just read successfully.
            if !(await manager.queueUserRefreshIfActive()) { forcedRefreshPending = true }
            return
        }
        await run { await self.manager.forceRefresh() }
    }

    /// Re-applies Preferences → Providers: a hidden provider is dropped and a
    /// newly shown one fetched. Vendors the user has already refreshed inside
    /// the poll floor are served from cache, so repeated toggles cannot hammer
    /// a vendor.
    ///
    /// If a refresh is already running it was planned against the old
    /// preferences (a provider shown meanwhile was left out of that fetch),
    /// so this queues one more pass for when it ends instead of dropping the
    /// request.
    public func applyProviderPreferences() async {
        if isRefreshing {
            forcedRefreshPending = true
            return
        }
        await forceRefresh()
    }

    private var forcedRefreshPending = false

    private func run(_ fetch: @escaping @Sendable () async -> [String: QuotaSnapshot]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await fetch()
        await reloadFromCache()
        while forcedRefreshPending {
            forcedRefreshPending = false
            _ = await manager.forceRefresh()
            await reloadFromCache()
        }
    }

    private func reloadFromCache() async {
        let snaps = await manager.sortedSnapshots()
        self.hasLoaded = true
        self.snapshots = snaps
        self.summary = SystemHealthSummary.compute(from: snaps)
        if let historyRecorder {
            await historyRecorder(snaps)
        }
        // After recording, so this poll's reading is part of the trend.
        if let readingsLoader {
            let now = Date()
            let readings = await readingsLoader(now.addingTimeInterval(-BurnRateForecast.defaultLookback))
            var next: [String: BurnRateForecast] = [:]
            for snapshot in snaps {
                next[snapshot.id] = BurnRateForecast.binding(for: snapshot, readings: readings, now: now)
            }
            self.forecasts = next
        }
        // The tray also reads forecasts. Notify after this poll's history and
        // forecasts are loaded, so it cannot render the previous poll's pace.
        onSummaryChange?(self.summary)
        // After recording, so this poll's balance is the strip's right-hand end.
        // A read that fails leaves the last good series in place rather than
        // blanking every strip on a transient error; the next reload replaces it.
        if let balanceSeriesLoader {
            let now = Date()
            let ids = BalanceSeries.seriesIDs(in: snaps)
            if !ids.isEmpty,
               let series = await balanceSeriesLoader(
                   now.addingTimeInterval(-Self.balanceLookback), now,
                   Self.balanceBucketSeconds, ids) {
                self.balanceSeries = series
            }
        }
        await reloadRecentEvents()
    }

}
