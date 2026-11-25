import SwiftUI
import AppKit
import QuotaBarCore

/// Inspector modal, in three layers: a summary to read at a glance; the
/// windows, a burndown or usage-history chart from recorded readings (hover a
/// point for the exact reading) and recent events to interrogate it with; and
/// the provenance of every figure.
///
/// Carried a "Test Quota Simulation" slider that wrote a made-up fraction into
/// the live snapshot — which then drove the advice engine and the menu bar
/// icon. A debug affordance that fabricates the one number this app exists to
/// report has no business shipping, so it is gone.
public struct MetricDetailModalView: View {

    let snapshot: QuotaSnapshot
    let readingsLoader: (VendorIdentifier, Date?) async -> [QuotaHistoryStore.ReadingRecord]?
    let eventsLoader: (VendorIdentifier, String?, Set<AIEventKind>?, Date?, Int?) async -> [AIEvent]?
    /// One balance series' recorded points over a window, thinned. nil when the
    /// history could not be read — a failure to read, not an absence.
    let balanceLoader: (String, Date, Date, Int) async -> [BalancePoint]?
    let onClose: () -> Void

    /// One balance series the snapshot publishes, with the outcome of its read:
    /// the points it answered with, or nil when the read failed.
    ///
    /// The series is listed whether or not the read answered. Gating the card
    /// on the *successful* reads alone left a failed read out of this list
    /// entirely, which hid the card and drew the failure as "this provider
    /// publishes no balance" — the one distinction this feature exists to make,
    /// with the card's own failure branch unreachable behind it.
    struct BalanceSeriesRead: Equatable {
        let series: BalanceSeries.Series
        /// nil when the read failed; `[]` is an answered read that held no
        /// readings in the window.
        let points: [BalancePoint]?
    }

    /// Which of the card's states applies.
    ///
    /// Pure, so the failure state can be asserted rather than only rendered:
    /// it shipped with no gate that could reach it.
    enum BalanceCardState: Equatable {
        case loading
        /// The pass has not recorded this series yet — a transient, and the
        /// only state a spinner is honest for.
        case awaitingRead
        /// The read failed: a failure to read, never an absence of readings.
        case readFailed
        case trend(BalanceSparklinePresentation, unit: BalanceSeries.Unit)
        case noTrend(readings: Int)

        static func of(isLoading: Bool, read: BalanceSeriesRead?) -> BalanceCardState {
            if isLoading { return .loading }
            guard let read else { return .awaitingRead }
            guard let points = read.points else { return .readFailed }
            guard let trend = BalanceSparklinePresentation.make(from: points) else {
                return .noTrend(readings: points.count)
            }
            return .trend(trend, unit: read.series.unit)
        }
    }

    /// Whether the card is drawn at all: the snapshot publishes at least one
    /// balance series. *Not* "did a read succeed" — a failed read is one of the
    /// card's own states, not a reason to hide the card.
    static func showsBalanceCard(for snapshot: QuotaSnapshot) -> Bool {
        !BalanceSeries.all(of: snapshot).isEmpty
    }

    /// Whether the quota chart card (burndown / usage history) is drawn.
    ///
    /// A balance-only provider (OpenRouter, DeepSeek) has no consumable window
    /// and records no usage fractions, so the card could only ever say "no
    /// burndown to draw" — and it did, at the top of the body, pushing the
    /// balance history the user opened the inspector for below the fold. The
    /// card stays whenever there is a window to chart, and whenever there is no
    /// balance card either, so an inspector never loses its only chart area.
    static func showsQuotaChart(for snapshot: QuotaSnapshot) -> Bool {
        !snapshot.quotaBars.isEmpty || !showsBalanceCard(for: snapshot)
    }

    /// The per-series reads one pass records: one entry per series the snapshot
    /// publishes, each carrying its read's own outcome.
    ///
    /// A failed read is *kept*, with `points` nil. Dropping it — which is what
    /// shipped — left the card with no series to draw when every read failed, so
    /// a failure to read rendered as "this provider publishes no balance" and
    /// the card's own failure branch could never be reached. Extracted from
    /// `load` so a revert of either half can be shown to fail a test: the
    /// card's gate alone cannot catch it, because one guard masks the other.
    ///
    /// Records nothing once the surrounding task is cancelled: a non-throwing
    /// `await` does not stop on cancellation, so a modal dismissed mid-pass
    /// would otherwise run every remaining series' read to completion and
    /// discard the lot.
    static func balanceReads(
        for snapshot: QuotaSnapshot,
        load: (BalanceSeries.Series) async -> [BalancePoint]?
    ) async -> [BalanceSeriesRead] {
        var reads: [BalanceSeriesRead] = []
        for series in BalanceSeries.all(of: snapshot) {
            if Task.isCancelled { return [] }
            reads.append(BalanceSeriesRead(series: series, points: await load(series)))
        }
        return reads
    }

