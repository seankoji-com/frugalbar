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
    @State private var footerHeight: CGFloat = 48

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
        onClose: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.readingsLoader = readingsLoader
        self.eventsLoader = eventsLoader
        self.balanceLoader = balanceLoader
        self.onClose = onClose
    }

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
                    footer
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                }
                .frame(width: 348)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .stroke(Theme.outlineVariant.opacity(0.4), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.6), radius: 20, x: 0, y: 10)
                .padding(Theme.edgeMargin)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: snapshot.id) { await load() }
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

    private func load() async {
        isLoading = true
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
        readings = r ?? []
        readingsFailed = r == nil
        balanceSeries = reads
        selectedBalanceID = selectedBalanceID ?? reads.first?.series.id
        historySince = since
        recentEvents = e ?? []
        eventsFailed = e == nil
        markerEvents = m ?? []
        markersFailed = m == nil
        now = loadTime
        isLoading = false
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VendorAvatarView(
                vendorId: snapshot.vendorId,
                status: snapshot.status,
                isExhausted: MetricRowPresentation(snapshot: snapshot).isExhausted
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snapshot.displayName)
                        .font(Theme.Typography.title)
                        .tracking(Theme.Tracking.title)
                        .foregroundStyle(Theme.onSurface)
                        .fixedSize(horizontal: false, vertical: true)

                    if let badge = snapshot.badgeText {
                        Text(badge)
                            .font(Theme.Typography.token)
                            .tracking(Theme.Tracking.token)
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.primary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }

                Text(snapshot.category.rawValue)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
            }
            // The column takes the row's remaining width, so the close button is
            // pinned right and the name is not starved by a flexible `Spacer`
            // competing with it for space.
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .padding(7)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(snapshot.displayName) details")
            .help("Close details (Esc)")
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 12)
        .background(Theme.surfaceContainerHigh)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.outlineVariant.opacity(0.5)).frame(height: 0.5)
        }
    }

    // MARK: - Content

    /// Layered so the answer comes first: the summary a glance needs, then
    /// the windows, chart and events to interrogate it with, then where the
    /// figures came from.
    private var content: some View {
        VStack(spacing: 12) {
            summaryCard
            if !presentation.windows.isEmpty {
                windowsCard
            }
            chartCard
            if Self.showsBalanceCard(for: snapshot) {
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

    private var summaryColor: Color { Self.color(for: presentation.summary.state) }

    /// Read by Settings' legend as well, so its swatches are the inspector's.
    nonisolated static func color(for state: MetricDetailPresentation.State) -> Color {
        switch state {
        case .unavailable, .lastPollFailed: Theme.outline
        case .healthy: Theme.secondary
        case .runningLow: Theme.tertiary
        case .critical, .exhausted, .blocked: Theme.error
        }
    }

    // MARK: Summary

    /// The glance: state in words and shape, the most pressing window's share
    /// used, when it resets, and a pace verdict only where the bar draws a
    /// pace tick.
    private var summaryCard: some View {
        let summary = presentation.summary
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: summary.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(summaryColor)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(summary.headline)
                        .font(Theme.Typography.cardBody.weight(.semibold))
                        .foregroundStyle(summaryColor)
                    Spacer(minLength: 4)
                    if let percent = summary.percentUsed, let label = summary.focusLabel {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            // A blocked window's figure is not headroom: the
                            // glyph sits beside it here as on every bar.
                            if summary.focusIsBlocked {
                                BlockedGlyph(color: summaryColor, size: 14)
                            }
                            Text("\(percent)%")
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
                        .foregroundStyle(Theme.primary.opacity(0.9))
                }
                if let pace = summary.paceVerdict {
                    Label(pace, systemImage: "gauge.with.needle")
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
                if let note = snapshot.auxiliaryInfo {
                    Text(note)
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
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
        .accessibilityLabel(summary.accessibilityLabel)
    }

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
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(line.label)
                            .font(Theme.Typography.token)
                            .tracking(Theme.Tracking.token)
                            .foregroundStyle(Theme.onSurfaceVariant)
                            .frame(width: 44, alignment: .leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        DualBarProgressView(metrics: line.metrics, showsLabel: false)
                        HStack(spacing: 3) {
                            if line.metrics.isBlocked, line.percentText != nil {
                                BlockedGlyph(color: DualBarProgressView.stateColor(for: line.metrics))
                            }
                            Text(line.percentText ?? line.noFigureText ?? "")
                                .font(Theme.Typography.gridPercent)
                                .foregroundStyle(line.percentText == nil
                                                 ? Theme.outline : DualBarProgressView.stateColor(for: line.metrics))
                        }
                        .frame(width: 62, alignment: .trailing)
                    }
                    if !line.detail.isEmpty {
                        Text(line.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                            .padding(.leading, 52)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(asOf == nil ? 1 : 0.55)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(asOf.map {
                    "\(line.accessibilityLabel), as of \(MetricDetailPresentation.clockText($0, now: now))"
                } ?? line.accessibilityLabel)
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
                Picker("Chart", selection: $chartMode) {
                    ForEach(ChartMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 170)
                .accessibilityLabel("Chart type")

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
                    Picker("Range", selection: $historyRange) {
                        ForEach(Self.historyRanges) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("History range")
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
           ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if burndown.isBlocked {
                        BlockedGlyph(color: Theme.onSurfaceVariant, size: 10)
                    }
                    // A blocked caption carries an extra clause; it wraps
                    // rather than cutting off the reset time.
                    Text(BurndownPresentation.summaryLine(for: burndown, now: now))
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(Theme.onSurfaceVariant)
                        .lineLimit(burndown.isBlocked ? 2 : 1)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHidden(true)
                BurndownChartView(burndown: burndown, now: now)
                if burndown.ideal == nil {
                    Text("No window length published, so no pace line can be drawn")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.outline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
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
            VStack(alignment: .leading, spacing: 4) {
                UsageHistoryChartView(
                    series: series,
                    range: historyRange,
                    markers: EventsPresentation.markerEvents(
                        markerEvents, vendor: snapshot.vendorId, range: historyRange, now: now
                    ),
                    now: now
                )
                if markersFailed {
                    Label("Reset markers could not be read, so resets may be missing from this chart.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.outline)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                        message: "Could not read the recorded balance. This is a failure to read, not an absence of readings."
                    )
                case .trend(let trend, let unit):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trend.caption(in: unit))
                            .font(Theme.Typography.subtitle)
                            .foregroundStyle(Theme.onSurfaceVariant)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
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
            sectionTitle("Source")
            ForEach(presentation.provenance) { row in
                diagRow(label: row.label, value: row.value)
            }
        }
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: copyJson) {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                    Text(copied ? "Copied" : "Copy JSON")
                        .font(Theme.Typography.footer)
                }
                .foregroundStyle(copied ? Theme.secondary : Theme.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copied details as JSON" : "Copy details as JSON")

            Spacer()

            Button("Done", action: onClose)
                .font(Theme.Typography.footer)
                .foregroundStyle(Theme.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
                .buttonStyle(.plain)
                .accessibilityLabel("Close details")
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 10)
        .background(Theme.surfaceContainerLowest)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.outlineVariant.opacity(0.5)).frame(height: 0.5)
        }
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
