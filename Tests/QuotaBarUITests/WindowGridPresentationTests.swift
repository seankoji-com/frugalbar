import Testing
import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Window grid")
struct WindowGridPresentationTests {

    private func bar(_ label: String, _ used: Double?, blocked: Bool = false, length: TimeInterval? = nil) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: used, label: label, isBlocked: blocked, windowLength: length)
    }

    private func snap(_ rows: [DualBarMetrics]) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "x", vendorId: .kiro, displayName: "Kiro", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .measured(.none),
            resetsAt: nil, lastUpdated: Date(timeIntervalSince1970: 0), auxiliaryInfo: nil,
            row1: rows.count > 0 ? rows[0] : nil, row2: rows.count > 1 ? rows[1] : nil,
            row3: rows.count > 2 ? rows[2] : nil)
    }

    @Test("bars go in the column their token names, whatever order the provider gave them")
    func placesByToken() {
        let grid = WindowGridPresentation(snapshot: snap([bar("MO", 0.5), bar("5H", 0.1), bar("WK", 0.3)]))
        #expect(grid.bars[.fiveHour]?.primaryFraction == 0.1)
        #expect(grid.bars[.weekly]?.primaryFraction == 0.3)
        #expect(grid.bars[.monthly]?.primaryFraction == 0.5)
        #expect(grid.extras.isEmpty)
        #expect(grid.usesGrid)
    }

    @Test("pools that are not windows go on their own lines, in order")
    func extrasKeepOrder() {
        let grid = WindowGridPresentation(snapshot: snap([bar("MO", 0.3), bar("BN", 0.5), bar("OV", 0.0)]))
        #expect(grid.bars.keys.sorted { $0.rawValue < $1.rawValue } == [.monthly])
        #expect(grid.extras.map(\.label) == ["BN", "OV"])
        // Pools that are not windows are spoken too, by their token.
        #expect(grid.spokenSummary() == "monthly 30% used, BN 50% used, OV 0% used")
    }

    @Test("a missing window leaves its column empty rather than drawing 0%")
    func missingColumnEmpty() {
        let grid = WindowGridPresentation(snapshot: snap([bar("WK", 0.4)]))
        #expect(grid.bars[.fiveHour] == nil)
        #expect(grid.bars[.monthly] == nil)
        #expect(grid.spokenSummary() == "weekly 40% used")
    }

    /// The exhausted-window collapse still applies: a spent monthly window
    /// leaves the shorter windows' cells empty.
    @Test("a spent longer window empties the shorter windows' cells")
    func collapseRespected() {
        let grid = WindowGridPresentation(snapshot: snap([
            bar("5H", 0.1, length: 5 * 3600), bar("WK", 0.2, length: 7 * 86_400), bar("MO", 1.0, length: 30 * 86_400),
        ]))
        #expect(grid.bars[.fiveHour] == nil)
        #expect(grid.bars[.weekly] == nil)
        #expect(grid.bars[.monthly]?.primaryFraction == 1.0)
    }

    @Test("an unmeasured cell says blocked or shows a dash, never 0%")
    func unmeasuredText() {
        #expect(WindowGridPresentation.percentText(for: bar("5H", nil, blocked: true)) == nil)
        #expect(WindowGridPresentation.unmeasuredText(for: bar("5H", nil, blocked: true)) == "Blocked")
        #expect(WindowGridPresentation.unmeasuredText(for: bar("5H", nil)) == "—")
        #expect(WindowGridPresentation.percentText(for: bar("5H", 0.425)) == "43%")
        #expect(WindowGridPresentation.percentText(for: bar("5H", 0)) == "0%")
        let grid = WindowGridPresentation(snapshot: snap([bar("5H", nil, blocked: true), bar("WK", nil)]))
        #expect(grid.spokenSummary() == "5-hour blocked, weekly no reading")
    }

    @Test("spend windows fill the matching columns as text when there are no bars")
    func spendColumns() {
        var s = QuotaSnapshot(
            id: "openrouter", vendorId: .openrouter, displayName: "OpenRouter", category: .apiSpendAndCredits,
            metric: .currency(balance: 10, limit: nil, spent: nil, currencyCode: "USD"),
            status: .measured(.none), resetsAt: nil, lastUpdated: Date(timeIntervalSince1970: 0), auxiliaryInfo: nil)
        s.spendWindows = [SpendWindow(label: "MO", amount: 12.4, currencyCode: "USD"),
                          SpendWindow(label: "WK", amount: nil, currencyCode: "USD")]
        let grid = WindowGridPresentation(snapshot: s)
        #expect(grid.usesGrid)
        #expect(grid.spend[.monthly]?.amount == 12.4)
        #expect(grid.spend[.weekly] != nil)
        #expect(grid.spend[.weekly]?.amount == nil)
        #expect(grid.spend[.fiveHour] == nil)
        // VoiceOver hears the same figures the cells show.
        let spoken = grid.spokenSummary() ?? ""
        #expect(spoken.hasPrefix("weekly spend not reported, monthly spend "))
        #expect(spoken.contains("12.40"))
    }

    /// The headline "42 percent used" and the grid's "5-hour 42% used" are
    /// the same figure; with a grid the headline is dropped, a plan name is not.
    @Test("a row with a grid speaks each percentage once")
    func percentageNotSpokenTwice() {
        let pct = QuotaSnapshot(
            id: "c", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.42, displayDetails: nil), status: .measured(.none),
            resetsAt: nil, lastUpdated: Date(timeIntervalSince1970: 0), auxiliaryInfo: nil,
            row1: bar("5H", 0.42))
        let p = MetricRowPresentation(snapshot: pct)
        #expect(p.accessibilityLabel.contains("42 percent used"))
        #expect(!p.accessibilityLabelOmittingPercentage.contains("42 percent used"))
        #expect(p.accessibilityLabelOmittingPercentage.hasPrefix("Claude"))

        let plan = snap([bar("MO", 0.3)])
        let q = MetricRowPresentation(snapshot: plan)
        #expect(q.accessibilityLabelOmittingPercentage == q.accessibilityLabel)
    }

    @Test("a row with no bars and no spend keeps the chip layout")
    func noGrid() {
        #expect(!WindowGridPresentation(snapshot: snap([])).usesGrid)
    }

    @Test("column tokens match the providers' standard labels")
    func tokens() {
        #expect(WindowColumn.allCases.map(\.label) == ["5H", "WK", "MO"])
        #expect(WindowColumn.column(forLabel: "mo") == .monthly)
        for other in ["CR", "BN", "OV", "OD", "SP", "1D", "PLAN", "CYCLE", "REST"] {
            #expect(WindowColumn.column(forLabel: other) == nil)
        }
    }
}