    @State private var copied = false
    @State private var chartMode: ChartMode = .burndown
    @State private var historyRange: HistoryPresentation.TimeRange = .last24Hours
    @State private var selectedBarLabel: String?
    @State private var readings: [QuotaHistoryStore.ReadingRecord] = []
    @State private var recentEvents: [AIEvent] = []
    @State private var markerEvents: [AIEvent] = []
    /// One entry per balance series the snapshot publishes, each with its read's
    /// outcome. Empty only before the first pass has recorded one.
    @State private var balanceSeries: [BalanceSeriesRead] = []
    @State private var selectedBalanceID: String?
    @State private var isLoading = true
    @State private var loadedSnapshotID: String?
    /// The readings or events could not be read. Each is then said as a
    /// failure to read, never as "no readings" or "no events".
    @State private var readingsFailed = false
    @State private var eventsFailed = false
    /// The chart-marker read failed: resets may be missing from the chart.
    /// Tracked apart from `eventsFailed`, whose query is a different one.
    @State private var markersFailed = false
    /// Where the readings read started, for the provenance's history count.
    @State private var historySince: Date?
    /// Fixed when the data loads, so every derived figure on screen agrees
    /// on one instant instead of each calling `Date()`.
    @State private var now = Date()
    @State private var bodyHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 70
    /// No footer: Copy JSON sits in the header and the close button is there.
    @State private var footerHeight: CGFloat = 0

    enum ChartMode: String, CaseIterable, Identifiable {
        case burndown = "Burndown"
        case history = "History"
        var id: String { rawValue }
    }

    /// The ranges the inspector offers; "All" belongs to the History window.
    static let historyRanges: [HistoryPresentation.TimeRange] = [.last24Hours, .last7Days, .last30Days]
    /// How far back the inspector reads, covering the longest offered range.
    static let historyLookback: TimeInterval = 30 * 86_400
    /// The balance read's bucket width: a day, so a month is about 30 points.
    static let balanceBucketSeconds = 86_400
    static let chartHeight: CGFloat = 150
    /// Keeps the whole modal near 600pt: header and footer sit outside this.
    static let maxBodyHeight: CGFloat = 480

    /// - Parameters:
    ///   - readingsLoader: one vendor's recorded readings since a date; nil
    ///     when the history could not be read.
    ///   - eventsLoader: one vendor's and instance's recorded events of the
    ///     given kinds (nil: every kind) since a date, newest first, at most
    ///     `limit`; nil when they could not be read. The instance keeps a
    ///     sibling workspace's events out; the vendor's own still come through.
    ///   - balanceLoader: one balance series' recorded points over a window,
    ///     thinned to the given bucket width; nil when the history could not be
    ///     read. Defaults to a loader that reports a failed read, so a caller
    ///     that does not wire it draws the failure state rather than a chart
    ///     built from nothing — a test that means to exercise the balance card
    ///     must inject this and assert it was hit.
    ///
    /// All run once per vendor when the modal appears, never on the refresh
    /// path.
    public init(
        snapshot: QuotaSnapshot,
        readingsLoader: @escaping (VendorIdentifier, Date?) async -> [QuotaHistoryStore.ReadingRecord]?,
        eventsLoader: @escaping (VendorIdentifier, String?, Set<AIEventKind>?, Date?, Int?) async -> [AIEvent]?,
        balanceLoader: @escaping (String, Date, Date, Int) async -> [BalancePoint]? = { _, _, _, _ in nil },
        focusBalanceSeriesID: String? = nil,
        onClose: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.readingsLoader = readingsLoader
        self.eventsLoader = eventsLoader
        self.balanceLoader = balanceLoader
        self.focusBalanceSeriesID = focusBalanceSeriesID
        self.onClose = onClose
    }

    /// The balance series of the Wallet line this was opened from, if any:
    /// its card comes first and shows that series, so ChatGPT API and ChatGPT
    /// bonus do not open the same view with the other figure selected.
    let focusBalanceSeriesID: String?

