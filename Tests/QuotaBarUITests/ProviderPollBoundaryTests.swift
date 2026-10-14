import Testing
import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

/// A poll that returned no window is recorded once, under the provider's own
/// label, not under each window. Every surface that draws or states a window
/// must still see it. Rows here are written by `QuotaHistoryStore.record`, as
/// production writes them, so a fixture cannot put the failure under the
/// window label the code happens to read.
@Suite("Provider poll boundaries")
struct ProviderPollBoundaryTests {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private var fiveHourReset: Date { base.addingTimeInterval(4 * 3_600) }
    private var weekReset: Date { base.addingTimeInterval(3 * 86_400) }

    private func makeStore() -> QuotaHistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("boundaries.sqlite3")
        return QuotaHistoryStore(databaseURL: url, isTestHost: true)
    }

    private func measured(fiveHour: Double, week: Double) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: week, displayDetails: nil),
            status: .measured(.none), resetsAt: weekReset, lastUpdated: base, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: fiveHour, label: "5H",
                                 resetsAt: fiveHourReset, windowLength: 5 * 3_600),
            row2: DualBarMetrics(primaryFraction: week, label: "WK",
                                 resetsAt: weekReset, windowLength: 7 * 86_400))
    }

    private var offline: QuotaSnapshot {
        QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0, displayDetails: nil),
            status: .unavailable(.offline), resetsAt: nil, lastUpdated: base, auxiliaryInfo: nil)
    }

    private func minutes(_ m: Double) -> Date { base.addingTimeInterval(m * 60) }

    /// Four measured polls ten minutes apart with a steady burn, then an
    /// offline poll at +40m.
    private func recordBurnThenOutage(_ store: QuotaHistoryStore) async throws {
        for i in 0..<4 {
            try await store.record(
                [measured(fiveHour: 0.30 + Double(i) * 0.04, week: 0.40 + Double(i) * 0.01)],
                now: minutes(Double(i) * 10))
        }
        try await store.record([offline], now: minutes(40))
    }

    // MARK: - The current burndown

    /// Regression: the burndown filtered to the window before looking for
    /// the newest poll, so a later failed poll (stored under `DEFAULT`)
    /// never reached it and the inspector said "58% left · … · out in 2h
    /// 10m" under a provider that had just failed. Proven red by restoring
    /// the label filter ahead of `readingAtLatestPoll` in `burndown`.
    @Test("a failed poll after measured ones leaves no current burndown and no projection")
    func failedPollGatesBurndown() async throws {
        let store = makeStore()
        try await recordBurnThenOutage(store)
        let readings = try await store.fetchReadings(vendor: .claude, since: nil)
        #expect(readings.contains { $0.barLabel == QuotaHistoryStore.providerPollLabel })

        let now = minutes(41)
        #expect(BurndownPresentation.burndown(
            readings: readings, instanceID: "claude", barLabel: "5H", now: now) == nil)
        let absence = BurndownPresentation.burndownAbsence(
            readings: readings, instanceID: "claude", barLabel: "5H", now: now)
        #expect(absence == .lastPollFailed)
        #expect(absence.message.contains("could not be read"))

        // Once it answers, the burndown is back, starting after the outage.
        try await store.record([measured(fiveHour: 0.50, week: 0.44)], now: minutes(50))
        let recovered = try await store.fetchReadings(vendor: .claude, since: nil)
        let burndown = try #require(BurndownPresentation.burndown(
            readings: recovered, instanceID: "claude", barLabel: "5H", now: minutes(51)))
        #expect(burndown.actual.map(\.timestamp) == [minutes(50)])
        #expect(burndown.projection == nil)
    }

    // MARK: - Lines across an outage

    /// Regression: `segments` split readings by window before it looked at
    /// failures, so the `DEFAULT` row sat in a group of its own and the WK
    /// and 5H lines ran straight across the outage in the timeline, the
    /// inspector's history, the overview sparkline and the widget. Proven
    /// red by dropping the provider polls from the merge in `segments`.
    @Test("a failed provider poll breaks every window's line on every surface")
    func failedPollBreaksEveryWindow() async throws {
        let store = makeStore()
        try await recordBurnThenOutage(store)
        try await store.record([measured(fiveHour: 0.50, week: 0.44)], now: minutes(50))
        try await store.record([measured(fiveHour: 0.52, week: 0.45)], now: minutes(60))
        let readings = try await store.fetchReadings(vendor: .claude, since: nil)
        let now = minutes(61)

        // The History timeline: every label of the subject.
        let timeline = HistoryPresentation.segments(from: HistoryPresentation.consumptionReadings(readings))
        for label in ["5H", "WK"] {
            let lines = timeline.filter { $0.barLabel == label }
            #expect(lines.map(\.points.count) == [4, 2], "\(label)")
        }

        // The inspector's history chart.
        let series = BurndownPresentation.history(
            readings: readings, instanceID: "claude", range: .last24Hours, now: now)
        #expect(series.filter { $0.label == "WK" }.map(\.points.count) == [4, 2])
        #expect(series.filter { $0.label == "5H" }.map(\.points.count) == [4, 2])

        // The History overview's sparkline, from the thinned read.
        let sampled = try await store.fetchSampledReadings(
            since: base.addingTimeInterval(-3_600), until: now, bucketSeconds: 120)
        let subjects = HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: [])
        let card = try #require(HistoryOverviewPresentation.overview(
            subjects: subjects, readings: sampled, bucketSeconds: 120).cards.first)
        #expect(card.barLabel == "WK")
        #expect(card.segments.map(\.points.count) == [4, 2])

        // The desktop widget's chart.
        let widget = AggregateBurndownPresentation.series(
            readings: readings, snapshots: [measured(fiveHour: 0.52, week: 0.45)],
            filters: WidgetFilters(), now: now,
            instanceName: { _ in nil }, instancePosition: { _ in nil })
        #expect(widget.first?.segments.map(\.points.count) == [4, 2])
    }

    @Test("a window filter still sees the provider's failed polls, and other windows stay apart")
    func windowFilterKeepsFailures() async throws {
        let store = makeStore()
        try await recordBurnThenOutage(store)
        try await store.record([measured(fiveHour: 0.50, week: 0.44)], now: minutes(50))
        let readings = try await store.fetchReadings(vendor: .claude, since: nil)

        let week = HistoryPresentation.segments(from: readings, barLabel: "WK")
        #expect(week.allSatisfy { $0.barLabel == "WK" })
        #expect(week.map(\.points.count) == [4, 1])
        // The provider's own label never becomes a line.
        #expect(HistoryPresentation.segments(from: readings)
            .allSatisfy { $0.barLabel != QuotaHistoryStore.providerPollLabel })
    }

    // MARK: - The carried-over figures of a failed poll

    /// Regression: `record` took the snapshot's status at face value, and
    /// retention had already replaced the failed poll's own status with the
    /// reading it was carrying over. A failed poll was therefore written as a
    /// fresh measurement of the old figures, stamped `now`: the timeline drew
    /// them straight across the outage as current, the inspector called them
    /// the provider's state now, and the burndown kept projecting from them.
    /// Proven red by removing the `staleReading` branch from
    /// `QuotaHistoryStore.record`.
    @Test("a failed poll records a failed poll, not the figures it carried over")
    func staleReadingRecordsAsFailedPoll() async throws {
        let store = makeStore()
        try await store.record([measured(fiveHour: 0.30, week: 0.40)], now: minutes(0))

        // Exactly what the manager hands over after a failed poll: the last
        // reading, still stamped with when it was measured, marked with the
        // failure. Its `status` stays `.measured` — see `StaleReading`.
        var carried = measured(fiveHour: 0.30, week: 0.40)
        carried.staleReading = StaleReading(reason: .offline, at: minutes(10))
        try await store.record([carried], now: minutes(10))

        let readings = try await store.fetchReadings(vendor: .claude, since: nil)
        // No window gained a row at +10m: those figures were measured at +0m
        // and that is where they stay.
        #expect(readings.filter { $0.barLabel == "5H" }.map(\.measuredAt) == [minutes(0)])
        #expect(readings.filter { $0.barLabel == "WK" }.map(\.measuredAt) == [minutes(0)])
        // The failure is one row of its own, under the provider's label, with
        // no figure — what breaks every window of this instance at that instant.
        #expect(readings.contains {
            $0.barLabel == QuotaHistoryStore.providerPollLabel
                && $0.measuredAt == minutes(10)
                && $0.fraction == nil
                && $0.confidence == .unavailable
        })

        let now = minutes(11)
        // Every surface that asks "what is the window now?" now sees the failure.
        #expect(HistoryPresentation.failedLatestPoll(readings: readings, instanceID: "claude") == minutes(10))
        #expect(HistoryPresentation.readingAtLatestPoll(readings: readings, barLabel: "5H") == nil)
        #expect(BurndownPresentation.burndown(
            readings: readings, instanceID: "claude", barLabel: "5H", now: now) == nil)
        #expect(BurndownPresentation.burndownAbsence(
            readings: readings, instanceID: "claude", barLabel: "5H", now: now) == .lastPollFailed)
        // The line stops at the failed poll rather than running across it.
        let line = try #require(HistoryPresentation.segments(
            from: HistoryPresentation.consumptionReadings(readings)).first { $0.barLabel == "5H" })
        #expect(line.points.map(\.timestamp) == [minutes(0)])

        // The inspector reaches the same conclusion from the snapshot alone —
        // reason included, and without waiting for the history read.
        let detail = MetricDetailPresentation(snapshot: carried, readings: readings, now: now)
        #expect(detail.summary.state == .lastPollFailed(at: minutes(10)))
        #expect(detail.summary.headline == "The last poll could not be read")
        #expect(detail.summary.remedy?.contains("Offline") == true)
        #expect(detail.summary.percentUsed == nil)
        #expect(detail.windowsAsOf == minutes(0))
        #expect(detail.windows.map(\.percentText) == ["40%", "30%"])
        #expect(detail.windows.allSatisfy { !$0.detail.contains("burning") && !$0.detail.contains("runs out") })
        #expect(detail.provenance.contains {
            $0.label == "Last poll" && $0.value?.contains("Offline") == true
        })

        // And once the provider answers again, the very next poll is current.
        try await store.record([measured(fiveHour: 0.50, week: 0.44)], now: minutes(20))
        let recovered = try await store.fetchReadings(vendor: .claude, since: nil)
        #expect(HistoryPresentation.failedLatestPoll(readings: recovered, instanceID: "claude") == nil)
        #expect(HistoryPresentation.readingAtLatestPoll(readings: recovered, barLabel: "5H")?.measuredAt == minutes(20))
    }

    // MARK: - The inspector's summary

    /// A healthy weekly window with a published pace, fetched at `fetched`.
    private func inspected(fetchedAt fetched: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.42, displayDetails: nil),
            status: .measured(.none), resetsAt: weekReset, lastUpdated: fetched, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.42, expectedPaceFraction: 0.30, label: "WK",
                                 resetsAt: weekReset, windowLength: 7 * 86_400))
    }

    /// Regression: the inspector's summary and windows read only the
    /// snapshot it was opened with, so a provider whose newer poll failed
    /// still led with a green "Healthy", "42% WK used" and a pace verdict,
    /// above a burndown saying the last poll could not be read. Proven red by
    /// returning nil from `MetricDetailPresentation.failedPollAfter`.
    @Test("a failed poll newer than the inspector's snapshot supersedes its summary")
    func newerFailureSupersedesInspectorSummary() async throws {
        let store = makeStore()
        let shown = inspected(fetchedAt: minutes(0))
        try await store.record([shown], now: minutes(0))
        let now = minutes(15)

        // Until something fails, the snapshot is the provider's state.
        let before = MetricDetailPresentation(
            snapshot: shown, readings: try await store.fetchReadings(vendor: .claude, since: nil), now: now)
        #expect(before.summary.state == .healthy)
        #expect(before.summary.paceVerdict != nil)
        #expect(before.windowsAsOf == nil)

        try await store.record([offline], now: minutes(5))
        let readings = try await store.fetchReadings(vendor: .claude, since: nil)
        let after = MetricDetailPresentation(snapshot: shown, readings: readings, now: now)
        #expect(after.summary.state == .lastPollFailed(at: minutes(5)))
        #expect(after.summary.headline == "The last poll could not be read")
        #expect(after.summary.percentUsed == nil)
        #expect(after.summary.resetText == nil)
        #expect(after.summary.paceVerdict == nil)
        #expect(after.summary.remedy?.contains("from \(MetricDetailPresentation.clockText(minutes(0), now: now))") == true)
        #expect(!after.summary.accessibilityLabel.contains("Healthy"))
        // The figures stay, named as of when they were fetched, with no
        // forecast drawn from them.
        #expect(after.windowsAsOf == minutes(0))
        #expect(after.windows.map(\.percentText) == ["42%"])
        #expect(after.windows.allSatisfy { !$0.detail.contains("burning") && !$0.detail.contains("runs out") })
        #expect(after.provenance.contains { $0.label == "Last poll" && $0.value?.hasPrefix("Could not be read") == true })
        // The burndown under it says the same thing.
        #expect(BurndownPresentation.burndownAbsence(
            readings: readings, instanceID: "claude", barLabel: "WK", now: now) == .lastPollFailed)
    }

    @Test("a snapshot newer than the recorded failure is the provider's state")
    func newerSnapshotOutranksOlderFailure() async throws {
        let store = makeStore()
        try await store.record([offline], now: minutes(5))
        let now = minutes(15)

        // Fetched after the failure, and not recorded yet.
        let unrecorded = inspected(fetchedAt: minutes(6))
        let live = MetricDetailPresentation(
            snapshot: unrecorded, readings: try await store.fetchReadings(vendor: .claude, since: nil), now: now)
        #expect(live.summary.state == .healthy)
        #expect(live.summary.percentUsed == 42)
        #expect(live.summary.paceVerdict != nil)
        #expect(live.windowsAsOf == nil)
        #expect(!live.provenance.contains { $0.label == "Last poll" })

        // Fetched after the failure, and recorded.
        let recorded = inspected(fetchedAt: minutes(10))
        try await store.record([recorded], now: minutes(10))
        let stands = MetricDetailPresentation(
            snapshot: recorded, readings: try await store.fetchReadings(vendor: .claude, since: nil), now: now)
        #expect(stands.summary.state == .healthy)
        #expect(stands.windowsAsOf == nil)
    }

    // MARK: - The overview's thinned read

    private func week(_ used: Double?) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: used ?? 0, displayDetails: nil),
            status: .measured(.none), resetsAt: weekReset, lastUpdated: base, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: used, label: "WK",
                                 resetsAt: weekReset, windowLength: 7 * 86_400))
    }

    /// The overview card's line breaks, from the full read and the thinned
    /// one, for every range the History window offers.
    private func overviewBreaks(
        record: (QuotaHistoryStore, Date) async throws -> Void
    ) async throws -> [(range: HistoryPresentation.TimeRange, full: [[Date]], sampled: [[Date]])] {
        let subjects = HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: [])
        var results: [(HistoryPresentation.TimeRange, [[Date]], [[Date]])] = []
        for range in HistoryPresentation.TimeRange.allCases {
            let store = makeStore()
            let bucket = HistoryOverviewPresentation.sampleBucketSeconds(
                range: range, retention: await store.retentionInterval)
            // A bucket boundary, so every failure below shares one bucket.
            let boundary = Date(timeIntervalSince1970:
                (base.timeIntervalSince1970 / Double(bucket)).rounded(.up) * Double(bucket))
            try await record(store, boundary)
            let until = boundary.addingTimeInterval(600)
            let full = try await store.fetchReadings(vendor: .claude, since: nil)
            let sampled = try await store.fetchSampledReadings(
                since: nil, until: until, bucketSeconds: bucket)
            func lines(_ readings: [QuotaHistoryStore.ReadingRecord]) throws -> [[Date]] {
                let card = try #require(HistoryOverviewPresentation.overview(
                    subjects: subjects, readings: readings, bucketSeconds: bucket).cards.first)
                return card.segments.map { $0.points.map(\.timestamp) }
            }
            results.append((range, try lines(full), try lines(sampled)))
        }
        return results
    }

    /// Regression: the thinned read kept only the latest row per window and
    /// bucket, so a WK poll without a figure followed by a recovered one in
    /// the same bucket was dropped, and the sparkline ran across the outage
    /// the full read broke. Proven red by removing the two failure SELECTs
    /// from `fetchSampledReadings`.
    @Test("a window's failed poll survives thinning when the window recovers in the same bucket")
    func sampledKeepsWindowFailure() async throws {
        let results = try await overviewBreaks { store, boundary in
            try await store.record([week(0.40)], now: boundary.addingTimeInterval(-300))
            try await store.record([week(nil)], now: boundary.addingTimeInterval(60))
            try await store.record([week(0.50)], now: boundary.addingTimeInterval(120))
        }
        for (range, full, sampled) in results {
            #expect(full.count == 2, "\(range)")
            #expect(sampled == full, "\(range)")
        }
    }

    /// Regression: a failed poll is stored under `DEFAULT`, and with two in
    /// one bucket only the later survived thinning, so the earlier outage —
    /// the one between two WK readings — no longer broke the line. Proven
    /// red by removing the `MIN` failure SELECT from `fetchSampledReadings`.
    @Test("the earlier of two failed provider polls in a bucket still breaks the sparkline")
    func sampledKeepsEarlierProviderFailure() async throws {
        let results = try await overviewBreaks { store, boundary in
            try await store.record([week(0.40)], now: boundary.addingTimeInterval(-300))
            try await store.record([offline], now: boundary.addingTimeInterval(60))
            try await store.record([week(0.50)], now: boundary.addingTimeInterval(120))
            try await store.record([offline], now: boundary.addingTimeInterval(180))
        }
        for (range, full, sampled) in results {
            #expect(full.count == 2, "\(range)")
            #expect(sampled == full, "\(range)")
        }
    }

    // MARK: - Why a chart is empty

    @Test("a blocked window polled without a figure says so, in both chart modes")
    func blockedWithoutFigure() async throws {
        let store = makeStore()
        let blocked = QuotaSnapshot(
            id: "opencode", vendorId: .opencode, displayName: "OpenCode Go", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0, displayDetails: nil),
            status: .measured(.critical), resetsAt: weekReset, lastUpdated: base, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: nil, label: "WK", isBlocked: true,
                                 resetsAt: weekReset, windowLength: 7 * 86_400))
        try await store.record([blocked], now: base)
        let readings = try await store.fetchReadings(vendor: .opencode, since: nil)
        let now = minutes(1)

        #expect(BurndownPresentation.burndown(
            readings: readings, instanceID: "opencode", barLabel: "WK", now: now) == nil)
        let burndownAbsence = BurndownPresentation.burndownAbsence(
            readings: readings, instanceID: "opencode", barLabel: "WK", now: now)
        #expect(burndownAbsence == .noFigureAtLastPoll(label: "WK", isBlocked: true))
        #expect(burndownAbsence.symbol == BlockedGlyph.symbolName)
        #expect(!burndownAbsence.message.contains("No readings"))

        let historyAbsence = BurndownPresentation.historyAbsence(
            readings: readings, instanceID: "opencode", range: .last24Hours, now: now)
        #expect(historyAbsence == .polledWithoutFigures(pollCount: 1, lastPollFailed: false))
        #expect(historyAbsence.message == "Polled once in this range, but no poll reported a usage figure to chart.")
    }

    @Test("no readings, readings outside the range, failed polls and an expired window are told apart")
    func absencesAreDistinct() async throws {
        let store = makeStore()
        #expect(BurndownPresentation.burndownAbsence(
            readings: [], instanceID: "claude", barLabel: "5H", now: base) == .noReadings)
        #expect(BurndownPresentation.historyAbsence(
            readings: [], instanceID: "claude", range: .last24Hours, now: base) == .noReadings)

        // Only failed polls.
        try await store.record([offline], now: base)
        try await store.record([offline], now: minutes(10))
        var readings = try await store.fetchReadings(vendor: .claude, since: nil)
        #expect(BurndownPresentation.burndownAbsence(
            readings: readings, instanceID: "claude", barLabel: "5H", now: minutes(11)) == .lastPollFailed)
        let failed = BurndownPresentation.historyAbsence(
            readings: readings, instanceID: "claude", range: .last24Hours, now: minutes(11))
        #expect(failed == .polledWithoutFigures(pollCount: 2, lastPollFailed: true))
        #expect(failed.message.hasSuffix("The last poll could not be read."))
        #expect(failed.symbol == "exclamationmark.triangle")

        // Two days later, nothing inside a 24-hour range.
        let later = base.addingTimeInterval(2 * 86_400)
        #expect(BurndownPresentation.historyAbsence(
            readings: readings, instanceID: "claude", range: .last24Hours, now: later) == .noneInRange)

        // A measured reading whose 5H reset has since passed.
        try await store.record([measured(fiveHour: 0.30, week: 0.40)], now: minutes(20))
        readings = try await store.fetchReadings(vendor: .claude, since: nil)
        let afterReset = fiveHourReset.addingTimeInterval(60)
        #expect(BurndownPresentation.burndown(
            readings: readings, instanceID: "claude", barLabel: "5H", now: afterReset) == nil)
        #expect(BurndownPresentation.burndownAbsence(
            readings: readings, instanceID: "claude", barLabel: "5H", now: afterReset) == .windowExpired(label: "5H"))
    }

    // MARK: - Readout

    /// Regression: the readout drew the chart's square beside a blocked
    /// figure. Proven red by returning `symbol(isBlocked:urgency:)` from
    /// `figureSymbol` unchanged.
    @Test("the chart readout puts the shared blocked glyph beside a blocked figure")
    func readoutBlockedGlyph() {
        #expect(ReadingReadout.figureSymbol(isBlocked: true, urgency: .warning) == BlockedGlyph.symbolName)
        #expect(ReadingReadout.figureSymbol(isBlocked: false, urgency: .warning) == "diamond.fill")
        // The chart's point shape is unchanged.
        #expect(ReadingReadout.symbol(isBlocked: true, urgency: .warning) == "square.fill")
    }
}