/// The reset time under each bar is on screen, so it has to be spoken.
@Suite("WindowGridPresentation — spoken reset times")
struct WindowGridSpokenResetTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func bar(_ label: String, _ used: Double?, resetsIn seconds: TimeInterval?, blocked: Bool = false) -> DualBarMetrics {
        DualBarMetrics(
            primaryFraction: used, label: label, isBlocked: blocked,
            resetsAt: seconds.map { now.addingTimeInterval($0) })
    }

    private func grid(_ bars: [DualBarMetrics]) -> WindowGridPresentation {
        WindowGridPresentation(snapshot: QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0, displayDetails: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bars.indices.contains(0) ? bars[0] : nil,
            row2: bars.indices.contains(1) ? bars[1] : nil,
            row3: bars.indices.contains(2) ? bars[2] : nil))
    }

    @Test("each window speaks its reset beside its figure")
    func resetsAreSpoken() {
        let g = grid([bar("5H", 0.06, resetsIn: 3 * 3600), bar("WK", 0.11, resetsIn: 6 * 86_400)])
        #expect(g.spokenSummary(now: now)
                == "5-hour 6% used, resets in 3 hours, weekly 11% used, resets in 6 days")
    }

    @Test("singular units, minutes and now are spoken correctly")
    func units() {
        #expect(grid([bar("5H", 0.1, resetsIn: 60)]).spokenSummary(now: now) == "5-hour 10% used, resets in 1 minute")
        #expect(grid([bar("5H", 0.1, resetsIn: 45 * 60)]).spokenSummary(now: now) == "5-hour 10% used, resets in 45 minutes")
        #expect(grid([bar("WK", 0.1, resetsIn: 86_400)]).spokenSummary(now: now) == "weekly 10% used, resets in 1 day")
        #expect(grid([bar("WK", 0.1, resetsIn: -30)]).spokenSummary(now: now) == "weekly 10% used, resets now")
    }

    /// The spoken figure is the visible one: both come from `compactReset`.
    @Test("the spoken reset matches the compact text on screen")
    func matchesVisibleText() {
        for seconds in [20.0, 45 * 60, 3 * 3600, 23.6 * 3600, 6.2 * 86_400] as [TimeInterval] {
            let date = now.addingTimeInterval(seconds)
            let visible = ResetCountdownBadge.compact(date, now: now) ?? ""
            let spoken = ResetCountdownBadge.compactSpoken(date, now: now) ?? ""
            let digits = visible.filter(\.isNumber)
            #expect(spoken.contains(digits), "visible \(visible) vs spoken \(spoken)")
        }
    }

    @Test("a window with no published reset speaks none, and a blocked one still does")
    func absentAndBlocked() {
        #expect(grid([bar("WK", 0.4, resetsIn: nil)]).spokenSummary(now: now) == "weekly 40% used")
        #expect(grid([bar("5H", nil, resetsIn: 2 * 3600, blocked: true)]).spokenSummary(now: now)
                == "5-hour blocked, resets in 2 hours")
    }

    @Test("non-window pools show no reset text, so they speak none")
    func extrasSpeakNoReset() {
        let g = grid([bar("MO", 0.3, resetsIn: 86_400), bar("BN", 0.5, resetsIn: 5 * 86_400)])
        #expect(g.spokenSummary(now: now) == "monthly 30% used, resets in 1 day, BN 50% used")
    }

    // MARK: Pace, the amber fill in words

    /// A pace the vendor published: it comes with the reset and the window
    /// length it is measured against.
    private func paced(_ used: Double, pace: Double?) -> DualBarMetrics {
        DualBarMetrics(
            primaryFraction: used, expectedPaceFraction: pace, label: "WK",
            resetsAt: now.addingTimeInterval(86_400), windowLength: QuotaWindow.week)
    }

    /// Amber is colour alone; WCAG 1.4.1 wants the same fact in words.
    @Test("a window meaningfully ahead of an even pace says so")
    func aheadIsSpoken() {
        #expect(grid([paced(0.30, pace: 0.10)]).spokenSummary(now: now)
                == "weekly 30% used, ahead of an even pace, resets in 1 day")
    }

    @Test("a window at or near pace, or with no pace published, says nothing about pace")
    func notAheadIsSilent() {
        #expect(grid([paced(0.12, pace: 0.10)]).spokenSummary(now: now) == "weekly 12% used, resets in 1 day")
        #expect(grid([paced(0.30, pace: nil)]).spokenSummary(now: now) == "weekly 30% used, resets in 1 day")
    }

    @Test("a spent window is not described as ahead of pace")
    func spentIsSilent() {
        #expect(grid([paced(1.0, pace: 0.10)]).spokenSummary(now: now) == "weekly 100% used, resets in 1 day")
    }

    @Test("pace is spoken before the reset, and an unmeasured window has no pace")
    func order() {
        let ahead = DualBarMetrics(primaryFraction: 0.5, expectedPaceFraction: 0.2, label: "WK",
                                   resetsAt: now.addingTimeInterval(86_400), windowLength: QuotaWindow.week)
        #expect(grid([ahead]).spokenSummary(now: now) == "weekly 50% used, ahead of an even pace, resets in 1 day")
        let blocked = DualBarMetrics(primaryFraction: nil, expectedPaceFraction: 0.2, label: "WK", isBlocked: true)
        #expect(grid([blocked]).spokenSummary(now: now) == "weekly blocked")
    }

    // MARK: Blocked with a measured percentage (OpenCode Go reports both)

    /// The vendor blocked the window yet reported how much was used, and the
    /// usage is well above pace. The bar wears the vendor's blocked colour,
    /// not amber, so "ahead of an even pace" would misdescribe it.
    private func blockedMeasured(used: Double = 0.90, pace: Double? = 0.20) -> DualBarMetrics {
        DualBarMetrics(
            primaryFraction: used, expectedPaceFraction: pace, label: "WK",
            blockedColor: "#ffb4ab", isBlocked: true,
            resetsAt: now.addingTimeInterval(86_400), windowLength: QuotaWindow.week)
    }

    @Test("a blocked window with a percentage says blocked, and never claims to be ahead of pace")
    func blockedMeasuredIsNotAheadOfPace() {
        let spoken = grid([blockedMeasured()]).spokenSummary(now: now)
        #expect(spoken == "weekly 90% used, blocked, resets in 1 day")
        #expect(spoken?.contains("ahead of an even pace") == false)
    }

    @Test("the same usage, not blocked, is ahead of pace")
    func sameUsageNotBlockedIsAhead() {
        let open = DualBarMetrics(
            primaryFraction: 0.90, expectedPaceFraction: 0.20, label: "WK",
            resetsAt: now.addingTimeInterval(86_400), windowLength: QuotaWindow.week)
        #expect(grid([open]).spokenSummary(now: now) == "weekly 90% used, ahead of an even pace, resets in 1 day")
    }

    @Test("a blocked pool that is not a window also says blocked")
    func blockedExtra() {
        let pool = DualBarMetrics(primaryFraction: 0.5, label: "BN", blockedColor: "#ffb4ab", isBlocked: true)
        #expect(grid([DualBarMetrics(primaryFraction: 0.3, label: "MO"), pool]).spokenSummary(now: now)
                == "monthly 30% used, BN 50% used, blocked")
    }

    // MARK: Blocked glyph, the on-screen non-colour channel

    @Test("a blocked window that reports a percentage gets the glyph; the others do not")
    func blockedGlyphRule() {
        let blockedMeasured = DualBarMetrics(primaryFraction: 0.9, label: "WK", blockedColor: "#ffb4ab", isBlocked: true)
        let blockedUnread = DualBarMetrics(primaryFraction: nil, label: "WK", isBlocked: true)
        let openMeasured = DualBarMetrics(primaryFraction: 0.9, label: "WK")
        #expect(WindowGridPresentation.showsBlockedGlyph(for: blockedMeasured))
        // No percentage: the cell already says "Blocked" in words.
        #expect(!WindowGridPresentation.showsBlockedGlyph(for: blockedUnread))
        #expect(WindowGridPresentation.unmeasuredText(for: blockedUnread) == "Blocked")
        #expect(!WindowGridPresentation.showsBlockedGlyph(for: openMeasured))
    }

    /// The glyph exists because a shape can be told apart where colours
    /// cannot; it must not be a shape an urgency already uses.
    @Test("the blocked glyph is not any shape an urgency or status already uses")
    func blockedGlyphIsDistinct() {
        let used: Set<String> = [
            StatusIndicatorDot.symbol(for: .healthy),
            StatusIndicatorDot.symbol(for: .warning),
            StatusIndicatorDot.symbol(for: .critical),
            StatusIndicatorDot.symbol(for: .unavailable(.offline)),
        ]
        #expect(!used.contains(BlockedGlyph.symbolName))
    }
}

