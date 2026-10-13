import SwiftUI
import AppKit
import QuotaBarCore

/// Main view for the History and Allowance Attribution window.
///
/// Reads top to bottom: an at-a-glance strip of every visible provider's
/// recent readings, then the selected provider's pace, an inspectable
/// timeline, and the local activity behind it.
public struct HistoryRootView: View {
    @State private var timeRange: HistoryPresentation.TimeRange = .last24Hours
    /// The selected provider or OpenCode Go workspace, by instance key.
    @State private var selectedSubjectID: String?
    /// Set once the user picks a subject, so a reload never moves them off it.
    @State private var userChoseSubject = false
    @State private var subjects: [HistoryOverviewPresentation.Subject] = []
    @State private var hiddenNames: [String] = []
    @State private var overviewCards: [HistoryOverviewPresentation.Card] = []
    @State private var overviewEmpty: [HistoryOverviewPresentation.Subject] = []
    @State private var overviewFailed = false
    /// Set once the strip has been read at least once, so a reload keeps the
    /// cards on screen instead of flashing "Reading…".
    @State private var overviewLoaded = false
    /// Bumped when Preferences changes which providers show, or the
    /// workspace order, so the strip and picker follow without a reopen.
    @State private var preferencesSerial = 0
    /// Bumped when a poll records new readings, and by the reload button, so
    /// the page follows the data instead of only the controls.
    @State private var dataSerial = 0
    @State private var lastReloadKey: ReloadKey?
    /// How far local-activity ingestion has got, read before the records.
    @State private var activityProgress: TokenUsagePresentation.IngestionProgress = .indexing
    @State private var segments: [HistoryPresentation.TimelineSegment] = []
    @State private var pace: HistoryPresentation.PaceComparison?
    @State private var attribution: AttributionSummary?
    @State private var isSampleMode: Bool = CredentialStore.isSampleModeEnabled
    @State private var isLoading: Bool = true
    /// Non-nil when the history could not be read at all. Distinct from an empty
    /// history, which is a fact about the user's data rather than about us.
    @State private var loadError: String?
    /// Readings existed but none of them measure consumption (a billing-cycle
    /// row, say), so there is nothing legitimate to plot on a "Used %" axis.
    @State private var hasOnlyElapsedReadings: Bool = false
    @State private var selectedTab: HistoryTab
    /// Reset-type events for the selected subject, drawn on the timeline.
    /// Always from the live store: the sample fixture records no events, and
    /// live markers over synthetic readings would assert a correlation that
    /// never happened.
    @State private var markers: [AIEvent] = []
    /// Set when the marker read failed, so missing markers are not mistaken
    /// for "no resets happened".
    @State private var markerLoadFailed: Bool = false

    private let liveStore: QuotaHistoryStore
    private let sampleStore: QuotaHistoryStore
    private let tabRequest: HistoryTabRequest?
    private let subjectSource: @MainActor () -> (subjects: [HistoryOverviewPresentation.Subject], hidden: [String])
    private let activityStatus: (@Sendable () async -> ActivityIngestionEngine.Status?)?

    /// - Parameters:
    ///   - subjectSource: the providers to offer and the hidden ones to name.
    ///     Defaults to the user's preferences; a test passes a fixture so a
    ///     render never depends on the shared preference file.
    ///   - activityStatus: this process's local-activity ingestion status.
    ///     Without it the breakdown never claims to be complete.
    public init(
        liveStore: QuotaHistoryStore? = nil,
        sampleStore: QuotaHistoryStore? = nil,
        initialTab: HistoryTab = .timeline,
        tabRequest: HistoryTabRequest? = nil,
        subjectSource: (@MainActor () -> (subjects: [HistoryOverviewPresentation.Subject], hidden: [String]))? = nil,
        activityStatus: (@Sendable () async -> ActivityIngestionEngine.Status?)? = nil
    ) {
        self.liveStore = liveStore ?? QuotaHistoryStore(databaseURL: QuotaHistoryStore.databaseURL())
        self.sampleStore = sampleStore ?? QuotaHistoryStore(databaseURL: QuotaHistoryStore.sampleDatabaseURL())
        self.tabRequest = tabRequest
        self.activityStatus = activityStatus
        self.subjectSource = subjectSource ?? {
            let prefs = CredentialStore.providerDisplayPreferences
            return (
                HistoryOverviewPresentation.subjects(
                    order: prefs.order, hidden: prefs.hidden, workspaces: OpenCodeGoWorkspaceStore.resolved()),
                HistoryOverviewPresentation.hiddenNames(order: prefs.order, hidden: prefs.hidden)
            )
        }
        _selectedTab = State(initialValue: initialTab)
    }

