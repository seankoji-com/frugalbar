import SwiftUI
import QuotaBarCore

/// Content of the desktop widget panel, in one of two layouts: the story of
/// one pool (the default), or raw token consumption stacked across providers.
/// Filters persist across launches.
struct DesktopWidgetView: View {

    let store: QuotaStore

    @State private var filters: WidgetFilters = WidgetFilters.decode(CredentialStore.desktopWidgetFiltersData)
    /// Bumped whenever the store's snapshots change, to re-query history.
    @State private var generation = 0
    /// The Tokens layout's chart, nil until loaded.
    @State private var tokenChart: TokenUsagePresentation.Chart?
    /// The history could not be read: said, never drawn as "no activity".
    @State private var tokenLoadFailed = false

    private struct LoadKey: Equatable {
        let filters: WidgetFilters
        let generation: Int
    }

    init(store: QuotaStore, filters: WidgetFilters? = nil) {
        self.store = store
        _filters = State(initialValue: filters ?? WidgetFilters.decode(CredentialStore.desktopWidgetFiltersData))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch filters.layout {
            case .tokens:
                header
                tokensArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .story:
                ProviderStoryView(store: store, poolID: $filters.storyPoolID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // The story reads live snapshots only. Switching layout changes the
        // load key and loads then.
        guard filters.layout == .tokens else { return }
        // While the first ingestion runs the table fills in behind us, so
        // look again every few seconds instead of waiting for the next poll,
        // and stop as soon as it has finished.
        var again = await reloadTokens()
        while again, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            again = await reloadTokens()
        }
    }

    /// One aggregate query for the range, summed inside SQLite, then a few
    /// dozen points of arithmetic. Providers the user hid are left out.
    ///
    /// Returns whether to look again soon: the first ingestion is still
    /// running and its status is known.
    @discardableResult
    private func reloadTokens() async -> Bool {
        let now = Date()
        // Status BEFORE the data, so it can only be older than what is drawn.
        // A pass finishing in between then makes the chart show a note it no
        // longer needs, never a "complete" claim about data read earlier.
        let status = await store.activityIngestionStatus()
        let window = TokenUsagePresentation.window(range: filters.range, now: now)
        let usage = await store.tokenUsage(
            since: window.since, until: now,
            bucketSeconds: TokenUsagePresentation.bucketSeconds(for: filters.range),
            anchor: window.anchor)
        guard !Task.isCancelled else { return false }
        guard let usage else {
            tokenChart = nil
            tokenLoadFailed = true
            return false
        }
        let configured = store.snapshots.map(\.vendorId).filter { store.configuredVendors.contains($0) }
        let progress = TokenUsagePresentation.IngestionProgress(status)
        tokenChart = TokenUsagePresentation.chart(
            usage: usage, filters: filters, hidden: CredentialStore.hiddenProviders,
            configured: configured, ingestion: progress, now: now,
            sources: status?.sources ?? [])
        tokenLoadFailed = false
        return progress == .indexing && status != nil
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: SystemHealthPresentation.symbol(for: store.summary))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SystemHealthPresentation.color(for: store.summary))
                .accessibilityLabel(SystemHealthPresentation.text(for: store.summary))

            Text(filters.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.onSurface)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Tokens

    @ViewBuilder
    private var tokensArea: some View {
        if tokenLoadFailed {
            placeholder(
                symbol: "exclamationmark.triangle",
                title: "Could not read token history",
                detail: "This is a failure to read, not an absence of activity."
            )
        } else if let chart = tokenChart {
            if let reason = chart.emptyReason {
                // Empty means "no activity" only once ingestion is complete;
                // before that the table is still being filled, and after a
                // failed pass some sources are missing.
                placeholder(
                    symbol: Self.emptySymbol(reason),
                    title: TokenUsagePresentation.emptyTitle(reason),
                    detail: TokenUsagePresentation.emptyDetail(for: chart)
                )
            } else {
                TokenUsageChartView(chart: chart, range: filters.range)
            }
        } else {
            placeholder(symbol: "hourglass", title: "Loading token history…", detail: nil)
        }
    }

    private static func emptySymbol(_ reason: TokenUsagePresentation.EmptyReason) -> String {
        switch reason {
        case .noActivity: "chart.xyaxis.line"
        case .indexing: "hourglass"
        case .incomplete: "exclamationmark.triangle"
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
                    .foregroundStyle(Theme.outline)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Filters

    /// The providers the vendor menu offers: those with a token source.
    private var availableVendors: [VendorIdentifier] { TokenUsagePresentation.tokenVendors }

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

    private var rangePicker: some View {
        Picker("Range", selection: $filters.range) {
            ForEach([HistoryPresentation.TimeRange.last24Hours, .last7Days, .last30Days]) { range in
                Text(WidgetFilters.rangeShortTitle(range)).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Time range")
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
        // The story has one control: which pool it follows. Tokens choose
        // providers and a range.
        if filters.layout == .story {
            return AnyView(HStack(spacing: 8) {
                layoutPicker
                StoryPoolMenu(glance: GlancePresentation(snapshots: store.snapshots, now: Date()),
                              poolID: $filters.storyPoolID)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .font(.system(size: 11)))
        }
        return AnyView(ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                layoutPicker
                vendorMenu
                Spacer(minLength: 4)
                rangePicker
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    layoutPicker
                    vendorMenu
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    rangePicker
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
        .font(.system(size: 11)))
    }
}
