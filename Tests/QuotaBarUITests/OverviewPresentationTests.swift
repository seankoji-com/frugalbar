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
        // Tokens is the default layout; anything unreadable or unset gets it.
        #expect(WidgetFilters.decode(Data(#"{"layout":"bogus"}"#.utf8)).layout == .tokens)
        #expect(WidgetFilters.decode(Data("{}".utf8)).layout == .tokens)
        #expect(WidgetFilters().layout == .tokens)
        // A layout the user chose survives the change of default.
        for layout in WidgetFilters.Layout.allCases {
            let stored = Data(#"{"layout":"\#(layout.rawValue)"}"#.utf8)
            #expect(WidgetFilters.decode(stored).layout == layout)
        }
        let filters = WidgetFilters(layout: .overview)
        #expect(WidgetFilters.decode(filters.encoded()) == filters)
        #expect(AggregateBurndownPresentation.title(for: filters) == "All subscriptions · overview · remaining")
    }

    /// Inverting a cycle for "remaining" would read as quota left.
    @Test("a billing cycle stays in elapsed terms whatever the metric")
    func cycleIgnoresMetric() {
        var cycle = DualBarMetrics(primaryFraction: 0.9, label: "CYCLE", windowLength: 30 * 86_400)
        cycle.measuresElapsedTimeOnly = true
        for metric in [WidgetFilters.Metric.used, .remaining] {
            let tile = O.tiles(snapshots: [snapshot(.devpass, bars: [cycle])], filters: WidgetFilters(metric: metric))[0]
            #expect(tile.windows[0].fraction == 0.9)
            #expect(O.accessibilityLabel(for: tile, metric: metric, now: now).contains("90 percent elapsed"))
            #expect(!O.accessibilityLabel(for: tile, metric: metric, now: now).contains("left"))
        }
    }

    @Test("quota pressure is spoken, not only coloured")
    func urgencySpoken() {
        let warn = O.tiles(snapshots: [snapshot(.claude, status: .warning, bars: [wk(0.8)])], filters: WidgetFilters())[0]
        let crit = O.tiles(snapshots: [snapshot(.claude, status: .critical, bars: [wk(0.95)])], filters: WidgetFilters())[0]
        #expect(O.accessibilityLabel(for: warn, metric: .remaining, now: now).hasSuffix("running low"))
        #expect(O.accessibilityLabel(for: crit, metric: .remaining, now: now).hasSuffix("critically low"))
    }

    @Test("a window the vendor blocked but still measured is spoken as blocked")
    func blockedMeasuredSpoken() {
        let blocked = DualBarMetrics(primaryFraction: 0.9, label: "WK", blockedColor: "#ffb4ab", isBlocked: true, windowLength: QuotaWindow.week)
        let tile = O.tiles(snapshots: [snapshot(.opencode, status: .critical, bars: [blocked])], filters: WidgetFilters())[0]
        let text = O.accessibilityLabel(for: tile, metric: .remaining, now: now)
        #expect(text.contains("weekly 10 percent remaining, blocked"))
    }

    @Test("only a blocked window that still reports a figure gets the glyph")
    func overviewGlyph() {
        func tile(_ bar: DualBarMetrics) -> O.WindowCell {
            O.tiles(snapshots: [snapshot(.opencode, status: .critical, bars: [bar])], filters: WidgetFilters())[0].windows[0]
        }
        #expect(tile(DualBarMetrics(primaryFraction: 0.9, label: "WK", blockedColor: "#ffb4ab", isBlocked: true)).showsBlockedGlyph)
        #expect(!tile(DualBarMetrics(primaryFraction: nil, label: "WK", isBlocked: true)).showsBlockedGlyph)
        #expect(!tile(DualBarMetrics(primaryFraction: 0.9, label: "WK")).showsBlockedGlyph)
    }

    // MARK: Exhausted vs blocked, and the tooltip

    private func firstTile(_ s: QuotaSnapshot) -> O.Tile {
        O.tiles(snapshots: [s], filters: WidgetFilters())[0]
    }

    /// The popover does not strike the logo of a window that is merely
    /// blocked; the Overview must not call it exhausted either.
    @Test("a blocked window that still reports a figure is blocked, not exhausted")
    func blockedIsNotExhausted() {
        let blocked = DualBarMetrics(primaryFraction: 0.4, label: "WK", blockedColor: "#ffb4ab", isBlocked: true, windowLength: QuotaWindow.week)
        let tile = firstTile(snapshot(.opencode, status: .critical, bars: [blocked]))
        #expect(!tile.isExhausted)
        #expect(!O.accessibilityLabel(for: tile, metric: .remaining, now: now).contains("exhausted"))
    }

    @Test("a spent window, or an account cut off with no figures, is exhausted")
    func spentIsExhausted() {
        let spent = firstTile(snapshot(.claude, status: .critical, bars: [DualBarMetrics(primaryFraction: 1.0, label: "WK", windowLength: QuotaWindow.week)]))
        #expect(spent.isExhausted)
        let cutOff = firstTile(snapshot(.opencode, status: .critical, bars: [DualBarMetrics(primaryFraction: nil, label: "WK", isBlocked: true, windowLength: QuotaWindow.week)]))
        #expect(cutOff.isExhausted)
    }

    @Test("the window tooltip says blocked, then when it resets")
    func tooltip() {
        func cell(_ bar: DualBarMetrics) -> O.WindowCell { firstTile(snapshot(.opencode, status: .critical, bars: [bar])).windows[0] }
        let reset = now.addingTimeInterval(3 * 3600)
        let blocked = cell(DualBarMetrics(primaryFraction: 0.9, label: "WK", blockedColor: "#ffb4ab", isBlocked: true, resetsAt: reset, windowLength: QuotaWindow.week))
        #expect(O.helpText(for: blocked, now: now) == "WK is blocked. Resets in 3h 0m")
        let open = cell(DualBarMetrics(primaryFraction: 0.9, label: "WK", resetsAt: reset, windowLength: QuotaWindow.week))
        #expect(O.helpText(for: open, now: now) == "Resets in 3h 0m")
        var cycle = DualBarMetrics(primaryFraction: 0.5, label: "CYCLE", resetsAt: reset, windowLength: 30 * 86_400)
        cycle.measuresElapsedTimeOnly = true
        #expect(O.helpText(for: cell(cycle), now: now) == "CYCLE: billing cycle, elapsed time only")
    }
}