/// The cell's compact text and the spoken label read one instant.
@Suite("WindowGridPresentation — one instant")
struct WindowGridInstantTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func grid(resetsIn seconds: TimeInterval, now: Date) -> WindowGridPresentation {
        let bar = DualBarMetrics(
            primaryFraction: 0.2, label: "5H", resetsAt: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(seconds),
            windowLength: QuotaWindow.fiveHours)
        return WindowGridPresentation(
            snapshot: QuotaSnapshot(
                id: "x", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
                metric: .percentage(usedFraction: 0, displayDetails: nil), status: .healthy,
                resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil, row1: bar),
            now: now)
    }

    /// 59m30s sits on a rounding boundary: "1h" to one reading and "59
    /// minutes" to another if each takes its own clock.
    @Test("the drawn text and the spoken words come from the grid's own instant")
    func agree() {
        let g = grid(resetsIn: 59 * 60 + 30, now: now)
        #expect(g.now == now)
        #expect(g.compactReset(for: .fiveHour) == "1h")
        #expect(g.spokenSummary()?.contains("resets in 1 hour") == true)
    }

    @Test("a grid built at another instant says something else, so the instant is what decides")
    func instantDecides() {
        let early = grid(resetsIn: 3 * 3600, now: now)
        let late = grid(resetsIn: 3 * 3600, now: now.addingTimeInterval(2.5 * 3600))
        #expect(early.compactReset(for: .fiveHour) == "3h")
        #expect(late.compactReset(for: .fiveHour) == "30m")
        #expect(late.spokenSummary()?.contains("resets in 30 minutes") == true)
    }
}
