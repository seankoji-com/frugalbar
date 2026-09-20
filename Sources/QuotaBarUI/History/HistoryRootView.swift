import SwiftUI
import AppKit
import QuotaBarCore

/// Main view for the History and Allowance Attribution window.
public struct HistoryRootView: View {
    @State private var timeRange: HistoryPresentation.TimeRange = .last24Hours
    @State private var selectedVendor: VendorIdentifier = .claude
    @State private var readings: [QuotaHistoryStore.ReadingRecord] = []
    @State private var segments: [HistoryPresentation.TimelineSegment] = []
    @State private var pace: HistoryPresentation.PaceComparison?
    @State private var attribution: AttributionSummary?
    @State private var isSampleMode: Bool = CredentialStore.isSampleModeEnabled
    @State private var isLoading: Bool = false

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

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isSampleMode {
                sampleModeBanner
            }

            ScrollView {
                VStack(spacing: 14) {
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
        .task(id: timeRange) {
            await reloadData()
        }
        .task(id: selectedVendor) {
            await reloadData()
        }
        .task(id: isSampleMode) {
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
        if let attribution, !attribution.projectAttributions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Project Activity Breakdown")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.onSurface)
                        Text("Share of locally observed tokens in this time window")
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
                    }
                }

                if attribution.hasConcurrentSessions {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                        Text("Multiple CLI sessions ran simultaneously in this window; individual session share cannot be fully separated.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
                    }
                    .padding(8)
                    .background(Theme.tertiary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary.opacity(0.9))

                Text("Unmonitored sources: Grok, Kiro, Gemini (these tools do not record local session tokens on disk).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
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

    // MARK: - Data Reload

    private func reloadData() async {
        isLoading = true
        defer { isLoading = false }

        if isSampleMode {
            try? await SampleDataGenerator.ensureSampleData(in: sampleStore)
        }

        let since = timeRange.startDate()
        do {
            let fetched = try await activeStore.fetchReadings(
                vendor: selectedVendor,
                since: since
            )
            self.readings = fetched
            self.segments = HistoryPresentation.segments(from: fetched)

            // Compute pace from latest measured reading
            if let latest = fetched.last(where: { $0.fraction != nil && $0.resetsAt != nil }) {
                self.pace = HistoryPresentation.computePace(reading: latest)
            } else {
                self.pace = nil
            }

            // Fetch activities and compute attribution
            let activities = try await activeStore.fetchActivities(
                since: since,
                until: Date()
            )
            let startFrac = fetched.first(where: { $0.fraction != nil })?.fraction
            let endFrac = fetched.last(where: { $0.fraction != nil })?.fraction
            self.attribution = AttributionEngine.computeAttribution(
                windowStart: since ?? (fetched.first?.measuredAt ?? Date()),
                windowEnd: Date(),
                startConsumptionFraction: startFrac,
                endConsumptionFraction: endFrac,
                activities: activities,
                configuredVendors: [selectedVendor]
            )
        } catch {
            self.readings = []
            self.segments = []
            self.pace = nil
            self.attribution = nil
        }
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
