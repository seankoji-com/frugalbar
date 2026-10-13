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
