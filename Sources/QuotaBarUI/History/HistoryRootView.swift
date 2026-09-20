import SwiftUI
import AppKit
import QuotaBarCore

/// Main view for the History and Allowance Attribution window.
public struct HistoryRootView: View {
    @State private var timeRange: HistoryPresentation.TimeRange = .last24Hours
    @State private var selectedVendor: VendorIdentifier = .claude
    @State private var segments: [HistoryPresentation.TimelineSegment] = []
    @State private var pace: HistoryPresentation.PaceComparison?
    @State private var attribution: AttributionSummary?
    @State private var isSampleMode: Bool = CredentialStore.isSampleModeEnabled
    @State private var isLoading: Bool = false
    /// Non-nil when the history could not be read at all. Distinct from an empty
    /// history, which is a fact about the user's data rather than about us.
    @State private var loadError: String?
    /// Readings existed but none of them measure consumption (a billing-cycle
    /// row, say), so there is nothing legitimate to plot on a "Used %" axis.
    @State private var hasOnlyElapsedReadings: Bool = false

    private let liveStore: QuotaHistoryStore
    private let sampleStore: QuotaHistoryStore

    public init(
        liveStore: QuotaHistoryStore? = nil,
        sampleStore: QuotaHistoryStore? = nil
    ) {
        self.liveStore = liveStore ?? QuotaHistoryStore(databaseURL: QuotaHistoryStore.databaseURL())
        self.sampleStore = sampleStore ?? QuotaHistoryStore(databaseURL: QuotaHistoryStore.sampleDatabaseURL())
    }

    private var activeStore: QuotaHistoryStore {
        isSampleMode ? sampleStore : liveStore
    }

    /// One identity for everything a reload depends on.
    ///
    /// Three separate `.task(id:)` modifiers used to each fire `reloadData()` on
    /// first render — three concurrent reads, three concurrent fixture
    /// generations, and `isLoading` flapping between them.
    private struct ReloadKey: Hashable {
        let range: HistoryPresentation.TimeRange
        let vendor: VendorIdentifier
        let sampleMode: Bool
    }

    private var reloadKey: ReloadKey {
        ReloadKey(range: timeRange, vendor: selectedVendor, sampleMode: isSampleMode)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isSampleMode {
                sampleModeBanner
            }

            ScrollView {
                VStack(spacing: 14) {
                    if let loadError {
                        failureCard(loadError)
                    }

                    if let pace {
                        paceCard(pace)
                    }

                    chartCard

                    attributionCard

                    telemetryCard
                }
                .padding(16)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .background(Theme.surface)
        .task(id: reloadKey) {
            await reloadData()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
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

            // Vendor Picker
            Picker("", selection: $selectedVendor) {
                ForEach(VendorIdentifier.allCases, id: \.self) { vendor in
                    Text(vendor.displayName).tag(vendor)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            // Time Range Picker
            Picker("", selection: $timeRange) {
                ForEach(HistoryPresentation.TimeRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

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
            .help(isSampleMode ? "Exit sample data mode" : "Switch to sample data mode")
            .padding(.horizontal, 4)
        }
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
                Text("Window Pace: \(pace.vendor) (\(pace.barLabel))")
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
                Text("\(selectedVendor.displayName) Quota Timeline")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }

            QuotaTimelineChart(segments: segments, timeRange: timeRange)
                .frame(height: 240)

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
        if AttributionEngine.localSourceIdentifiers(for: selectedVendor).isEmpty {
            noLocalTelemetryCard
        } else if let attribution, !attribution.projectAttributions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Project Activity Breakdown")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.onSurface)
                        Text(attributionSubtitle(attribution))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                    }

                    Spacer()

                    Text(formatTokenCount(attribution.totalObservedTokens) + " observed tokens")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.primary.opacity(0.12))
                        .clipShape(Capsule())
                }

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

                caveatList(attribution.caveats)
            }
            .padding(14)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
            )
        }
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
                Text("FrugalBar has no local activity adapter for \(selectedVendor.displayName), so no project breakdown can be attributed to its allowance.")
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

    // MARK: - Data Reload

    private func reloadData() async {
        isLoading = true
        defer { isLoading = false }

        loadError = nil
        hasOnlyElapsedReadings = false

        if isSampleMode {
            do {
                try await SampleDataGenerator.ensureSampleData(in: sampleStore)
            } catch {
                loadError = "Could not prepare the sample fixture: \(error.localizedDescription)"
                segments = []
                pace = nil
                attribution = nil
                return
            }
        }

        let since = timeRange.startDate()
        let now = Date()

        do {
            let allReadings = try await activeStore.fetchReadings(
                vendor: selectedVendor,
                since: since
            )

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
            let sources = AttributionEngine.localSourceIdentifiers(for: selectedVendor)
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
                configuredVendors: [selectedVendor]
            )
        } catch {
            // A failed read must never render as "you have no history".
            loadError = error.localizedDescription
            segments = []
            pace = nil
            attribution = nil
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
