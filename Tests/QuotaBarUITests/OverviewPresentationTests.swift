import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

@Suite("OverviewPresentation")
struct OverviewPresentationTests {

    typealias O = OverviewPresentation
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ vendor: VendorIdentifier,
        status: ProviderStatus = .healthy,
        bars: [DualBarMetrics] = [],
        plan: String? = nil
    ) -> QuotaSnapshot {
        var s = QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0, displayDetails: nil),
            status: status, resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bars.indices.contains(0) ? bars[0] : nil,
            row2: bars.indices.contains(1) ? bars[1] : nil,
            row3: bars.indices.contains(2) ? bars[2] : nil)
        s.planName = plan
        return s
    }

    private func wk(_ used: Double?, blocked: Bool = false) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: used, label: "WK", isBlocked: blocked, windowLength: QuotaWindow.week)
    }

    @Test("a provider that is not configured gets no tile")
    func notConfiguredSkipped() {
        let tiles = O.tiles(snapshots: [
            snapshot(.claude, bars: [wk(0.2)]),
            snapshot(.grok, status: .unavailable(.notConfigured)),
        ], filters: WidgetFilters(layout: .overview))
        #expect(tiles.map(\.vendorId) == [.claude])
    }

    /// Failure must never render as health: an unreadable provider keeps its
    /// tile, says why, and carries no window to draw as full.
    @Test("an unreadable provider keeps its tile and says why")
    func unreadableKept() {
        let tiles = O.tiles(snapshots: [
            snapshot(.claude, status: .unavailable(.credentialRejected), bars: [wk(0.2)]),
        ], filters: WidgetFilters(layout: .overview))
        #expect(tiles.count == 1)
        #expect(tiles[0].unavailableHeadline == "Credential rejected")
        #expect(tiles[0].windows.isEmpty)
    }

    @Test("store order is preserved and the vendor filter applies")
    func orderAndFilter() {
        let snaps = [snapshot(.kiro, bars: [wk(0.1)]), snapshot(.claude, bars: [wk(0.1)]), snapshot(.grok, bars: [wk(0.1)])]
        #expect(O.tiles(snapshots: snaps, filters: WidgetFilters()).map(\.vendorId) == [.kiro, .claude, .grok])
        #expect(O.tiles(snapshots: snaps, filters: WidgetFilters(vendors: [.grok, .kiro])).map(\.vendorId) == [.kiro, .grok])
    }

    @Test("the metric converts used to remaining, and nil stays nil")
    func metricAndNil() {
        let snaps = [snapshot(.claude, bars: [wk(0.25)]), snapshot(.opencode, status: .critical, bars: [wk(nil, blocked: true)])]
        let remaining = O.tiles(snapshots: snaps, filters: WidgetFilters(metric: .remaining))
        let used = O.tiles(snapshots: snaps, filters: WidgetFilters(metric: .used))
        #expect(remaining[0].windows[0].fraction == 0.75)
        #expect(used[0].windows[0].fraction == 0.25)
        #expect(remaining[1].windows[0].fraction == nil)
        #expect(remaining[1].windows[0].isBlocked)
    }

    @Test("a hand-entered cycle is flagged as elapsed time, not usage")
    func cycleFlagged() {
        var cycle = DualBarMetrics(primaryFraction: 0.9, label: "CYCLE", windowLength: 30 * 86_400)
        cycle.measuresElapsedTimeOnly = true
        let tile = O.tiles(snapshots: [snapshot(.devpass, bars: [wk(0.1), cycle])], filters: WidgetFilters(metric: .used))[0]
        #expect(tile.windows.first { $0.label == "CYCLE" }?.measuresElapsedTimeOnly == true)
        let spoken = O.accessibilityLabel(for: tile, metric: .used, now: now)
        #expect(spoken.contains("CYCLE cycle 90 percent elapsed"))
    }

    @Test("the spoken label carries every figure and never invents one")
    func spoken() {
        let tile = O.tiles(snapshots: [
            snapshot(.claude, bars: [wk(0.4), DualBarMetrics(primaryFraction: nil, label: "5H", isBlocked: true, windowLength: QuotaWindow.fiveHours)], plan: "Max (5x)"),
        ], filters: WidgetFilters())[0]
        let text = O.accessibilityLabel(for: tile, metric: .remaining, now: now)
        #expect(text.hasPrefix("Claude, Max (5x)"))
        #expect(text.contains("weekly 60 percent remaining"))
        #expect(text.contains("5-hour blocked"))
    }

    @Test("layout decodes tolerantly, round-trips, and shows in the title")
    func layoutCoding() throws {
        #expect(WidgetFilters.decode(Data(#"{"layout":"bogus"}"#.utf8)).layout == .chart)
        #expect(WidgetFilters.decode(Data("{}".utf8)).layout == .chart)
        let filters = WidgetFilters(layout: .overview)
        #expect(WidgetFilters.decode(filters.encoded()) == filters)
        #expect(AggregateBurndownPresentation.title(for: filters) == "All subscriptions · overview · remaining")
    }
}
