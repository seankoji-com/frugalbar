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