    private var accentColor: Color {
        Color(hexString: snapshot.vendorId.accentColorHex) ?? Theme.primary
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Semi-transparent backdrop
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                // Modal card
                VStack(spacing: 0) {
                    header
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    ScrollView(.vertical) {
                        content
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                bodyHeight = $0
                            }
                    }
                    .frame(height: Self.scrollHeight(contentHeight: bodyHeight,
                        availableHeight: geometry.size.height, headerHeight: headerHeight, footerHeight: footerHeight,
                        maxBody: maxBody))
                    .scrollBounceBehavior(.basedOnSize)
                    // More below the fold says so: a visible scroller and a
                    // fade at the bottom edge, so a chart cut by the edge does
                    // not read as the whole of it.
                    .scrollIndicators(.visible)
                    .overlay(alignment: .bottom) {
                        if bodyHeight > Self.scrollHeight(contentHeight: bodyHeight,
                            availableHeight: geometry.size.height, headerHeight: headerHeight,
                            footerHeight: footerHeight, maxBody: maxBody) + 1 {
                            LinearGradient(colors: [Theme.card.opacity(0), Theme.card],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 22)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(width: 348)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Theme.cardRimTop, Theme.outlineVariant.opacity(0.35)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: Color.black.opacity(0.62), radius: 22, x: 0, y: 12)
                .padding(Theme.edgeMargin)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Re-read whenever the poll behind the snapshot changes, not only when
        // another pool is opened: the popover passes the store's current copy
        // (`PopoverRootView`), and a pass that fails, blocks or spends this
        // pool must not leave the open inspector describing the earlier poll.
        .task(id: Self.loadKey(for: snapshot)) { await load() }
        // The presentation is a function of the time as well as the poll: a
        // reset that passes while the inspector is open must turn its verdict
        // into "awaiting a reading" and drop its forecast on the same tick
        // the popover and menu bar call it "due", not at the next poll.
        .task { await followGlanceClock() }
        .onExitCommand(perform: onClose)
    }

    static func scrollHeight(contentHeight: CGFloat, availableHeight: CGFloat,
                             headerHeight: CGFloat, footerHeight: CGFloat,
                             maxBody: CGFloat = maxBodyHeight) -> CGFloat {
        min(contentHeight > 0 ? contentHeight : maxBody, maxBody,
            max(0, availableHeight - headerHeight - footerHeight - 2 * Theme.edgeMargin))
    }

    /// The body's height cap. Only the render harness raises it, to draw
    /// every layer in one image instead of the first screenful.
    var maxBody: CGFloat = maxBodyHeight

    nonisolated static func balanceSelection(keeping current: String?, in ids: [String]) -> String? {
        if let current, ids.contains(current) { return current }
        return ids.first
    }

    /// Which poll the inspector is showing: the pool, when it was fetched,
    /// and whether (and when) a later poll failed.
    private func followGlanceClock() async {
        while !Task.isCancelled {
            let tick = GlanceClock.nextTick(after: Date())
            let wait = max(tick.timeIntervalSinceNow, 0.01)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { return }
            // A late wake describes the newest boundary passed, as the Story does.
            now = Self.displayTime(current: now, tick: GlanceClock.reportedTick(scheduled: tick, woke: Date()))
        }
    }

    /// The inspector's clock never runs backwards: a load that finished
    /// after the tick already set a later time.
    nonisolated static func displayTime(current: Date, tick: Date) -> Date {
        GlanceClock.displayTime(current: current, tick: tick)
    }

    nonisolated static func loadKey(for snapshot: QuotaSnapshot) -> String {
        "\(snapshot.id)|\(snapshot.lastUpdated.timeIntervalSince1970)|\(snapshot.staleReading?.at.timeIntervalSince1970 ?? 0)"
    }

    private func load() async {
        // A refresh of the same pool keeps the drawn history until the new
        // read lands; only opening another pool starts from the loading state.
        if loadedSnapshotID != snapshot.id { isLoading = true }
        defer { loadedSnapshotID = snapshot.id }
        let vendor = snapshot.vendorId
        let loadTime = Date()
        // Far enough back for the longest offered range and for the start
        // of the longest window the vendor published.
        var since = loadTime.addingTimeInterval(-Self.historyLookback)
        for bar in snapshot.quotaBars {
            if let reset = bar.resetsAt, let length = bar.windowLength {
                since = min(since, reset.addingTimeInterval(-length))
            }
        }
        let r = await readingsLoader(vendor, since)
        // Every balance series this snapshot carries: its own money figure and
        // one per prepaid credit entry. Read for the same lookback as the
        // readings, bucketed a day wide so a month is ~30 points. One entry per
        // series, each with its read's own outcome — a failed read is kept as
        // that series' outcome rather than used to skip the series.
        let reads = await Self.balanceReads(for: snapshot) { series in
            await balanceLoader(
                series.id, loadTime.addingTimeInterval(-Self.historyLookback), loadTime,
                Self.balanceBucketSeconds)
        }
        // Filtered by kind in the query, so the five slots are never spent
        // on scheduled rollovers (the store already drops retired rows).
        // Scoped to this instance, so a sibling workspace's resets and
        // restores never appear here — on the chart as a marker or in the
        // recent-events card. The vendor's own events (no instance) still do.
        let e = await eventsLoader(vendor, snapshot.id, QuotaStore.recentEventKinds, nil, 5)
        let m = await eventsLoader(
            vendor, snapshot.id, nil, loadTime.addingTimeInterval(-Self.historyLookback), nil)
        guard !Task.isCancelled else { return }
        let agyAliases: [String] = if let account = snapshot.antigravityAccount,
                                      let allowance = AntigravityAccount.allowance(for: snapshot.vendorId) {
            account.poolHistoryAliases(for: allowance)
        } else {
            []
        }
        readings = (r ?? []).map { record in
            (snapshot.claudeAccount?.historyAliases.contains(record.vendor) == true
                || agyAliases.contains(record.vendor))
                ? record.namingInstance(snapshot.id) : record
        }
        readingsFailed = r == nil
        balanceSeries = reads
        // Keep the chosen series only while this poll still publishes it: a
        // reload that drops it left the card on "Loading balance history"
        // with no picker to choose another.
        selectedBalanceID = Self.balanceSelection(keeping: selectedBalanceID ?? focusBalanceSeriesID,
                                                  in: reads.map(\.series.id))
        historySince = since
        recentEvents = e ?? []
        eventsFailed = e == nil
        markerEvents = m ?? []
        markersFailed = m == nil
        // The load awaited four reads; a clock tick may have moved the time
        // past `loadTime` meanwhile, and restoring the earlier instant put a
        // window the popover already called "due" back on its forecast.
        now = Self.displayTime(current: now, tick: loadTime)
        isLoading = false
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VendorAvatarView(
                vendorId: snapshot.vendorId,
                status: snapshot.status,
                // The summary's verdict, so the avatar and the headline beside
                // it cannot disagree (a spent bonus pool, an account block).
                isExhausted: [.exhausted, .blocked].contains(presentation.summary.state)
            )

            // The name and its badge claim the row's width before the close
            // button, so the name keeps its own line instead of breaking
            // mid-word. A flexible `Spacer` here used to win a share of the row
            // and leave the name less than its ideal width, which broke
            // "OpenRouter" across two lines beside a two-word badge — "$179.50
            // credit", "$12.34 key cap left" and "Payment required" are all real
            // badges, so it was every one of them. The name stays wrappable,
            // because "OpenCode Go · Gamma workspace" is wider than the row and
            // must still take two lines.
            // Which pool this is, named as the popover names it: the pool and
            // account first, then its service and plan. The badge and the
            // category ("AI Subscriptions") repeated the verdict below or
            // said nothing.
            VStack(alignment: .leading, spacing: 2) {
                Text(headerNames.name)
                    .font(Theme.Typography.title)
                    .tracking(Theme.Tracking.title)
                    .foregroundStyle(Theme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headerSubtitle)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                    // Plan names arrive verbatim from vendors; wrap, never clip.
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The column takes the row's remaining width, so the close button is
            // pinned right and the name is not starved by a flexible `Spacer`
            // competing with it for space.
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: copyJson) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? Theme.secondary : Theme.onSurfaceVariant)
                    .padding(7)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copied details as JSON" : "Copy details as JSON")
            .help("Copy these details as JSON")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .padding(7)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(headerNames.name) details")
            .help("Close details (Esc)")
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 12)
        .background(Theme.surfaceContainerHigh)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.outlineVariant.opacity(0.5)).frame(height: 0.5)
        }
    }

    private var headerNames: (service: String, name: String) {
        GlancePresentation.names(for: snapshot)
    }

    /// "Antigravity · Google AI Pro", "Claude Code · Max (20x)".
    private var headerSubtitle: String {
        let plan = snapshot.claudeAccount != nil ? (snapshot.planName ?? "") : snapshot.shortPlanName
        return ([headerNames.service == headerNames.name ? snapshot.category.rawValue : headerNames.service]
                + [plan.isEmpty ? nil : plan].compactMap { $0 }).joined(separator: " · ")
    }

    // MARK: - Content

    /// Layered so the answer comes first: the summary a glance needs, then
    /// the windows, chart and events to interrogate it with, then where the
    /// figures came from.
    private var content: some View {
        let balanceFirst = focusBalanceSeriesID != nil && Self.showsBalanceCard(for: snapshot)
        return VStack(spacing: 12) {
            summaryCard
            // Opened from a Wallet line: that line's figure comes first.
            if balanceFirst {
                balanceCard
            }
            if !presentation.windows.isEmpty {
                windowsCard
            }
            if Self.showsQuotaChart(for: snapshot) {
                chartCard
            }
            if Self.showsBalanceCard(for: snapshot) && !balanceFirst {
                balanceCard
            }
            recentEventsCard
            provenanceCard
        }
        .padding(Theme.cardPadding)
    }

    private var presentation: MetricDetailPresentation {
        MetricDetailPresentation(
            snapshot: snapshot,
            history: recordedHistory,
            readings: isLoading || readingsFailed ? nil : readings,
            now: now)
    }

    /// One scoped count for the provenance row and Copy JSON alike.
    private var recordedHistory: MetricDetailPresentation.RecordedHistory {
        isLoading ? .loading : .of(
            readings: readingsFailed ? nil : readings, instanceID: snapshot.id, since: historySince ?? now)
    }

    /// True when the snapshot's raw quota band is still `.healthy` yet the
    /// forecast says it runs out: before the reset, any moment now, or with
    /// no reset published to save it (`RunOutVerdict.warns`). Forecasts that
    /// say "lasts until the reset" never trigger this warning.
    private var forecastWarnsEarlyRunOut: Bool {
        presentation.summary.state == .healthy && runOutResult?.warns == true
    }

    private var summaryColor: Color {
        forecastWarnsEarlyRunOut ? Theme.tertiary : Self.color(for: presentation.summary.state)
    }

    /// Headline text color on the tinted summary card. Exhausted/blocked cards
    /// tint with `Theme.errorBold`, so their 14.5pt headline uses `Theme.error`
    /// (#FFB4AB, > 9:1 on the tinted card) to clear WCAG small-text AA (>= 4.5:1).
    private var summaryHeadlineColor: Color {
        Self.headlineColor(for: presentation.summary.state, warnsEarlyRunOut: forecastWarnsEarlyRunOut)
    }

    nonisolated static func headlineColor(
        for state: MetricDetailPresentation.State,
        warnsEarlyRunOut: Bool
    ) -> Color {
        if warnsEarlyRunOut { return Theme.tertiary }
        switch state {
        case .exhausted, .blocked: return Theme.error
        default: return Self.color(for: state)
        }
    }

    private var summaryHeadline: String {
        forecastWarnsEarlyRunOut ? "On track to run out" : presentation.summary.headline
    }

    private var summarySymbol: String {
        forecastWarnsEarlyRunOut ? "exclamationmark.triangle.fill" : presentation.summary.symbol
    }

    nonisolated static func summaryAccessibilityLabel(
        summary: MetricDetailPresentation.Summary,
        warnsEarlyRunOut: Bool,
        isAheadOfPace: Bool,
        runOutText: String?,
        historyNote: String? = nil
    ) -> String {
        let base: String
        if warnsEarlyRunOut {
            let needle = ", \(summary.headline)"
            if let range = summary.accessibilityLabel.range(of: needle) {
                base = summary.accessibilityLabel.replacingCharacters(in: range, with: ", On track to run out")
            } else {
                base = "On track to run out, \(summary.accessibilityLabel)"
            }
        } else {
            base = summary.accessibilityLabel
        }
        var parts = [base]
        if isAheadOfPace, !base.localizedCaseInsensitiveContains("ahead of even pace") {
            parts.append("Ahead of even pace")
        }
        if let runOutText {
            parts.append(runOutText)
        }
        if let historyNote {
            parts.append(historyNote)
        }
        return parts.joined(separator: ". ")
    }

    /// The headline is a verdict on the figure this poll read, not on the
    /// recorded history below it. When that history could not be read, the
    /// summary says so beside the verdict, so "Healthy" above "Could not read
    /// the recorded balance" is not taken as a verdict on the chart.
    nonisolated static func historyScopeNote(isLoading: Bool, reads: [BalanceSeriesRead]) -> String? {
        guard !isLoading, reads.contains(where: { $0.points == nil }) else { return nil }
        return "Verdict from the latest poll · recorded balance history could not be read"
    }

    /// Read by Settings' legend as well, so its swatches are the inspector's.
    nonisolated static func color(for state: MetricDetailPresentation.State) -> Color {
        switch state {
        case .unavailable, .lastPollFailed: Theme.outline
        // Not a verdict on the quota: amber says "not confirmed", never green.
        case .awaitingReading: Theme.tertiary
        case .healthy: Theme.secondary
        case .runningLow: Theme.tertiary
        case .critical: Theme.error
        case .exhausted, .blocked: Theme.errorBold
        }
    }

    // MARK: Summary

    /// The glance: state in words and shape, the most pressing window's share
    /// used, when it resets, and a pace verdict only where the bar draws a
    /// pace tick.
    private var summaryCard: some View {
        let summary = presentation.summary
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: summarySymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(summaryColor)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(summaryHeadline)
                        .font(Theme.Typography.cardBody.weight(.semibold))
                        .foregroundStyle(summaryHeadlineColor)
                    Spacer(minLength: 4)
                    if let focus = focusWindow, let used = focus.used, let label = summary.focusLabel {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            // A blocked window's figure is not headroom: the
                            // glyph sits beside it here as on every bar.
                            if summary.focusIsBlocked {
                                BlockedGlyph(color: summaryColor, size: 14)
                            }
                            // "% used", formatted as the popover's bars print
                            // it, so the summary, the window lines and the
                            // burndown caption never round one reading apart.
                            Text(GlancePresentation.usedPercentText(used))
                                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.onSurface)
                            Text("\(label) used")
                                .font(Theme.Typography.subtitle)
                                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                        }
                        // The headline wraps instead; a figure split across
                        // lines ("97" over "%") cannot be read at a glance.
                        .fixedSize()
                    } else if let figure = summary.figure {
                        Text(figure)
                            .font(Theme.Typography.numeric)
                            .foregroundStyle(Theme.onSurface)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }

                if let reset = summary.resetText {
                    Label(reset, systemImage: "clock")
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(Theme.onSurfaceVariant)
                }
                if focusWindow?.isAheadOfPace == true {
                    Label("Ahead of even pace", systemImage: "arrowtriangle.up.fill")
                        .font(Theme.Typography.subtitle.weight(.semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                if let runOut = runOutText {
                    Label(runOut, systemImage: "hourglass")
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(Theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let remedy = summary.remedy {
                    Text(remedy)
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(Theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = Self.historyScopeNote(isLoading: isLoading, reads: balanceSeries) {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(Theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(summaryColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(summaryColor.opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summaryAccessibilityLabel(
            summary: summary,
            warnsEarlyRunOut: forecastWarnsEarlyRunOut,
            isAheadOfPace: focusWindow?.isAheadOfPace == true,
            runOutText: runOutText,
            historyNote: Self.historyScopeNote(isLoading: isLoading, reads: balanceSeries)
        ))
    }

    /// The verdict's window, read the way the popover reads it.
    private var focusWindow: GlancePresentation.Window? {
        guard let label = presentation.summary.focusLabel,
              let bar = snapshot.quotaBars.first(where: { $0.label == label }) else { return nil }
        return GlancePresentation.window(for: snapshot.applyingAccountBlock(to: bar), now: now)
    }

    private var runOutResult: InspectorRunOut.Result? {
        // No forecast while the pool awaits a reading: its figures describe
        // a window that has ended.
        if case .awaitingReading = presentation.summary.state { return nil }
        guard let label = presentation.summary.focusLabel,
              let bar = snapshot.quotaBars.first(where: { $0.label == label }) else { return nil }
        return InspectorRunOut.compute(for: bar, in: snapshot,
                                       readings: isLoading || readingsFailed ? nil : readings, now: now)
    }

    private var runOutText: String? { runOutResult?.text }

    // MARK: Windows

    /// Every window the vendor published, one line each, in the vendor's own
    /// order (longest first). The same bar as the popover — one fill, one pace
    /// tick — so the two can never disagree.
    private var windowsCard: some View {
        let asOf = presentation.windowsAsOf
        return VStack(alignment: .leading, spacing: 8) {
            // Superseded figures say when they are from, and are dimmed, so
            // they do not read as the provider's state now.
            sectionTitle(asOf.map {
                "Windows at \(MetricDetailPresentation.clockText($0, now: now)), before the failed poll"
            } ?? "Windows")
            ForEach(presentation.windows) { line in
                let window = GlancePresentation.window(for: line.metrics, now: now)
                let leftText: String? = line.metrics.measuresElapsedTimeOnly
                    ? line.percentText.map { "\($0) elapsed" }
                    : window.used.map { "\(GlancePresentation.usedPercentText($0)) used" }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(line.label)
                            .font(Theme.Typography.token)
                            .tracking(Theme.Tracking.token)
                            .foregroundStyle(Theme.onSurfaceVariant)
                            .frame(width: 44, alignment: .leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        // "% used", the popover's bar: fill is what was used,
                        // the tick where an even pace would be. A billing
                        // cycle keeps its elapsed-time bar.
                        // Carried-over figures: the bar recedes, the words
                        // and the pace tick do not. Dimming the whole line took
                        // its reset caption to 3.0:1 (design-loop sol-15); the
                        // title above already says these predate the failed poll.
                        if line.metrics.measuresElapsedTimeOnly {
                            DualBarProgressView(metrics: line.metrics, showsLabel: false)
                                .opacity(asOf == nil ? 1 : UsageBar.dimmedOpacity)
                        } else {
                            UsageBar(window: window, height: 6, dimmed: asOf != nil)
                        }
                        HStack(spacing: 3) {
                            // The nosign means "the vendor blocked this", as in
                            // the popover; a window the user used up says "spent".
                            if line.metrics.isBlocked {
                                BlockedGlyph(color: Theme.errorBold)
                            }
                            Text(window.isSpent && !line.metrics.isBlocked ? "spent"
                                 : (leftText ?? line.noFigureText ?? ""))
                                .font(Theme.Typography.gridPercent)
                                .foregroundStyle(leftText == nil ? Theme.outline
                                                 : (window.isSpent ? Theme.errorBold : GlanceColors.text(for: window)))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(minWidth: 62, alignment: .trailing)
                    }
                    if !line.detail.isEmpty || window.isAheadOfPace {
                        HStack(spacing: 6) {
                            if !line.detail.isEmpty { Text(line.detail) }
                            if window.isAheadOfPace {
                                Label("ahead of pace", systemImage: "arrowtriangle.up.fill")
                                    .foregroundStyle(Theme.tertiary)
                            }
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                        .padding(.leading, 52)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(windowSpoken(line: line, left: leftText, window: window, asOf: asOf))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceContainerLowest.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    /// Spoken in the unit drawn: "% used", or elapsed for a billing cycle.
    private func windowSpoken(line: MetricDetailPresentation.WindowLine, left: String?,
                              window: GlancePresentation.Window, asOf: Date?) -> String {
        let name = WindowColumn.column(forLabel: line.label)?.spokenName ?? line.label
        var parts = ["\(name) window"]
        // A blocked window keeps the percentage it reported in speech, as the
        // row prints it ("blocked, 97 percent used reported").
        if window.isSpent {
            parts.append(line.metrics.isBlocked ? "blocked" : "spent")
            if line.metrics.isBlocked, let left {
                parts.append("\(left.replacingOccurrences(of: "%", with: " percent")) reported")
            }
        }
        else if let left { parts.append(left.replacingOccurrences(of: "%", with: " percent")) }
        else if let noFigure = line.noFigureText { parts.append(noFigure.lowercased()) }
        if !line.detail.isEmpty { parts.append(line.detail) }
        if window.isAheadOfPace { parts.append("ahead of pace") }
        if let asOf { parts.append("as of \(MetricDetailPresentation.clockText(asOf, now: now))") }
        return parts.joined(separator: ", ")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.subtitle.weight(.semibold))
            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Chart card

    /// Consumable windows, longest first — the burndown's choices.
    private var burndownLabels: [String] {
        snapshot.quotaBars.map(\.label)
    }

    private var activeBurndownLabel: String? {
        if let selectedBarLabel, burndownLabels.contains(selectedBarLabel) { return selectedBarLabel }
        return burndownLabels.first
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                GlanceSegmentedControl(
                    options: ChartMode.allCases,
                    selection: $chartMode,
                    title: \.rawValue,
                    accessibilityLabel: "Chart type"
                )

                Spacer(minLength: 0)

                switch chartMode {
                case .burndown:
                    if burndownLabels.count > 1, let active = activeBurndownLabel {
                        Picker("Window", selection: Binding(
                            get: { active },
                            set: { selectedBarLabel = $0 }
                        )) {
                            ForEach(burndownLabels, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Burndown window")
                    }
                case .history:
                    GlanceSegmentedControl(
                        options: Self.historyRanges,
                        selection: $historyRange,
                        title: \.rawValue,
                        accessibilityLabel: "History range"
                    )
                }
            }

            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Loading readings")
                } else if readingsFailed {
                    ChartEmptyState(
                        symbol: "exclamationmark.triangle",
                        message: "Could not read the recorded history. This is a failure to read, not an absence of readings."
                    )
                } else {
                    switch chartMode {
                    case .burndown: burndownContent
                    case .history: historyContent
                    }
                }
            }
            .frame(height: Self.chartHeight)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceContainerLowest.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var burndownContent: some View {
        if let label = activeBurndownLabel,
           let burndown = BurndownPresentation.burndown(
               readings: readings, instanceID: snapshot.id, barLabel: label, now: now
           )?.current(for: snapshot, now: now) {
            // Room above the plot: its "now" annotation sits at the top edge
            // and overprinted the caption.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if burndown.isBlocked {
                        BlockedGlyph(color: Theme.onSurfaceVariant, size: 10)
                    }
                    // The caption wraps rather than cutting its last clause,
                    // which is the run-out warning whenever there is one
                    // ("58% used · resets in 5d · at recent rate, out in 41h"
                    // is 293pt in a 234pt column).
                    // The chart reads the recorded series, which can trail the
                    // live poll by a reading; its figure says when it is from,
                    // so "63%" under a live "62%" reads as history, not conflict.
                    Text((burndown.latestReading.map {
                        "Recorded \(MetricDetailPresentation.clockText($0.measuredAt, now: now)) · "
                    } ?? "") + BurndownPresentation.summaryLine(for: burndown, now: now))
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(Theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text("Axis: % left")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.outline)
                        .fixedSize()
                }
                .accessibilityHidden(true)
                // The key comes before the plot it explains: below it, "Even
                // pace" fell under the first viewport while the lines it names
                // were on screen.
                if burndown.ideal == nil && burndown.projection == nil {
                    Text("No window length published, so no pace line can be drawn")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.outline)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    burndownLegend(for: burndown)
                }
                BurndownChartView(burndown: burndown, now: now)
                    .padding(.top, 2)
            }
        } else if let label = activeBurndownLabel {
            let absence = BurndownPresentation.burndownAbsence(
                readings: readings, instanceID: snapshot.id, barLabel: label, now: now)
            ChartEmptyState(
                symbol: absence.symbol ?? "chart.line.downtrend.xyaxis",
                message: absence.message
            )
        } else {
            ChartEmptyState(
                symbol: "chart.line.downtrend.xyaxis",
                message: "No consumable window, so there is no burndown to draw"
            )
        }
    }

    private func burndownLegend(for burndown: BurndownPresentation.Burndown) -> some View {
        HStack(spacing: 12) {
            if burndown.ideal != nil {
                HStack(spacing: 5) {
                    legendDashSwatch(color: Theme.outline.opacity(0.85), dash: [4, 2.5], lineWidth: 1.25)
                    Text("Even pace")
                }
            }
            if burndown.projection != nil {
                HStack(spacing: 5) {
                    legendDashSwatch(
                        color: burndown.runOutVerdict(now: now).warns ? Theme.error : Theme.tertiary,
                        dash: [1.5, 2.5],
                        lineWidth: 1.5
                    )
                    Text("Recent pace")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(Theme.outline)
        .accessibilityHidden(true)
    }

    private func legendDashSwatch(color: Color, dash: [CGFloat], lineWidth: CGFloat) -> some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, dash: dash))
        }
        .frame(width: 14, height: 6)
    }

    /// High-contrast dark-mode segmented control replacing macOS's native
    /// segmented picker (whose selected capsule measured ~2.3:1 on dark cards).
    /// Selected pill (`Theme.primary`) clears > 11:1 against the well
    /// (`Theme.surfaceContainerLowest`), and both selected and unselected text
    /// clear > 11:1 against their backgrounds.
    private struct GlanceSegmentedControl<Option: Hashable & Identifiable>: View {
        let options: [Option]
        @Binding var selection: Option
        let title: (Option) -> String
        let accessibilityLabel: String

        var body: some View {
            HStack(spacing: 2) {
                ForEach(options) { option in
                    let isSelected = selection == option
                    Button {
                        selection = option
                    } label: {
                        Text(title(option))
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Theme.surfaceContainerLowest : Theme.onSurfaceVariant)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? Theme.primary : Color.clear)
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title(option))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.surfaceContainerLowest)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.outlineVariant.opacity(0.6), lineWidth: 0.75)
            )
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        let series = BurndownPresentation.history(
            readings: readings, instanceID: snapshot.id, range: historyRange, now: now
        )
        if series.isEmpty {
            let absence = BurndownPresentation.historyAbsence(
                readings: readings, instanceID: snapshot.id, range: historyRange, now: now)
            ChartEmptyState(
                symbol: absence.symbol ?? "chart.line.uptrend.xyaxis",
                message: absence.message
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // The qualification comes before the plot it qualifies: below
                // it, the warning sat under the fold while the whole chart
                // read as complete.
                if markersFailed {
                    Label("Reset markers could not be read, so resets may be missing from this chart.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                UsageHistoryChartView(
                    series: series,
                    range: historyRange,
                    markers: EventsPresentation.markerEvents(
                        markerEvents, vendor: snapshot.vendorId, range: historyRange, now: now
                    ),
                    now: now
                )
            }
        }
    }

    // MARK: - Balance card

    /// The recorded balance the popover's inline strip only gestures at: the
    /// same readings over a month, one series at a time.
    ///
    /// Drawn for every snapshot that *publishes* a balance series — a quota-only
    /// provider has no line to show, and an empty chart would read as "your
    /// balance is zero" rather than "this provider has no balance". A snapshot
    /// that publishes a series but whose read failed draws the failure instead:
    /// the two are different answers and the card says which it is.
    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle("Balance history")
                Spacer(minLength: 0)
                if balanceSeries.count > 1 {
                    Picker("Balance series", selection: selectedBalanceBinding) {
                        ForEach(balanceSeries, id: \.series.id) { entry in
                            Text(entry.series.label).tag(entry.series.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Balance series")
                }
            }
            Group {
                switch BalanceCardState.of(isLoading: isLoading, read: currentBalance) {
                case .loading, .awaitingRead:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Loading balance history")
                case .readFailed:
                    ChartEmptyState(
                        symbol: "exclamationmark.triangle",
                        message: "Could not read the recorded balance. This is a failure to read, not an absence of readings. It is read again with the next poll, or when you reopen these details."
                    )
                case .trend(let trend, let unit):
                    VStack(alignment: .leading, spacing: 4) {
                        // The span and the newest reading's time, so a fall
                        // over two days does not read like one over twelve,
                        // and the last point is not mistaken for the live figure.
                        Text("\(trend.caption(in: unit)) \(trend.spanDescription) · "
                             + "last recorded \(MetricDetailPresentation.clockText(trend.lastMeasuredAt, now: now))")
                            .font(Theme.Typography.subtitle)
                            .foregroundStyle(Theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                        BalanceChartView(presentation: trend) { value in
                            unit.format(value)
                        }
                    }
                case .noTrend(let readings):
                    ChartEmptyState(
                        symbol: "chart.line.flattrend.xyaxis",
                        message: balanceAbsenceMessage(readings: readings)
                    )
                }
            }
            .frame(height: Self.chartHeight)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceContainerLowest.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var selectedBalanceBinding: Binding<String> {
        Binding(
            get: { selectedBalanceID ?? balanceSeries.first?.series.id ?? "" },
            set: { selectedBalanceID = $0 }
        )
    }

    /// The series the card is drawing, with its read's outcome. A series whose
    /// read failed is still selectable: its failure is what the card says.
    private var currentBalance: BalanceSeriesRead? {
        balanceSeries.first { $0.series.id == (selectedBalanceID ?? balanceSeries.first?.series.id) }
    }

    /// Why no trend can be drawn — an absence of readings, said as itself
    /// rather than as a zero balance.
    private func balanceAbsenceMessage(readings: Int) -> String {
        readings == 0
            ? "No balance recorded in the last 30 days yet."
            : "Only one balance reading recorded so far, so there is no trend to draw yet."
    }

    /// A figure in the series' own unit — money through the one money rule, a
    /// credit count kept as a count. Delegates to the unit's own `format`, so
    /// the chart's readout, its axis ends and the caption cannot word the same
    /// number three ways.
    private func format(_ value: Decimal, in unit: BalanceSeries.Unit) -> String {
        unit.format(value)
    }

    // MARK: - Recent events

    /// This instance's resets, outages and new models. Said when there are
    /// none, so an empty card is not mistaken for one that failed to load.
    private var recentEventsCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Recent events")
            if isLoading {
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.outline)
            } else if eventsFailed {
                Label("Could not read recorded events for this provider.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.outline)
                    .fixedSize(horizontal: false, vertical: true)
            } else if recentEvents.isEmpty {
                Text("No resets, outages or new models recorded for this provider.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.outline)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recentEvents) { event in
                    EventRowView(event: event, now: now, compact: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceContainerLowest.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Provenance

    /// Where the figures came from. Every value is measured or says it was
    /// not reported: a plausible placeholder in a diagnostics panel is read
    /// as fact.
    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Details")
            // The vendor's own note (e.g. which models share this allowance).
            if let note = snapshot.auxiliaryInfo {
                Text(note)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }
            ForEach(presentation.provenance) { row in
                diagRow(label: row.label, value: row.value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surfaceContainerLowest.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func diagRow(label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.Typography.subtitle)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
            Spacer(minLength: 8)
            Text(value ?? "Not reported")
                .font(Theme.Typography.subtitle.monospaced())
                .foregroundStyle(value == nil ? Theme.outline : Theme.onSurface)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value ?? "not reported")")
    }

    private func copyJson() {
        guard let json = InspectorExport(
            snapshot: snapshot, readingsCount: recordedHistory.count, readingsSince: recordedHistory.since).jsonString() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
