import SwiftUI
import Charts
import QuotaBarCore

/// Content of the desktop widget panel: one burndown line per subscription
/// window, an honestly labelled average across them, a current-headroom
/// strip, and filters that persist across launches.
struct DesktopWidgetView: View {

    let store: QuotaStore

    @State private var filters: WidgetFilters = WidgetFilters.decode(CredentialStore.desktopWidgetFiltersData)
    @State private var series: [AggregateBurndownPresentation.VendorSeries] = []
    @State private var average: [AggregateBurndownPresentation.AveragePoint] = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    /// The clock the chart was computed against, so the x-axis and the data
    /// agree instead of each reading `Date()` separately.
    @State private var chartNow = Date()
    /// Bumped whenever the store's snapshots change, to re-query history.
    @State private var generation = 0

    private struct LoadKey: Equatable {
        let filters: WidgetFilters
        let generation: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if filters.layout == .overview {
                overviewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chartArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                headroomStrip
            }
            filterBar
        }
        .padding(.horizontal, 14)
        .padding(.top, 26)   // clear the transparent title bar's close button
        .padding(.bottom, 12)
        .frame(minWidth: 320, minHeight: 240)
        .preferredColorScheme(.dark)
        .task(id: LoadKey(filters: filters, generation: generation)) {
            await reload()
        }
        .onChange(of: store.snapshots) {
            generation &+= 1
        }
        .onChange(of: filters) {
            CredentialStore.desktopWidgetFiltersData = filters.encoded()
        }
    }

    // MARK: - Data

    private func reload() async {
        // The overview reads live snapshots only: no history query, no
        // segmenting or averaging. Switching back to Chart changes the
        // load key and loads then.
        guard filters.layout == .chart else { return }
        isLoading = true
        defer { isLoading = false }
        let now = Date()
        let snapshots = store.snapshots
        let since = filters.range.startDate(from: now)
        let vendors = AggregateBurndownPresentation.selectedVendors(snapshots: snapshots, filters: filters)

        var readings: [QuotaHistoryStore.ReadingRecord] = []
        for vendor in vendors {
            readings += await store.readings(for: vendor, since: since)
            if Task.isCancelled { return }
        }

        // Segmenting and averaging up to 30 days of readings is pure work on
        // Sendable values; keep it off the main actor so a poll never stalls
        // the popover.
        let input = readings
        let filtersNow = filters
        let (computed, avg) = await Task.detached(priority: .utility) {
            let computed = AggregateBurndownPresentation.series(
                readings: input, snapshots: snapshots, filters: filtersNow, now: now
            )
            let avg = computed.count > 1
                ? AggregateBurndownPresentation.average(
                    of: computed,
                    bucket: AggregateBurndownPresentation.bucketInterval(for: filtersNow.range),
                    now: now
                )
                : []
            return (computed.map { AggregateBurndownPresentation.decimated($0) }, avg)
        }.value
        guard !Task.isCancelled else { return }
        series = computed
        average = avg
        chartNow = now
        hasLoaded = true
    }

    private var metricWord: String { filters.metric == .used ? "used" : "remaining" }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: SystemHealthPresentation.symbol(for: store.summary))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SystemHealthPresentation.color(for: store.summary))
                .accessibilityLabel(SystemHealthPresentation.text(for: store.summary))

            Text(AggregateBurndownPresentation.title(for: filters))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.onSurface)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let oldest = store.summary.oldestReading {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let age = SystemHealthPresentation.elapsed(since: oldest, now: context.date)
                    Text("updated \(age) ago")
                        .font(Theme.Typography.footerMeta)
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
                        .accessibilityLabel("Oldest reading \(age) ago")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartArea: some View {
        if !hasLoaded && isLoading {
            placeholder(symbol: "hourglass", title: "Loading history…", detail: nil)
        } else if AggregateBurndownPresentation.availableVendors(snapshots: store.snapshots).isEmpty {
            placeholder(
                symbol: "chart.line.downtrend.xyaxis",
                title: "No subscription windows yet",
                detail: "Add a provider with a usage window in Settings."
            )
        } else if series.isEmpty {
            placeholder(
                symbol: "chart.line.downtrend.xyaxis",
                title: "No readings in this range",
                detail: "Readings accumulate as FrugalBar polls your providers."
            )
        } else {
            VStack(alignment: .leading, spacing: 4) {
                chart
                legend
            }
        }
    }

    private func placeholder(symbol: String, title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.4))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func accent(_ vendor: VendorIdentifier) -> Color {
        Color(hexString: vendor.accentColorHex) ?? Theme.primary
    }

    /// Shape is the non-colour channel for urgency (WCAG 1.4.1), matching the
    /// History chart's mapping.
    private func symbol(for point: AggregateBurndownPresentation.SeriesPoint) -> BasicChartSymbolShape {
        if point.isBlocked { return .square }
        if point.urgency == .critical { return .triangle }
        if point.urgency == .warning { return .diamond }
        return .circle
    }

    /// Point marks only where they say something: the latest reading of each
    /// series, and readings under pressure. A mark on every two-minute poll
    /// would bury the lines.
    private func showsPoint(
        _ point: AggregateBurndownPresentation.SeriesPoint,
        in series: AggregateBurndownPresentation.VendorSeries
    ) -> Bool {
        point.isBlocked || point.urgency > .none || point == series.latest
    }

    private var xDomain: ClosedRange<Date> {
        let start = filters.range.startDate(from: chartNow)
            ?? series.flatMap(\.allPoints).map(\.timestamp).min()
            ?? chartNow.addingTimeInterval(-3600)
        return min(start, chartNow)...chartNow
    }

    private var chart: some View {
        Chart {
            ForEach(series) { s in
                ForEach(s.segments) { segment in
                    ForEach(segment.points) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Percent", point.value * 100),
                            series: .value("Window", "\(s.id)|\(segment.id)")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(accent(s.vendorId))
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                }
                ForEach(s.allPoints.filter { showsPoint($0, in: s) }) { point in
                    PointMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Percent", point.value * 100)
                    )
                    .foregroundStyle(accent(s.vendorId))
                    .symbol(symbol(for: point))
                    .symbolSize(point.isBlocked || point.urgency > .none ? 26 : 16)
                }
            }
            ForEach(average) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Percent", point.value * 100),
                    series: .value("Window", "average|\(point.segment)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.onSurface.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 3]))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.35))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%")
                            .font(.system(size: 9.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.outlineVariant.opacity(0.2))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date))
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subscription burndown, percent \(metricWord), \(filters.range.title)")
        .accessibilityValue(AggregateBurndownPresentation.accessibilitySummary(
            series: series, average: average, filters: filters
        ))
    }

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("HHmm")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private func axisLabel(_ date: Date) -> String {
        filters.range == .last24Hours ? Self.hourFormatter.string(from: date) : Self.dayFormatter.string(from: date)
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(series) { s in
                    HStack(spacing: 4) {
                        Capsule().fill(accent(s.vendorId)).frame(width: 10, height: 3)
                        Text("\(s.vendorId.displayName) \(s.barLabel)")
                    }
                }
                if !average.isEmpty {
                    HStack(spacing: 4) {
                        Capsule().fill(Theme.onSurface.opacity(0.85)).frame(width: 12, height: 3)
                        Text(AggregateBurndownPresentation.averageLabel(for: average))
                    }
                    .help("Mean of the selected windows' real readings — not a combined quota.")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
        }
        .accessibilityHidden(true)   // the chart's accessibility value covers it
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewArea: some View {
        let tiles = OverviewPresentation.tiles(snapshots: store.snapshots, filters: filters)
        if tiles.isEmpty {
            placeholder(
                symbol: "tray",
                title: "No providers to show",
                detail: "Add a provider in Settings, or widen the subscriptions filter."
            )
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(tiles) { tile in
                            overviewTile(tile, now: context.date)
                        }
                    }
                }
            }
        }
    }

    private func overviewTile(_ tile: OverviewPresentation.Tile, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                VendorAvatarView(vendorId: tile.vendorId, status: tile.status, isExhausted: tile.isExhausted, size: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tile.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.onSurface)
                        .lineLimit(1)
                    if let plan = tile.planName {
                        Text(plan)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            if let headline = tile.unavailableHeadline {
                Text(headline)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.onSurfaceVariant)
                if let remedy = tile.unavailableRemedy {
                    Text(remedy)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
                        .lineLimit(2)
                }
            } else if tile.windows.isEmpty {
                Text("No usage windows")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
            } else {
                ForEach(tile.windows) { window in
                    overviewWindow(window, now: now)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OverviewPresentation.accessibilityLabel(for: tile, metric: filters.metric, now: now))
    }

    private func overviewWindow(_ window: OverviewPresentation.WindowCell, now: Date) -> some View {
        let color = DualBarProgressView.stateColor(for: window.metrics)
        return HStack(spacing: 5) {
            Text(window.label)
                .font(Theme.Typography.token)
                .tracking(Theme.Tracking.token)
                .foregroundStyle(Theme.onSurfaceVariant)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 30, alignment: .leading)
            // The bar always fills with what is *remaining*, matching the
            // headroom strip; the figure beside it follows the metric.
            MicroProgressBar(
                fraction: window.fraction.map {
                    window.measuresElapsedTimeOnly || filters.metric == .remaining ? $0 : 1 - $0
                },
                statusColor: color
            )
            .frame(maxWidth: .infinity)
            if let fraction = window.fraction {
                if window.showsBlockedGlyph {
                    BlockedGlyph(color: color, size: 8)
                }
                Text("\(Int((fraction * 100).rounded()))%\(window.measuresElapsedTimeOnly ? " elapsed" : "")")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.onSurface)
            } else {
                Text(window.isBlocked ? "blocked" : "—")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
            }
        }
        .help(OverviewPresentation.helpText(for: window, now: now))
    }

    // MARK: - Headroom strip

    @ViewBuilder
    private var headroomStrip: some View {
        let items = AggregateBurndownPresentation.currentHeadroom(snapshots: store.snapshots, filters: filters)
        if !items.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        headroomRow(item, now: context.date)
                    }
                }
            }
        }
    }

    private func headroomColor(_ item: AggregateBurndownPresentation.HeadroomItem) -> Color {
        if item.isBlocked || item.urgency == .critical { return Theme.error }
        if item.urgency == .warning { return Theme.tertiary }
        return Theme.healthy
    }

    private func headroomRow(_ item: AggregateBurndownPresentation.HeadroomItem, now: Date) -> some View {
        let percentText = item.remainingFraction.map { "\(Int(($0 * 100).rounded()))%" }
        return HStack(spacing: 6) {
            VendorAvatarView(vendorId: item.vendorId, status: item.status, size: 14)
            Text(item.barLabel)
                .font(Theme.Typography.token)
                .tracking(Theme.Tracking.token)
                .foregroundStyle(Theme.onSurfaceVariant)
                .frame(width: 26, alignment: .leading)
            MicroProgressBar(fraction: item.remainingFraction, statusColor: headroomColor(item))
                .frame(maxWidth: .infinity)
            if let percentText {
                if item.showsBlockedGlyph {
                    BlockedGlyph(color: headroomColor(item), size: 9)
                }
                Text(percentText)
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.onSurface)
            } else {
                Text(item.isBlocked ? "blocked" : "—")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
            }
            if item.resetsAt != nil {
                Text(ResetCountdownBadge.format(item.resetsAt, now: now))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.65))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AggregateBurndownPresentation.headroomAccessibilityLabel(item, now: now))
    }

    // MARK: - Filters

    private var availableVendors: [VendorIdentifier] {
        AggregateBurndownPresentation.availableVendors(snapshots: store.snapshots)
    }

    private func vendorBinding(_ vendor: VendorIdentifier) -> Binding<Bool> {
        Binding(
            get: { filters.vendors.isEmpty || filters.vendors.contains(vendor) },
            set: { isOn in
                var selected = filters.vendors.isEmpty ? Set(availableVendors) : filters.vendors
                if isOn { selected.insert(vendor) } else { selected.remove(vendor) }
                // Every vendor ticked is the same as "all", and stays "all"
                // when a new provider is configured later.
                filters.vendors = selected == Set(availableVendors) || selected.isEmpty ? [] : selected
            }
        )
    }

    private var vendorMenu: some View {
        Menu {
            Button("All subscriptions") { filters.vendors = [] }
            Divider()
            ForEach(availableVendors, id: \.self) { vendor in
                Toggle(vendor.displayName, isOn: vendorBinding(vendor))
            }
        } label: {
            Label(filters.vendors.isEmpty ? "All" : "\(filters.vendors.count) selected", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Subscriptions shown: \(filters.vendors.isEmpty ? "all" : filters.vendors.map(\.displayName).sorted().joined(separator: ", "))")
    }

    private var windowMenu: some View {
        Menu {
            Button("Longest window per subscription") { filters.windowLabel = nil }
            Divider()
            ForEach(AggregateBurndownPresentation.availableWindowLabels(snapshots: store.snapshots), id: \.self) { label in
                Button(label) { filters.windowLabel = label }
            }
        } label: {
            Text(filters.windowLabel ?? "All")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Window: \(filters.windowLabel ?? "longest per subscription")")
    }

    private var rangePicker: some View {
        Picker("Range", selection: $filters.range) {
            ForEach([HistoryPresentation.TimeRange.last24Hours, .last7Days, .last30Days]) { range in
                Text(AggregateBurndownPresentation.rangeShortTitle(range)).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Time range")
    }

    private var metricPicker: some View {
        Picker("Metric", selection: $filters.metric) {
            ForEach(WidgetFilters.Metric.allCases, id: \.self) { metric in
                Text(metric.title).tag(metric)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Show percent remaining or used")
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $filters.layout) {
            ForEach(WidgetFilters.Layout.allCases, id: \.self) { layout in
                Text(layout.title).tag(layout)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Widget layout")
    }

    private var filterBar: some View {
        let chart = filters.layout == .chart
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                layoutPicker
                vendorMenu
                if chart { windowMenu }
                Spacer(minLength: 4)
                if chart { rangePicker }
                metricPicker
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    layoutPicker
                    vendorMenu
                    if chart { windowMenu }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    if chart { rangePicker }
                    Spacer(minLength: 0)
                    metricPicker
                }
            }
        }
        .controlSize(.small)
        .font(.system(size: 11))
    }
}
