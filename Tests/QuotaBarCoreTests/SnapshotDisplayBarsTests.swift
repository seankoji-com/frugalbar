import Testing
import Foundation
@testable import QuotaBarCore

private let month: TimeInterval = 30 * 86_400

private func bar(
    _ label: String,
    used: Double?,
    window: TimeInterval?,
    blocked: Bool = false,
    elapsedOnly: Bool = false
) -> DualBarMetrics {
    DualBarMetrics(
        primaryFraction: used,
        label: label,
        isBlocked: blocked,
        measuresElapsedTimeOnly: elapsedOnly,
        windowLength: window
    )
}

/// Rows are handed in shortest-first on purpose: `bars`/`displayBars` order
/// longest-period first, so these tests pin that ordering too.
private func snapshot(_ rows: [DualBarMetrics]) -> QuotaSnapshot {
    QuotaSnapshot(
        id: "opencode", vendorId: .opencode, displayName: "OpenCode",
        category: .aiSubscriptions,
        metric: .percentage(usedFraction: 0.1, displayDetails: nil),
        status: .measured(.none),
        resetsAt: nil, lastUpdated: Date(timeIntervalSince1970: 1_800_000_000),
        auxiliaryInfo: nil,
        row1: rows.count > 0 ? rows[0] : nil,
        row2: rows.count > 1 ? rows[1] : nil,
        row3: rows.count > 2 ? rows[2] : nil
    )
}

/// `displayBars` is what the popover and inspector draw; `bars` stays the full
/// data set (history persists it). These pin the collapse and, just as
/// importantly, that the collapse never reaches the data.
@Suite("Drawing drops windows a spent longer period makes redundant")
struct SnapshotDisplayBarsTests {

    @Test("a spent monthly window hides the weekly and five-hour bars beneath it")
    func spentMonthHidesShorter() {
        let snap = snapshot([
            bar("5H", used: 0.1, window: QuotaWindow.fiveHours),
            bar("WK", used: 0.2, window: QuotaWindow.week),
            bar("MO", used: 1.0, window: month),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO"])
        // The data is untouched: history still records every window.
        #expect(snap.bars.map(\.label) == ["MO", "WK", "5H"])
        #expect(snap.quotaBars.map(\.label) == ["MO", "WK", "5H"])
    }

    @Test("a spent weekly window hides only the five-hour bar, not the month")
    func spentWeekHidesFiveHourOnly() {
        let snap = snapshot([
            bar("5H", used: 0.1, window: QuotaWindow.fiveHours),
            bar("WK", used: 1.0, window: QuotaWindow.week),
            bar("MO", used: 0.3, window: month),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO", "WK"])
    }

    @Test("a spent five-hour window hides nothing: nothing is shorter")
    func spentFiveHourHidesNothing() {
        let snap = snapshot([
            bar("5H", used: 1.0, window: QuotaWindow.fiveHours),
            bar("WK", used: 0.2, window: QuotaWindow.week),
            bar("MO", used: 0.3, window: month),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO", "WK", "5H"])
    }

    @Test("with nothing spent every window still draws")
    func nothingSpentDrawsAll() {
        let snap = snapshot([
            bar("5H", used: 0.9, window: QuotaWindow.fiveHours),
            bar("WK", used: 0.4, window: QuotaWindow.week),
            bar("MO", used: 0.1, window: month),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO", "WK", "5H"])
    }

    @Test("float residue at 100 still counts as spent")
    func floatResidueTriggersCollapse() {
        let snap = snapshot([
            bar("WK", used: 0.2, window: QuotaWindow.week),
            bar("MO", used: 0.9995, window: month),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO"])
    }

    @Test("the longest spent window is the one that decides")
    func longestSpentDecides() {
        let snap = snapshot([
            bar("5H", used: 1.0, window: QuotaWindow.fiveHours),
            bar("WK", used: 1.0, window: QuotaWindow.week),
            bar("MO", used: 1.0, window: month),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO"])
    }

    @Test("a period-less window survives a spent longer period")
    func periodLessWindowSurvives() {
        // Kiro's bonus credits have no window length and outlive the monthly
        // reset — hiding them because the month is spent would hide headroom
        // that is still usable.
        let snap = snapshot([
            bar("BN", used: 0.5, window: nil),
            bar("MO", used: 1.0, window: month),
            bar("OV", used: 0.0, window: nil),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO", "BN", "OV"])
    }

    @Test("an elapsed-time-only cycle row is never collapsed away")
    func cycleRowSurvives() {
        // The cycle is the shortest period here (a week) and a longer quota
        // window is spent, but a cycle row is a billing countdown, not
        // consumption, and stays.
        let snap = snapshot([
            bar("CYCLE", used: 0.9, window: QuotaWindow.week, elapsedOnly: true),
            bar("MO", used: 1.0, window: month),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO", "CYCLE"])
    }

    @Test("a cycle row that is 100% elapsed never triggers the collapse")
    func elapsedCycleDoesNotTrigger() {
        let snap = snapshot([
            bar("CYCLE", used: 1.0, window: month, elapsedOnly: true),
            bar("WK", used: 0.2, window: QuotaWindow.week),
        ])
        #expect(snap.displayBars.map(\.label) == ["CYCLE", "WK"])
    }

    @Test("a blocked window with no reading does not trigger the collapse")
    func blockedWithoutReadingDoesNotCollapse() {
        // Blocked already has its own hatched treatment; "spent" is a measured
        // number, never inferred from a declaration.
        let snap = snapshot([
            bar("WK", used: 0.2, window: QuotaWindow.week),
            bar("MO", used: nil, window: month, blocked: true),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO", "WK"])
    }

    @Test("a measured window that also reports blocked still collapses")
    func blockedWithReadingCollapses() {
        let snap = snapshot([
            bar("WK", used: 0.2, window: QuotaWindow.week),
            bar("MO", used: 1.0, window: month, blocked: true),
        ])
        #expect(snap.displayBars.map(\.label) == ["MO"])
    }
}
