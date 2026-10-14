import AppKit
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

// Opt-in offscreen renders of production views. Fixtures never enter a live store.
@Suite("UX renders", .enabled(if: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"] != nil))
@MainActor
struct UXRenderTests {
    private struct FixtureProvider: QuotaProvider {
        let snapshot: QuotaSnapshot
        var vendorId: VendorIdentifier { snapshot.vendorId }
        var displayName: String { snapshot.displayName }
        var category: MetricCategory { snapshot.category }
        var instanceID: String { snapshot.id }
        func fetchSnapshot() async throws -> QuotaSnapshot { snapshot }
    }

    @Test func render() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_791_848_000)
        func snapshot(_ vendor: VendorIdentifier, _ name: String, _ fraction: Double) -> QuotaSnapshot {
            QuotaSnapshot(id: vendor == .opencode ? "opencode.gamma" : vendor.rawValue,
                vendorId: vendor, displayName: name, category: .aiSubscriptions,
                metric: .subscription(tierName: "Review fixture", renewalDate: nil), status: .measured(.none),
                resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: DualBarMetrics(primaryFraction: fraction, expectedPaceFraction: 0.5, label: "WK",
                    usedText: "\(Int(fraction * 100))% used", resetText: "Resets in 3d",
                    resetsAt: now.addingTimeInterval(3.5 * 86400), windowLength: 7 * 86400),
                row2: DualBarMetrics(primaryFraction: 0.2, label: "5H", usedText: "20% used",
                    resetText: "Resets in 1h", resetsAt: now.addingTimeInterval(3600)))
        }
        let snapshots = [snapshot(.claude, "Claude", 0.65), snapshot(.opencode, "OpenCode Go · Gamma workspace", 0.45),
                         snapshot(.commandcode, "Command Code", 0.9)] + soleMeters(now: now)
        try await save(VStack(spacing: 12) {
            Text("Review fixtures · no live account data").font(.caption).foregroundStyle(Theme.outline)
            AdviceSectionView(advice: .evaluate(from: snapshots), onActionTap: {})
            MetricSectionView(category: .aiSubscriptions, snapshots: snapshots, onSelect: { _ in })
            APICreditSectionView(entries: creditFixtures())
            FooterActionsView(summary: .compute(from: snapshots), isRefreshing: false,
                onOpenSettings: {}, onQuit: {}, onRefresh: {})
        }.padding(12).frame(width: 384).background(Theme.surface), name: "popover", directory: directory)
        try await save(MetricDetailModalView(snapshot: snapshots[1], readingsLoader: { _, _ in [] },
            eventsLoader: { _, _, _, _, _ in [] }, onClose: {}).frame(width: 384, height: 400),
            name: "inspector-short", directory: directory)
        // A vendor's failed poll retains its balances, and the card must not
        // present them as this poll's reading. OpenAI's row here is stale;
        // Claude's, in the same card, is not — a whole card marked stale would
        // not show that the marker belongs to the vendor.
        try await save(VStack(spacing: 12) {
            Text("Credit card · OpenAI's newest poll failed").font(.caption).foregroundStyle(Theme.outline)
            APICreditSectionView(entries: creditFixtures(), staleVendors: ["openai"])
        }.padding(12).frame(width: 384).background(Theme.surface),
            name: "credit-section-stale", directory: directory)
        let history = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        try await save(QuotaTimelineChart(segments: [], timeRange: .last7Days)
            .frame(width: 640, height: 240).background(Theme.card),
            name: "history-empty", directory: directory)
        try await save(EventsListView(store: history, isSampleMode: false)
            .frame(width: 640, height: 320).background(Theme.surface),
            name: "events-empty", directory: directory)
        try await save(HistoryRootView(liveStore: history, sampleStore: history).frame(width: 640, height: 460),
                 name: "history-minimum", directory: directory)
        let graphQL = QuotaSnapshot(id: "github_graphql", vendorId: .githubGraphql, displayName: "GitHub GraphQL",
            category: .developerLimits, metric: .count(remaining: 600, limit: 1000, unitName: "points"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.4, label: "GraphQL", usedText: "40% used"))
        let providers = (snapshots + [graphQL]).map { FixtureProvider(snapshot: $0) }
        let store = QuotaStore(manager: QuotaManager(providerFactory: { providers }, displayPreferences: { .default }))
        await store.load()
        try await save(DesktopWidgetView(store: store, filters: WidgetFilters(metric: .used, layout: .overview))
            .frame(width: 320, height: 300), name: "widget-used", directory: directory)
        try await save(DesktopWidgetView(store: store, filters: WidgetFilters(vendors: [.githubGraphql], metric: .remaining, layout: .overview))
            .frame(width: 320, height: 240), name: "widget-graphql", directory: directory)
        try await save(DesktopWidgetView(store: store, filters: WidgetFilters(metric: .remaining, layout: .overview))
            .frame(width: 360, height: 300), name: "widget-two-columns", directory: directory)
        let unreadable = QuotaSnapshot(id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .unavailable(.offline), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        let unreadableStore = QuotaStore(manager: QuotaManager(
            providerFactory: { [FixtureProvider(snapshot: unreadable)] }, displayPreferences: { .default }))
        await unreadableStore.load()
        try await save(DesktopWidgetView(store: unreadableStore, filters: WidgetFilters(layout: .overview))
            .frame(width: 320, height: 240).background(Theme.surface),
            name: "widget-unreadable", directory: directory)
        let tokenChart = TokenUsagePresentation.chart(usage: .init(buckets: [
            .init(source: "codex", start: TokenUsagePresentation.window(range: .last24Hours, now: now).since.addingTimeInterval(7200),
                  tokens: 1234, records: 1)
        ], uncountedRecords: ["claude_code": 3]), filters: WidgetFilters(layout: .tokens), hidden: [],
            configured: [.claude, .openai, .gemini, .grok, .kiro], ingestion: .incomplete, now: now)
        try await save(TokenUsageChartView(chart: tokenChart, range: .last24Hours).padding(14)
            .frame(width: 320, height: 240).background(Theme.surface), name: "token-caveats", directory: directory)
    }

    /// The prepaid credit entries the API Spend & Credits card draws: a credit
    /// count (OpenAI's unit, never money), a monthly money pool with its limit
    /// as the note, and a promo credit whose expiry is a date rather than a
    /// countdown. None of them carries a bar.
    private func creditFixtures() -> [APICreditEntry] {
        [APICreditEntry(
            id: "openai.api-credits", vendorId: .openai, label: "API credits",
            metric: .credits(remaining: 62_500, unitName: "credits"),
            source: "Codex usage payload · credits.balance"),
         APICreditEntry(
            id: "claude.extra-usage", vendorId: .claude, label: "API credits",
            metric: .currency(balance: Decimal(string: "179.50")!,
                              limit: Decimal(string: "200.00")!, spent: nil, currencyCode: "USD"),
            currencyBasis: .prepaidCredit, detail: "$200.00 monthly limit",
            source: "OAuth usage payload · extra_usage"),
         APICreditEntry(
            id: "claude.promo-credit", vendorId: .claude, label: "Promo credit",
            metric: .currency(balance: Decimal(150), limit: Decimal(200), spent: nil, currencyCode: "USD"),
            currencyBasis: .prepaidCredit, detail: "Expires 15 Nov 2026",
            source: "OAuth usage payload · iguana_necktie")]
    }

    /// The vendors that publish a single window — GitHub Copilot reports
    /// monthly only, OpenAI weekly only. Each row's one meter spans the whole
    /// grid rather than sitting in a third of the row with a faint dash either
    /// side, and this fixture is what the rendered popover shows it with. The
    /// OpenAI row also carries banked reset credits, so the ticket strip
    /// (capped, with the overflow count) is visible in the render.
    private func soleMeters(now: Date) -> [QuotaSnapshot] {
        func sole(_ vendor: VendorIdentifier, _ name: String, _ plan: String, _ token: String,
                  fraction: Double, pace: Double?, length: TimeInterval, resetsIn: TimeInterval,
                  bankedResets: Int? = nil) -> QuotaSnapshot {
            var snap = QuotaSnapshot(id: vendor.rawValue, vendorId: vendor, displayName: name, category: .aiSubscriptions,
                metric: .subscription(tierName: plan, renewalDate: nil), status: .measured(.none),
                resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: DualBarMetrics(
                    primaryFraction: fraction, expectedPaceFraction: pace, label: token,
                    usedText: "\(Int(fraction * 100))% used",
                    resetText: "Resets in \(Int(resetsIn / 86_400))d",
                    resetsAt: now.addingTimeInterval(resetsIn), windowLength: length))
            snap.resetCreditsAvailable = bankedResets
            return snap
        }
        return [sole(.copilot, "GitHub Copilot", "Pro", "MO", fraction: 1.0, pace: nil,
                     length: 30 * 86_400, resetsIn: 18 * 86_400),
                sole(.openai, "OpenAI", "Plus", "WK", fraction: 0.12, pace: 0.15,
                     length: 7 * 86_400, resetsIn: 6 * 86_400, bankedResets: 7)]
    }

    // MARK: - Detail, History, Settings and workspace order

    /// Renders the surfaces this pass reworked, from fixtures only. Readings go
    /// into a throwaway database under the render directory; the workspace
    /// list and display preferences are written to the test-host preference
    /// suite (never the user's) and removed afterwards; Settings is drawn with
    /// `readsCredentials: false`, so no Keychain item is read.
    @Test func renderReworkedSurfaces() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Relative to the clock because the History window reads its ranges
        // from it; nothing here asserts a duration.
        let now = Date()
        let beta = OpenCodeGoWorkspace(id: "render-beta", name: "Go Beta")
        let alpha = OpenCodeGoWorkspace(id: "render-alpha", name: "Go Alpha")

        func bar(_ label: String, _ used: Double?, length: TimeInterval, resetsIn: TimeInterval,
                 isBlocked: Bool = false) -> DualBarMetrics {
            let reset = now.addingTimeInterval(resetsIn)
            return DualBarMetrics(
                primaryFraction: used,
                expectedPaceFraction: DualBarMetrics.proRataPace(resetsAt: reset, windowLength: length, now: now),
                label: label, isBlocked: isBlocked,
                usedText: used.map { "\(Int($0 * 100))% used" }, resetText: nil,
                resetsAt: reset, windowLength: length)
        }
        func snapshot(_ id: String, _ vendor: VendorIdentifier, _ name: String, status: ProviderStatus = .measured(.none),
                      bars: [DualBarMetrics], plan: String? = "Review fixture") -> QuotaSnapshot {
            var s = QuotaSnapshot(
                id: id, vendorId: vendor, displayName: name, category: .aiSubscriptions,
                metric: .percentage(usedFraction: bars.first?.primaryFraction ?? 0, displayDetails: nil),
                status: status, resetsAt: bars.first?.resetsAt, lastUpdated: now.addingTimeInterval(-90),
                auxiliaryInfo: nil,
                row1: bars.count > 0 ? bars[0] : nil, row2: bars.count > 1 ? bars[1] : nil)
            s.planName = plan
            s.cliSource = "Review fixture"
            s.latencyMs = 212
            return s
        }

        let claude = snapshot("claude", .claude, "Claude", bars: [
            bar("WK", 0.62, length: 7 * 86_400, resetsIn: 3.2 * 86_400),
            bar("5H", 0.18, length: 5 * 3600, resetsIn: 2.5 * 3600),
        ])
        // The user put Beta first; Alpha's month turns over sooner, which used
        // to pull it above Beta under the automatic sort.
        let goBeta = snapshot(beta.instanceID, .opencode, beta.name, bars: [
            bar("MO", 0.35, length: 30 * 86_400, resetsIn: 20 * 86_400),
            bar("WK", 0.4, length: 7 * 86_400, resetsIn: 4 * 86_400),
        ], plan: "Go")
        let goAlpha = snapshot(alpha.instanceID, .opencode, alpha.name, status: .measured(.critical), bars: [
            bar("MO", 0.88, length: 30 * 86_400, resetsIn: 2 * 86_400),
            bar("WK", 0.97, length: 7 * 86_400, resetsIn: 1 * 86_400, isBlocked: true),
        ], plan: "Go")
        let openai = QuotaSnapshot(
            id: "openai", vendorId: .openai, displayName: "OpenAI", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.credentialRejected),
            resetsAt: nil, lastUpdated: now.addingTimeInterval(-90), auxiliaryInfo: nil)
        let snapshots = [claude, goBeta, goAlpha, openai]

        // MARK: Popover, with workspaces in the user's order under the automatic sort
        let providers = [claude, goBeta, goAlpha, openai].map { FixtureProvider(snapshot: $0) }
        let store = QuotaStore(manager: QuotaManager(
            providerFactory: { providers },
            displayPreferences: { ProviderDisplayPreferences(ordering: .automatic) }))
        await store.load()
        #expect(store.snapshots.filter { $0.vendorId == .opencode }.map(\.id) == [beta.instanceID, alpha.instanceID])
        try await save(VStack(spacing: 12) {
            Text("Review fixtures · automatic order · workspaces in the user's order").font(.caption)
                .foregroundStyle(Theme.outline)
            MetricSectionView(category: .aiSubscriptions, snapshots: store.snapshots, onSelect: { _ in })
            FooterActionsView(summary: store.summary, isRefreshing: false,
                onOpenSettings: {}, onQuit: {}, onRefresh: {})
        }.padding(12).frame(width: 384).background(Theme.surface), name: "popover-workspaces", directory: directory)

        // MARK: Readings for the inspector and the History window
        let history = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-fixture-\(UUID().uuidString).sqlite"))
        var readings: [QuotaHistoryStore.ReadingRecord] = []
        for step in stride(from: 6 * 86_400.0, through: 1800, by: -1800) {
            let at = now.addingTimeInterval(-step)
            let t = 1 - step / (6 * 86_400)
            let wobble = 0.03 * sin(step / 7_000)
            var polled: [QuotaSnapshot] = []
            func with(_ snap: QuotaSnapshot, _ bars: [DualBarMetrics]) -> QuotaSnapshot {
                var copy = snap
                copy.row1 = bars.count > 0 ? bars[0] : nil
                copy.row2 = bars.count > 1 ? bars[1] : nil
                return copy
            }
            let fiveUsed = (step.truncatingRemainder(dividingBy: 18_000)) / 18_000 * 0.6
            polled.append(with(claude, [
                DualBarMetrics(primaryFraction: 0.08 + 0.54 * t + wobble, label: "WK",
                               resetsAt: claude.row1?.resetsAt, windowLength: 7 * 86_400),
                DualBarMetrics(primaryFraction: 0.6 - fiveUsed, label: "5H", windowLength: 5 * 3600),
            ]))
            polled.append(with(goBeta, [DualBarMetrics(primaryFraction: 0.2 + 0.15 * t, label: "MO",
                                                     resetsAt: goBeta.row1?.resetsAt, windowLength: 30 * 86_400)]))
            polled.append(with(goAlpha, [DualBarMetrics(primaryFraction: 0.55 + 0.33 * t + wobble, label: "MO",
                                                      resetsAt: goAlpha.row1?.resetsAt, windowLength: 30 * 86_400)]))
            try await history.record(polled, now: at)
        }
        // Go Beta's newest poll failed: its History card must say so rather
        // than lead with the figure from the poll before.
        try await history.record([QuotaSnapshot(
            id: beta.instanceID, vendorId: .opencode, displayName: beta.name, category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.offline),
            resetsAt: nil, lastUpdated: now.addingTimeInterval(-60), auxiliaryInfo: nil)],
            now: now.addingTimeInterval(-60))
        readings = try await history.fetchReadings(vendor: .claude)
        let resetEvent = AIEvent(
            id: AIEvent.makeID(kind: .usageReset, vendorId: .claude, components: ["render"]),
            kind: .usageReset, vendorId: .claude, title: "5-hour window reset", detail: nil,
            occurredAt: now.addingTimeInterval(-9_000), observedAt: now.addingTimeInterval(-9_000), source: .quotaPoll)

        // MARK: Inspector
        var inspector = MetricDetailModalView(
            snapshot: claude, readingsLoader: { [readings] _, _ in readings },
            eventsLoader: { _, _, _, _, _ in [resetEvent] }, onClose: {})
        inspector.maxBody = 1_400
        try await save(inspector.frame(width: 384, height: 1_560).background(Theme.surface),
                       name: "inspector-detail", directory: directory)
        var blocked = MetricDetailModalView(
            snapshot: goAlpha, readingsLoader: { _, _ in [] }, eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        blocked.maxBody = 1_000
        try await save(blocked.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-blocked-workspace", directory: directory)
        var unreadable = MetricDetailModalView(
            snapshot: openai, readingsLoader: { _, _ in [] }, eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        unreadable.maxBody = 800
        try await save(unreadable.frame(width: 384, height: 760).background(Theme.surface),
                       name: "inspector-unreadable", directory: directory)
        // The history database could not be read: said as a failed read, not
        // as zero readings or "no events".
        var failedRead = MetricDetailModalView(
            snapshot: claude, readingsLoader: { _, _ in nil }, eventsLoader: { _, _, _, _, _ in nil }, onClose: {})
        failedRead.maxBody = 1_000
        try await save(failedRead.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-history-unreadable", directory: directory)

        // MARK: History
        let subjects = HistoryOverviewPresentation.subjects(
            order: [.claude, .opencode, .openai, .grok, .kiro], hidden: [.kiro], workspaces: [beta, alpha])
        try await save(
            HistoryRootView(liveStore: history, sampleStore: history,
                            subjectSource: { (subjects, ["Kiro"]) })
                .frame(width: 880, height: 1_180),
            name: "history-overview", directory: directory)
        let segments = HistoryPresentation.segments(from: HistoryPresentation.consumptionReadings(
            readings.filter { $0.measuredAt >= now.addingTimeInterval(-86_400) }))
        try await save(
            QuotaTimelineChart(segments: segments, timeRange: .last24Hours)
                .inspecting(now.addingTimeInterval(-6 * 3600))
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            name: "history-chart-readout", directory: directory)
        // Long-range sparklines, thinned exactly as the window thins them.
        for range in [HistoryPresentation.TimeRange.last30Days, .allTime] {
            let bucket = HistoryOverviewPresentation.sampleBucketSeconds(
                range: range, retention: await history.retentionInterval)
            let sampled = try await history.fetchSampledReadings(
                since: range.startDate(from: now), until: now, bucketSeconds: bucket)
            let cards = HistoryOverviewPresentation.overview(
                subjects: subjects, readings: sampled, bucketSeconds: bucket).cards
            #expect(cards.allSatisfy { $0.segments.count == 1 })
            try await save(
                HStack(spacing: 10) {
                    ForEach(cards) { HistoryOverviewCardView(card: $0, isSelected: false, onSelect: {}) }
                }
                .padding(14).frame(width: 640).background(Theme.card),
                name: "history-\(range == .allTime ? "all" : "30d")-sparkline", directory: directory)
        }

        // A real key press: the chart takes focus and the right arrow selects
        // the newest poll, with no pointer involved.
        try await saveAfterKeys(
            QuotaTimelineChart(segments: segments, timeRange: .last24Hours)
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            keys: [(48, "\t"), (124, "\u{F703}")],
            name: "history-chart-keyboard", directory: directory)
        // The control: focus alone selects nothing, so the readout above is
        // the arrow key's doing.
        try await saveAfterKeys(
            QuotaTimelineChart(segments: segments, timeRange: .last24Hours)
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            keys: [(48, "\t")],
            name: "history-chart-focus-only", directory: directory)

        let emptyHistory = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-empty-\(UUID().uuidString).sqlite"))
        try await save(
            HistoryRootView(liveStore: emptyHistory, sampleStore: emptyHistory,
                            subjectSource: { (Array(subjects.prefix(2)), ["Grok", "Kiro"]) })
                .frame(width: 880, height: 760),
            name: "history-empty-reasons", directory: directory)

        // MARK: Attempt-3 states: blocked burndown, failed polls, widget reads
        // A blocked window still reporting a percentage: no "out in", and its
        // figure is "reported remaining", not headroom.
        let blockedWeekly = (0..<6).map { i in
            QuotaHistoryStore.ReadingRecord(
                vendor: alpha.instanceID, barLabel: "WK", measuredAt: now.addingTimeInterval(-Double(6 - i) * 600),
                fraction: 0.91 + Double(i) * 0.01, isBlocked: true, confidence: .measured, urgency: .critical,
                resetsAt: goAlpha.row2?.resetsAt, windowLength: 7 * 86_400, elapsedOnly: false)
        }
        var blockedFirst = goAlpha
        blockedFirst.row1 = goAlpha.row2
        blockedFirst.row2 = nil
        var blockedBurndown = MetricDetailModalView(
            snapshot: blockedFirst, readingsLoader: { _, _ in blockedWeekly },
            eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        blockedBurndown.maxBody = 1_000
        try await save(blockedBurndown.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-blocked-burndown", directory: directory)

        // Claude's newest poll failed: the card says so and no pace card
        // compares the figure from before it.
        let failedLatest = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-failed-latest-\(UUID().uuidString).sqlite"))
        try await failedLatest.record([claude], now: now.addingTimeInterval(-1_200))
        try await failedLatest.record([QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.offline),
            resetsAt: nil, lastUpdated: now.addingTimeInterval(-60), auxiliaryInfo: nil)],
            now: now.addingTimeInterval(-60))
        let claudeOnly = HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: [])
        try await save(
            HistoryRootView(liveStore: failedLatest, sampleStore: failedLatest, subjectSource: { (claudeOnly, []) })
                .frame(width: 880, height: 900),
            name: "history-failed-latest", directory: directory)

        // Every poll in range failed: said as failed polls, not "no readings".
        let onlyFailed = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-only-failed-\(UUID().uuidString).sqlite"))
        try await onlyFailed.record([QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.offline),
            resetsAt: nil, lastUpdated: now.addingTimeInterval(-60), auxiliaryInfo: nil)],
            now: now.addingTimeInterval(-60))
        try await save(
            HistoryRootView(liveStore: onlyFailed, sampleStore: onlyFailed,
                            subjectSource: { (HistoryOverviewPresentation.subjects(
                                order: [.claude, .grok], hidden: [], workspaces: []), []) })
                .frame(width: 880, height: 760),
            name: "history-only-failed", directory: directory)

        // A blocked figure on an overview card wears the nosign glyph.
        let blockedCard = try #require(HistoryOverviewPresentation.overview(
            subjects: HistoryOverviewPresentation.subjects(order: [.opencode], hidden: [], workspaces: [alpha]),
            readings: blockedWeekly).cards.first)
        try await save(
            HistoryOverviewCardView(card: blockedCard, isSelected: false, onSelect: {})
                .padding(14).frame(width: 260).background(Theme.card),
            name: "history-card-blocked", directory: directory)

        // The widget's Chart layout when history reads fail: wholly, then for
        // one of two vendors.
        let widgetFixtures = [claude, goBeta].map { FixtureProvider(snapshot: $0) }
        for (name, failing) in [("widget-chart-read-failed", Set<VendorIdentifier>([.claude, .opencode])),
                                ("widget-chart-read-partial", Set<VendorIdentifier>([.opencode]))] {
            let widgetStore = QuotaStore(
                manager: QuotaManager(
                    providerFactory: { widgetFixtures },
                    displayPreferences: { ProviderDisplayPreferences(ordering: .automatic) }),
                vendorReadingsLoader: { [readings] vendor, _ in
                    failing.contains(vendor) ? nil : readings.filter { $0.vendor == vendor.rawValue }
                })
            await widgetStore.load()
            try await save(
                DesktopWidgetView(store: widgetStore, filters: WidgetFilters(layout: .chart))
                    .frame(width: 420, height: 320).background(Theme.surface),
                name: name, directory: directory)
        }

        // MARK: Attempt-4 states: provider-level failed polls, blocked readout
        // Measured polls, an offline poll stored under the provider's own
        // label, then recovery: every line breaks at the outage, and the
        // inspector opened during it has no current burndown.
        let outage = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("rework-outage-\(UUID().uuidString).sqlite"))
        let offlineClaude = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .unavailable(.offline),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        func claudeAt(_ week: Double, _ fiveHour: Double) -> QuotaSnapshot {
            var s = claude
            s.row1 = bar("WK", week, length: 7 * 86_400, resetsIn: 3.2 * 86_400)
            s.row2 = bar("5H", fiveHour, length: 5 * 3600, resetsIn: 2.5 * 3600)
            return s
        }
        for i in 0..<8 {
            try await outage.record([claudeAt(0.50 + Double(i) * 0.01, 0.20 + Double(i) * 0.03)],
                                    now: now.addingTimeInterval(-Double(16 - i) * 600))
        }
        try await outage.record([offlineClaude], now: now.addingTimeInterval(-7 * 600))
        let duringOutage = try await outage.fetchReadings(vendor: .claude)
        var failedPollInspector = MetricDetailModalView(
            snapshot: claude, readingsLoader: { _, _ in duringOutage },
            eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        failedPollInspector.maxBody = 1_000
        try await save(failedPollInspector.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-failed-poll", directory: directory)
        // MARK: Attempt-5 states: a snapshot a later failed poll superseded,
        // and outages inside one overview bucket.
        // The inspector opened on a snapshot fetched 15 minutes ago, with an
        // offline poll recorded 10 minutes ago: the summary says the last
        // poll failed and the windows say when they are from.
        let superseded = QuotaHistoryStore(
            databaseURL: directory.appendingPathComponent("rework-superseded-\(UUID().uuidString).sqlite"))
        var stale = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.42, displayDetails: nil), status: .measured(.none),
            resetsAt: claude.resetsAt, lastUpdated: now.addingTimeInterval(-900), auxiliaryInfo: nil,
            row1: bar("WK", 0.42, length: 7 * 86_400, resetsIn: 3.2 * 86_400),
            row2: bar("5H", 0.18, length: 5 * 3600, resetsIn: 2.5 * 3600))
        stale.cliSource = "Review fixture"
        for i in 0..<4 {
            try await superseded.record([stale], now: now.addingTimeInterval(-Double(4 - i) * 300 - 600))
        }
        try await superseded.record([offlineClaude], now: now.addingTimeInterval(-600))
        let supersededReadings = try await superseded.fetchReadings(vendor: .claude)
        #expect(MetricDetailPresentation(snapshot: stale, readings: supersededReadings, now: now)
            .summary.state == .lastPollFailed(at: Date(timeIntervalSince1970:
                now.addingTimeInterval(-600).timeIntervalSince1970.rounded(.down))))
        var supersededInspector = MetricDetailModalView(
            snapshot: stale, readingsLoader: { _, _ in supersededReadings },
            eventsLoader: { _, _, _, _, _ in [] }, onClose: {})
        supersededInspector.maxBody = 1_000
        try await save(supersededInspector.frame(width: 384, height: 1_000).background(Theme.surface),
                       name: "inspector-superseded-by-failed-poll", directory: directory)

        // A day of polls with two outages inside 12-minute buckets of the
        // 24-hour overview: two offline polls either side of a reading, then
        // a poll with no WK figure followed by a recovery. The thinned
        // sparkline breaks where the full read does.
        let bucketed = QuotaHistoryStore(
            databaseURL: directory.appendingPathComponent("rework-bucketed-\(UUID().uuidString).sqlite"))
        let bucket24 = HistoryOverviewPresentation.sampleBucketSeconds(
            range: .last24Hours, retention: await bucketed.retentionInterval)
        let start = (now.timeIntervalSince1970 / Double(bucket24)).rounded(.down) * Double(bucket24) - 20 * 3600
        var noWeekFigure = claude
        noWeekFigure.row1 = bar("WK", nil, length: 7 * 86_400, resetsIn: 3.2 * 86_400)
        for i in 0..<240 {
            let at = Date(timeIntervalSince1970: start + Double(i) * 300)
            let poll = i == 84 || i == 86 ? offlineClaude
                : i == 168 ? noWeekFigure
                : claudeAt(0.30 + Double(i) * 0.001, 0.2)
            try await bucketed.record([poll], now: at)
        }
        let bucketedFull = try await bucketed.fetchReadings(vendor: .claude)
        let bucketedSampled = try await bucketed.fetchSampledReadings(
            since: now.addingTimeInterval(-86_400), until: now, bucketSeconds: bucket24)
        let bucketedCards = HistoryOverviewPresentation.overview(
            subjects: HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: []),
            readings: bucketedSampled, bucketSeconds: bucket24).cards
        let fullCards = HistoryOverviewPresentation.overview(
            subjects: HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: []),
            readings: bucketedFull, bucketSeconds: bucket24).cards
        #expect(fullCards.first?.segments.count == 4)
        #expect(bucketedCards.first?.segments.count == 4)
        try await save(
            HStack(spacing: 10) {
                ForEach(bucketedCards) { HistoryOverviewCardView(card: $0, isSelected: false, onSelect: {}) }
            }
            .padding(14).frame(width: 320).background(Theme.card),
            name: "history-sparkline-outages-in-bucket", directory: directory)

        for i in 0..<6 {
            try await outage.record([claudeAt(0.60 + Double(i) * 0.01, 0.45 + Double(i) * 0.03)],
                                    now: now.addingTimeInterval(-Double(6 - i) * 600))
        }
        let acrossOutage = try await outage.fetchReadings(vendor: .claude)
        let outageSegments = HistoryPresentation.segments(from: HistoryPresentation.consumptionReadings(acrossOutage))
        #expect(outageSegments.filter { $0.barLabel == "WK" }.count == 2)
        try await save(
            QuotaTimelineChart(segments: outageSegments, timeRange: .last24Hours)
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            name: "history-chart-outage", directory: directory)

        // A blocked reading inspected on the chart: the readout wears the
        // nosign glyph beside "blocked", while the point keeps its square.
        let blockedSegments = HistoryPresentation.segments(from: blockedWeekly)
        try await save(
            QuotaTimelineChart(segments: blockedSegments, timeRange: .last24Hours)
                .inspecting(blockedWeekly[3].measuredAt)
                .padding(14).frame(width: 760, height: 300).background(Theme.card),
            name: "history-chart-blocked-readout", directory: directory)

        // MARK: Settings
        let workspacesKey = OpenCodeGoWorkspaceStore.defaultsKey
        let savedWorkspaces = CredentialStore.preferences.data(forKey: workspacesKey)
        let savedHidden = CredentialStore.preferences.object(forKey: CredentialStore.hiddenProvidersDefaultsKey)
        defer {
            if let savedWorkspaces {
                CredentialStore.preferences.set(savedWorkspaces, forKey: workspacesKey)
            } else {
                CredentialStore.preferences.removeObject(forKey: workspacesKey)
            }
            if let savedHidden {
                CredentialStore.preferences.set(savedHidden, forKey: CredentialStore.hiddenProvidersDefaultsKey)
            } else {
                CredentialStore.preferences.removeObject(forKey: CredentialStore.hiddenProvidersDefaultsKey)
            }
        }
        #expect(CredentialStore.preferences !== UserDefaults.standard)
        OpenCodeGoWorkspaceStore.set([beta, alpha])
        CredentialStore.hiddenProviders = [.kiro]
        for pane in [SettingsView.Pane.providers, .workspaces, .notifications, .display, .data] {
            try await save(
                SettingsView(store: store, initialPane: pane, readsCredentials: false),
                name: "settings-\(pane.rawValue)", directory: directory)
        }
        // The whole Display pane, so the popover, usage-details and
        // window-bar legends are all on one image.
        try await save(
            SettingsView(store: store, initialPane: .display, readsCredentials: false, height: 1900),
            name: "settings-display-full", directory: directory)
        _ = snapshots
    }

    /// Hosts `view` in a key window, delivers `keys` (virtual key code and
    /// characters) as real key-down events, then renders it.
    private func saveAfterKeys<V: View>(
        _ view: V, keys: [(UInt16, String)], name: String, directory: URL
    ) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
        try await Task.sleep(for: .milliseconds(300))
        for (code, characters) in keys {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: code == 124 ? [.numericPad, .function] : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        window.close()
    }

    private func save<V: View>(_ view: V, name: String, directory: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        window.close()
    }
}
