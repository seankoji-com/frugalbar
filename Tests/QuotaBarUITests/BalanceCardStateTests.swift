import Foundation
import Testing
@testable import QuotaBarUI
import QuotaBarCore

/// The inspector's balance card decides two things that this feature exists to
/// keep apart, and both were wrong in a way no render could catch:
///
/// * whether the card is drawn at all — gating it on the *successful* reads made
///   a failed read vanish as "this provider publishes no balance", and left the
///   card's own failure branch unreachable; and
/// * what it says about the series it does draw — a read that came back with no
///   readings is an absence, a read that failed is a failure.
///
/// Both are pure and asserted here rather than only visible on screen.
@Suite("Balance card state")
struct BalanceCardStateTests {

    private func snapshot(
        credits: Bool,
        metric: MetricType = .currency(balance: 12.5, limit: nil, spent: nil, currencyCode: "USD")
    ) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(
            id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .apiSpendAndCredits, metric: metric,
            status: .measured(.none), resetsAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0), auxiliaryInfo: nil,
            row1: nil, row2: nil
        )
        if credits {
            snapshot.apiCredits = [APICreditEntry(
                id: "openai:credits", vendorId: .openai, label: "API credits",
                metric: .credits(remaining: 250, unitName: "credits"),
                detail: nil, source: "test payload"
            )]
        }
        return snapshot
    }

    private func read(points: [BalancePoint]?) -> MetricDetailModalView.BalanceSeriesRead {
        let series = BalanceSeries.all(of: snapshot(credits: true))[0]
        return MetricDetailModalView.BalanceSeriesRead(series: series, points: points)
    }

    /// The card is drawn for a snapshot that *publishes* a series, never for one
    /// whose read happened to succeed. A quota-only provider has no line to
    /// show; a provider that publishes one and could not be read still does.
    @Test("the card follows the published series, not the read's success")
    func cardFollowsThePublishedSeries() {
        #expect(MetricDetailModalView.showsBalanceCard(for: snapshot(credits: true)))
        // The snapshot's own metric is a balance figure, so it publishes one.
        #expect(MetricDetailModalView.showsBalanceCard(for: snapshot(credits: false)))
        // A quota-only provider publishes none: no card, so no empty chart
        // reading as "your balance is zero".
        #expect(!MetricDetailModalView.showsBalanceCard(
            for: snapshot(credits: false, metric: .percentage(usedFraction: 0.4, displayDetails: nil))))
    }

    /// The regression itself: a failed read was folded into "no series", so the
    /// card disappeared and this branch could never be reached.
    @Test("a read that failed says so, and is not an absence of readings")
    func failedReadIsItsOwnState() {
        let state = MetricDetailModalView.BalanceCardState.of(
            isLoading: false, read: read(points: nil))
        #expect(state == .readFailed)
        #expect(state != .noTrend(readings: 0))
    }

    /// An answered read that held nothing in the window is the absence, and it
    /// is worded from the count rather than from a zero balance.
    @Test("an answered read with no points is an absence, not a failure")
    func emptyAnswerIsAnAbsence() {
        #expect(MetricDetailModalView.BalanceCardState.of(
            isLoading: false, read: read(points: [])) == .noTrend(readings: 0))
    }

    /// One reading is a figure, not a trend: a line through a single point
    /// would be a fabricated direction.
    @Test("one reading is an absence of a trend, two are a trend")
    func oneReadingIsNoTrend() {
        let only = [BalancePoint(measuredAt: Date(timeIntervalSince1970: 0), value: 12.5)]
        #expect(MetricDetailModalView.BalanceCardState.of(
            isLoading: false, read: read(points: only)) == .noTrend(readings: 1))

        let two = only + [BalancePoint(measuredAt: Date(timeIntervalSince1970: 3600), value: 15)]
        guard case .trend = MetricDetailModalView.BalanceCardState.of(
            isLoading: false, read: read(points: two)) else {
            Issue.record("two readings are a trend")
            return
        }
    }

    /// Loading outranks whatever the last pass left behind, and a selection the
    /// current pass has not recorded yet is not a failure either.
    @Test("loading and an unrecorded series are their own states")
    func loadingAndUnrecordedAreDistinct() {
        #expect(MetricDetailModalView.BalanceCardState.of(
            isLoading: true, read: read(points: nil)) == .loading)
        #expect(MetricDetailModalView.BalanceCardState.of(isLoading: false, read: nil) == .awaitingRead)
    }

    // MARK: - The pass that records them

    /// The other half of the shipped defect, and the half a gate test cannot
    /// catch: the failed reads were not merely hidden, they were never
    /// recorded, so there was no series left to draw and no selection to make.
    /// A failed read is kept, with `points` nil, for every published series.
    @Test("a failed read is still recorded, once per published series")
    func failedReadsAreStillRecorded() async {
        let published = BalanceSeries.all(of: snapshot(credits: true))
        #expect(published.count > 1)

        let reads = await MetricDetailModalView.balanceReads(for: snapshot(credits: true)) { _ in nil }
        #expect(reads.map(\.series.id) == published.map(\.id))
        #expect(reads.allSatisfy { $0.points == nil })

        // The snapshot's own figure and the credit entry each keep their own
        // outcome, so one failed pool cannot mark its neighbour unreadable.
        let mixed = await MetricDetailModalView.balanceReads(for: snapshot(credits: true)) { series in
            series.id == published[0].id ? [] : nil
        }
        let own = mixed.first { $0.series.id == published[0].id }
        let credit = mixed.first { $0.series.id == published[1].id }
        #expect(own?.points ?? nil == [])
        #expect(credit?.points ?? nil == nil)
    }

    /// A non-throwing `await` does not stop on cancellation, so a pass with no
    /// bail of its own would run every remaining read to completion and throw
    /// the lot away when the modal closed.
    @Test("a cancelled pass records nothing, rather than a partial history")
    func cancelledPassRecordsNothing() async {
        let snapshot = snapshot(credits: true)
        #expect(BalanceSeries.all(of: snapshot).count > 1)

        let task = Task {
            await MetricDetailModalView.balanceReads(for: snapshot) { _ in
                try? await Task.sleep(nanoseconds: 50_000_000)
                return []
            }
        }
        // Cancel while the first read is in flight, so the bail is what the
        // result turns on rather than whether the loop had started.
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let reads = await task.value
        #expect(reads.isEmpty)
    }
}