    private var activeStore: QuotaHistoryStore {
        isSampleMode ? sampleStore : liveStore
    }

    private var selectedSubject: HistoryOverviewPresentation.Subject? {
        subjects.first { $0.id == selectedSubjectID } ?? subjects.first
    }

    /// One identity for everything a reload depends on.
    ///
    /// Three separate `.task(id:)` modifiers used to each fire `reloadData()` on
    /// first render — three concurrent reads, three concurrent fixture
    /// generations, and `isLoading` flapping between them.
    private struct ReloadKey: Hashable {
        let range: HistoryPresentation.TimeRange
        let subject: String?
        let sampleMode: Bool
        let preferencesSerial: Int
        let dataSerial: Int

        /// Only new data arrived: reload in place, without the loading state.
        func isDataRefresh(of previous: ReloadKey?) -> Bool {
            guard let previous else { return false }
            return range == previous.range && subject == previous.subject && sampleMode == previous.sampleMode
                && preferencesSerial == previous.preferencesSerial && dataSerial != previous.dataSerial
        }
    }

    private var reloadKey: ReloadKey {
        ReloadKey(range: timeRange, subject: selectedSubjectID, sampleMode: isSampleMode,
                  preferencesSerial: preferencesSerial, dataSerial: dataSerial)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isSampleMode {
                sampleModeBanner
            }

            switch selectedTab {
            case .timeline:
                ScrollView {
                    VStack(spacing: 14) {
                        if let loadError {
                            failureCard(loadError)
                        }

                        overviewSection

                        if selectedSubject != nil {
                            if !isLoading, let pace {
                                paceCard(pace)
                            }

                            chartCard

                            if !isLoading { attributionCard }

                            telemetryCard
                        }
                    }
                    .padding(16)
                }
            case .events:
                EventsListView(store: liveStore, isSampleMode: isSampleMode)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .background(Theme.surface)
        .task(id: reloadKey) {
            await reloadData()
        }
        .onChange(of: tabRequest?.serial) {
            if let tabRequest { selectedTab = tabRequest.tab }
        }
        .onReceive(NotificationCenter.default.publisher(for: .frugalbarProviderPreferencesDidChange)) { _ in
            preferencesSerial += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .frugalbarHistoryDidRecord)) { _ in
            dataSerial += 1
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Allowance History")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.onSurface)

                        if isSampleMode {
                            Text("SAMPLE DATA")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.tertiary.opacity(0.2))
                                .foregroundStyle(Theme.tertiary)
                                .clipShape(Capsule())
                        }
                    }
                    Text("Track quota consumption over time and monitor burn rate.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                }

                Spacer()

                Button {
                    dataSerial += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(selectedTab != .timeline)
                .accessibilityLabel("Reload history")
                .help("Read the history again. It also reloads whenever a poll records new readings.")

                Picker("View", selection: $selectedTab) {
                    ForEach(HistoryTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("History view")

                // Sample Mode Toggle Button
                Button {
                    let next = !isSampleMode
                    isSampleMode = next
                    CredentialStore.isSampleModeEnabled = next
                } label: {
                    Image(systemName: isSampleMode ? "flask.fill" : "flask")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSampleMode ? Theme.tertiary : Theme.onSurfaceVariant.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSampleMode ? "Exit sample data mode" : "View sample data")
                .help(isSampleMode ? "Exit sample data mode" : "Switch to sample data mode")
                .padding(.horizontal, 4)
            }
            // The events tab has its own filter bar.
            if selectedTab == .timeline {
                HStack(spacing: 12) {
                    // Time range first: it applies to the whole page, the
                    // overview included.
                    Picker("Time range", selection: $timeRange) {
                        ForEach(HistoryPresentation.TimeRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("History time range")

                    // Providers and workspaces in the popover's order. Hidden
                    // ones are absent: they are not polled.
                    Picker("Provider", selection: Binding(
                        get: { selectedSubject?.id ?? "" },
                        set: { select($0) }
                    )) {
                        ForEach(subjects) { subject in
                            Text(subject.name).tag(subject.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .fixedSize(horizontal: false, vertical: true)
                    .disabled(subjects.isEmpty)
                    .accessibilityLabel("History provider")
                    Spacer(minLength: 0)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.outlineVariant.opacity(0.25))
                .frame(height: 1)
        }
    }

    private var sampleModeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)

            Text("Viewing synthetic sample fixture data. Real historical readings remain untouched.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.onSurface)

            Spacer()

            Button("Exit Sample Mode") {
                isSampleMode = false
                CredentialStore.isSampleModeEnabled = false
            }
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.tertiary.opacity(0.12))
    }

    // MARK: - Pace Card

    private func paceCard(_ pace: HistoryPresentation.PaceComparison) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                let name = selectedSubject?.name
                    ?? OpenCodeGoWorkspaceStore.displayName(forInstanceKey: pace.vendor)
                    ?? OpenCodeGoWorkspaceStore.vendor(forInstanceKey: pace.vendor)?.displayName
                    ?? pace.vendor
                Text("Window Pace: \(name) (\(pace.barLabel))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)

                Spacer()

                Text(pace.status.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(paceBadgeBackground(pace.status))
                    .foregroundStyle(paceBadgeColor(pace.status))
                    .clipShape(Capsule())
            }

            Text(pace.headline)
                .font(.system(size: 12))
                .foregroundStyle(Theme.onSurfaceVariant)

            VStack(spacing: 6) {
                paceProgressBar(
                    label: "Quota Consumed",
                    fraction: pace.consumedFraction,
                    color: paceBadgeColor(pace.status)
                )
                paceProgressBar(
                    label: "Window Elapsed",
                    fraction: pace.elapsedFraction,
                    color: Theme.primary.opacity(0.85)
                )
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func paceProgressBar(label: String, fraction: Double, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                .frame(width: 100, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.surfaceContainerHigh)
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, proxy.size.width * CGFloat(min(1.0, max(0.0, fraction)))))
                }
            }
            .frame(height: 6)

            Text("\(Int(round(fraction * 100)))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.onSurface)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func paceBadgeColor(_ status: HistoryPresentation.PaceStatus) -> Color {
        switch status {
        case .aheadOfPace: Theme.tertiary
        case .onPace: Theme.primary
        case .underPace: Theme.healthy
        }
    }

    private func paceBadgeBackground(_ status: HistoryPresentation.PaceStatus) -> Color {
        paceBadgeColor(status).opacity(0.18)
    }

    // MARK: - Chart Card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(selectedSubject?.name ?? "") Quota Timeline")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }

            Group {
                if isLoading {
                    Text("Loading readings…")
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(Theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadError != nil {
                    Label("Timeline unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    QuotaTimelineChart(
                        segments: segments, timeRange: timeRange, markers: markers,
                        emptyMessage: HistoryOverviewPresentation.emptyExplanation(
                            isSampleMode: isSampleMode, range: timeRange))
                }
            }
            .frame(height: 240)

            if markerLoadFailed {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                    Text("Reset markers could not be read, so resets may be missing from this chart.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            if !isLoading, loadError == nil, !segments.isEmpty {
                Text("Hover the chart, or click it and use the arrow keys, to read an exact reading and when it was taken.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.outline)
                    .accessibilityHidden(true)
            }

            if hasOnlyElapsedReadings {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.onSurfaceVariant)
                    Text("This vendor's readings for the window measure elapsed time, not consumption, so there is nothing to plot as used percentage.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Attribution Card

    @ViewBuilder
    private var attributionCard: some View {
        if AttributionEngine.localSourceIdentifiers(for: selectedSubject?.vendor ?? .claude).isEmpty {
            noLocalTelemetryCard
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Project Activity Breakdown")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.onSurface)
                        if let attribution {
                            Text(attributionSubtitle(attribution))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                        }
                    }

                    Spacer()

                    if let attribution, !attribution.projectAttributions.isEmpty {
                        Text(formatTokenCount(attribution.totalObservedTokens) + " observed tokens")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.primary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                if let subject = selectedSubject,
                   let scope = HistoryPresentation.activityScopeNote(vendor: subject.vendor, subjectName: subject.name) {
                    activityNote(symbol: "person.2", text: scope)
                }

                if let attribution, !attribution.projectAttributions.isEmpty {
                    if let note = HistoryPresentation.activityProgressNote(activityProgress) {
                        activityNote(symbol: activityProgress == .indexing ? "hourglass" : "exclamationmark.triangle",
                                     text: note)
                    }
                    projectBars(attribution)
                    caveatList(attribution.caveats)
                } else {
                    activityNote(
                        symbol: activityProgress == .complete ? "tray" : "hourglass",
                        text: HistoryPresentation.activityEmptyMessage(
                            activityProgress,
                            vendorName: selectedSubject?.vendor.displayName ?? "",
                            recordsWithoutTokenTotals: attribution?.recordsWithoutTokenTotals ?? 0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    private func projectBars(_ attribution: AttributionSummary) -> some View {
        VStack(spacing: 8) {
            ForEach(attribution.projectAttributions) { project in
                VStack(spacing: 4) {
                    HStack {
                        Text(project.displayName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.onSurface)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Text("\(formatTokenCount(project.tokenCount)) (\(Int(round(project.tokenShare * 100)))%)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onSurfaceVariant)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Theme.surfaceContainerHigh)
                            Capsule()
                                .fill(Theme.primary)
                                .frame(width: max(0, proxy.size.width * CGFloat(min(1.0, max(0.0, project.tokenShare)))))
                        }
                    }
                    .frame(height: 5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(project.displayName), \(formatTokenCount(project.tokenCount)) tokens, \(Int(round(project.tokenShare * 100))) percent of observed tokens, \(project.sessionCount) sessions")
            }
        }
    }

    private func activityNote(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurfaceVariant)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Shown for a vendor with no local activity adapter. Rendering another
    /// tool's tokens here would imply they explain this vendor's allowance.
    private var noLocalTelemetryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project Activity Breakdown")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onSurface)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onSurfaceVariant)
                Text("FrugalBar has no local activity adapter for \(selectedSubject?.vendor.displayName ?? "this provider"), so no project breakdown can be attributed to its allowance.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private func attributionSubtitle(_ attribution: AttributionSummary) -> String {
        if let label = attribution.barLabel {
            return "Share of locally observed tokens in this window · \(label) window"
        }
        return "Share of locally observed tokens in this window"
    }

    @ViewBuilder
    private func caveatList(_ caveats: [AttributionCaveat]) -> some View {
        if !caveats.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(caveats, id: \.rawValue) { caveat in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: caveat == .concurrentSessionsDetected
                              ? "clock.arrow.2.circlepath"
                              : "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                        Text(caveat.explanation)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
            .background(Theme.tertiary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Telemetry & Attribution Card

    private var telemetryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity & Observed Tokens")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.onSurface)

            Text("Local coding sessions are monitored from CLI telemetry (Claude Code, Codex, OpenCode). Observed tokens are tracked in their native token counts and are never converted to vendor quota percentages.")
                .font(.system(size: 11))
                .lineSpacing(1.5)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))

            Divider()
                .background(Theme.outlineVariant.opacity(0.25))
                .padding(.vertical, 2)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary.opacity(0.9))

                // Derived from the engine's own set rather than restated here, so
                // the copy cannot drift from the caveat logic. States what
                // FrugalBar knows — that it has no adapter — rather than making a
                // claim about what those tools write to disk.
                Text("No local activity adapter: \(unmonitoredVendorNames). FrugalBar cannot read session token counts for these tools, so their usage is not represented above.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    /// Sorted so the copy is stable between launches.
    private var unmonitoredVendorNames: String {
        AttributionEngine.unmonitoredVendorIdentifiers
            .map(\.displayName)
            .sorted()
            .joined(separator: ", ")
    }

    // MARK: - Overview

    /// Small multiples: one card per visible provider or workspace, each its
    /// own longest window. Nothing here sums or averages across cards.
    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("At a glance")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Text("· \(timeRange.title.lowercased()), each provider's longest window")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                Spacer()
            }

            if subjects.isEmpty {
                overviewNote(
                    symbol: "eye.slash",
                    text: "Every provider is hidden in Preferences → Providers, so there is nothing to chart.")
            } else if overviewFailed {
                overviewNote(
                    symbol: "exclamationmark.triangle",
                    text: "The overview could not be read. This is a failure to read, not an absence of data.")
            } else if !overviewLoaded {
                overviewNote(symbol: "hourglass", text: "Reading recorded history…")
            } else if overviewCards.isEmpty {
                overviewNote(
                    symbol: "chart.line.uptrend.xyaxis",
                    text: HistoryOverviewPresentation.emptyExplanation(isSampleMode: isSampleMode, range: timeRange))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    ForEach(overviewCards) { card in
                        HistoryOverviewCardView(
                            card: card,
                            isSelected: card.subject.id == selectedSubject?.id,
                            onSelect: { select(card.subject.id) })
                    }
                }
            }

            if !overviewEmpty.isEmpty, !overviewCards.isEmpty {
                overviewNote(
                    symbol: "circle.dashed",
                    text: "No readings in this range: \(overviewEmpty.map(\.name).joined(separator: ", ")).")
            }
            if !hiddenNames.isEmpty {
                overviewNote(
                    symbol: "eye.slash",
                    text: "Hidden in Preferences, so not polled or shown: \(hiddenNames.joined(separator: ", ")).")
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func overviewNote(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurfaceVariant)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func select(_ id: String) {
        guard subjects.contains(where: { $0.id == id }) else { return }
        userChoseSubject = true
        selectedSubjectID = id
    }

    // MARK: - Data Reload

    private func reloadData() async {
        let key = reloadKey
        // New readings reload in place; anything the user changed shows the
        // loading state, so a stale chart is never mistaken for the new pick.
        if !key.isDataRefresh(of: lastReloadKey) { isLoading = true }
        lastReloadKey = key
        defer { isLoading = false }

        loadError = nil
        hasOnlyElapsedReadings = false

        let source = subjectSource()
        subjects = source.subjects
        hiddenNames = source.hidden
        if !subjects.contains(where: { $0.id == selectedSubjectID }) {
            selectedSubjectID = subjects.first?.id
            userChoseSubject = false
        }

        if isSampleMode {
            do {
                try await SampleDataGenerator.ensureSampleData(in: sampleStore)
            } catch {
                NSLog("frugalbar: sample history failed: %@", error.localizedDescription)
                loadError = "Could not prepare the sample data. Try again or reopen FrugalBar."
                segments = []
                pace = nil
                attribution = nil
                return
            }
        }

        await reloadOverview()
        // Until the user picks one, lead with the first provider that has
        // something to show rather than an empty chart.
        if !userChoseSubject, let first = overviewCards.first,
           !overviewCards.contains(where: { $0.subject.id == selectedSubjectID }) {
            selectedSubjectID = first.subject.id
        }
        guard let subject = selectedSubject else {
            segments = []
            pace = nil
            attribution = nil
            markers = []
            return
        }

        await reloadMarkers(for: subject)

        let since = timeRange.startDate()
        let now = Date()

        do {
            // Every key the subject owns, and no sibling's: the vendor-wide
            // read returns each OpenCode Go workspace, which must not be drawn
            // or paced as one.
            let allReadings = try await activeStore.fetchReadings(
                vendor: subject.vendor,
                since: since
            ).filter { subject.keys.contains($0.vendor) }

            // Only consumption belongs on a "Used %" axis. A window that measures
            // elapsed time would otherwise be drawn — and paced — as quota spent.
            let readings = HistoryPresentation.consumptionReadings(allReadings)
            hasOnlyElapsedReadings = readings.isEmpty && !allReadings.isEmpty

            // Everything below is scoped to ONE bar label. `fetchReadings` returns
            // every label for the vendor, interleaved by time, so taking the
            // endpoints across the unfiltered list subtracted one window's
            // fraction from another's.
            let barLabel = AttributionEngine.preferredBarLabel(readings: readings)
            self.segments = HistoryPresentation.segments(from: readings)

            let scoped = barLabel.map { label in readings.filter { $0.barLabel == label } } ?? []

            if let latest = scoped.last(where: { $0.fraction != nil && $0.resetsAt != nil }) {
                self.pace = HistoryPresentation.computePace(reading: latest, now: now)
            } else {
                self.pace = nil
            }

            // Activity is restricted to the sources that can actually speak for
            // the selected vendor. Showing Codex and OpenCode tokens beneath a
            // "Claude" heading asserted an attribution nothing measured.
            let sources = AttributionEngine.localSourceIdentifiers(for: subject.vendor)
            // The status first: records read before it could be from a pass
            // that finished after it, and would then be vouched for wrongly.
            // The sample fixture is written whole before it is read.
            activityProgress = isSampleMode
                ? .complete
                : TokenUsagePresentation.IngestionProgress(await activityStatus?())
            let allActivities = try await activeStore.fetchActivities(since: since, until: now)
            let activities = allActivities.filter { sources.contains($0.source) }

            let endpoints: (start: Double?, end: Double?)
            if let barLabel {
                endpoints = AttributionEngine.consumptionEndpoints(readings: readings, barLabel: barLabel)
            } else {
                endpoints = (nil, nil)
            }

            self.attribution = AttributionEngine.computeAttribution(
                windowStart: since ?? (readings.first?.measuredAt ?? now),
                windowEnd: now,
                barLabel: barLabel,
                startConsumptionFraction: endpoints.start,
                endConsumptionFraction: endpoints.end,
                activities: activities,
                configuredVendors: [subject.vendor]
            )
        } catch {
            // A failed read must never render as "you have no history".
            NSLog("frugalbar: history read failed: %@", error.localizedDescription)
            loadError = HistoryPresentation.failureMessage(for: error)
            segments = []
            pace = nil
            attribution = nil
        }
    }

    /// Re-reads the strip on every reload — a new range, source, subject or
    /// poll — through the thinned query, so a 30-day strip of every provider
    /// stays a few thousand rows. It is never served from a cache: a cached
    /// strip kept showing readings older than the chart beneath it, and kept
    /// a failed read failed.
    private func reloadOverview() async {
        let now = Date()
        let store = activeStore
        let retention = await store.retentionInterval
        let bucket = HistoryOverviewPresentation.sampleBucketSeconds(range: timeRange, retention: retention)
        do {
            let sampled = try await store.fetchSampledReadings(
                since: timeRange.startDate(from: now),
                until: now,
                bucketSeconds: bucket)
            let overview = HistoryOverviewPresentation.overview(
                subjects: subjects, readings: sampled, bucketSeconds: bucket)
            overviewCards = overview.cards
            overviewEmpty = overview.empty
            overviewFailed = false
        } catch {
            NSLog("frugalbar: history overview read failed: %@", error.localizedDescription)
            overviewCards = []
            overviewEmpty = []
            overviewFailed = true
        }
        overviewLoaded = true
    }

    /// Reset markers for the timeline, from the live store only.
    private func reloadMarkers(for subject: HistoryOverviewPresentation.Subject) async {
        markerLoadFailed = false
        guard !isSampleMode else {
            markers = []
            return
        }
        let now = Date()
        do {
            let events = try await liveStore.fetchEvents(
                vendor: subject.vendor,
                instanceID: subject.id,
                kinds: EventsPresentation.markerKinds,
                since: timeRange.startDate(from: now)
            )
            markers = EventsPresentation.markerEvents(events, vendor: subject.vendor, range: timeRange, now: now)
        } catch {
            markers = []
            markerLoadFailed = true
        }
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.error)
                Text("Could not read quota history")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)
            }

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            Text("This is a failure to read, not an absence of data.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.error.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.error.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Could not read quota history. \(message)")
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.0fk", Double(count) / 1000.0)
        } else {
            return "\(count)"
        }
    }
}
