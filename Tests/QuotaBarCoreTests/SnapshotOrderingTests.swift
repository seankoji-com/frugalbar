import Testing
import Foundation
@testable import QuotaBarCore

/// A provider that returns exactly the snapshot it was handed.
private struct FixedProvider: QuotaProvider {
    let vendorId: VendorIdentifier
    let displayName = "Fixed"
    let category: MetricCategory = .aiSubscriptions
    let snapshot: QuotaSnapshot

    func fetchSnapshot() async throws -> QuotaSnapshot { snapshot }
}

private func bar(
    _ label: String,
    used: Double,
    window: TimeInterval?,
    resetsIn hours: Double?,
    now: Date,
    elapsedOnly: Bool = false
) -> DualBarMetrics {
    DualBarMetrics(
        primaryFraction: used,
        label: label,
        measuresElapsedTimeOnly: elapsedOnly,
        resetsAt: hours.map { now.addingTimeInterval($0 * 3600) },
        windowLength: window
    )
}

private func snapshot(
    _ vendor: VendorIdentifier,
    now: Date,
    rows: [DualBarMetrics] = []
) -> QuotaSnapshot {
    QuotaSnapshot(
        id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
        category: .aiSubscriptions,
        metric: .percentage(usedFraction: 0.1, displayDetails: nil),
        status: .measured(.none),
        resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
        row1: rows.count > 0 ? rows[0] : nil,
        row2: rows.count > 1 ? rows[1] : nil,
        row3: rows.count > 2 ? rows[2] : nil
    )
}

private func manager(_ snapshots: [QuotaSnapshot]) -> QuotaManager {
    QuotaManager(
        cachePolicy: CachePolicy(cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
        providerFactory: { snapshots.map { FixedProvider(vendorId: $0.vendorId, snapshot: $0) } }
    )
}

@Suite("Snapshot ordering")
struct SnapshotOrderingTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the longest window decides a vendor's place, not its shortest")
    func longestWindowWins() async {
        // Claude's five-hour bucket resets in an hour, but its week has three
        // days left. Kiro has only a month, and that month ends tomorrow.
        // Kiro is the deadline that actually constrains today.
        let claude = snapshot(.claude, now: now, rows: [
            bar("5H", used: 0.2, window: QuotaWindow.fiveHours, resetsIn: 1, now: now),
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 72, now: now),
        ])
        let kiro = snapshot(.kiro, now: now, rows: [
            bar("MO", used: 0.2, window: 30 * 86_400, resetsIn: 24, now: now),
        ])

        let sorted = await orderedVendors(from: [claude, kiro])
        #expect(sorted == [.kiro, .claude])
    }

    @Test("an exhausted vendor sorts last however soon it refills")
    func exhaustedGoesLast() async {
        // Copilot's month is spent and resets in an hour; Grok's week is
        // barely touched and resets in six days. A spent vendor is not
        // somewhere to send work, whatever its clock says.
        let copilot = snapshot(.copilot, now: now, rows: [
            bar("MO", used: 1.0, window: 30 * 86_400, resetsIn: 1, now: now),
        ])
        let grok = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 144, now: now),
        ])

        #expect(await orderedVendors(from: [copilot, grok]) == [.grok, .copilot])
    }

    @Test("float residue below 1.0 still counts as exhausted")
    func residueIsExhausted() async {
        let copilot = snapshot(.copilot, now: now, rows: [
            bar("MO", used: 0.9995, window: 30 * 86_400, resetsIn: 1, now: now),
        ])
        let grok = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 144, now: now),
        ])
        #expect(await orderedVendors(from: [copilot, grok]) == [.grok, .copilot])
    }

    @Test("a vendor with no window sits between the dated ones and the spent ones")
    func undatedInTheMiddle() async {
        let dated = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 100, now: now),
        ])
        let undated = snapshot(.openrouter, now: now)
        let spent = snapshot(.copilot, now: now, rows: [
            bar("MO", used: 1.0, window: 30 * 86_400, resetsIn: 1, now: now),
        ])

        #expect(await orderedVendors(from: [spent, undated, dated])
            == [.grok, .openrouter, .copilot])
    }

    @Test("a blocked window counts as exhausted even with no percentage")
    func blockedIsExhausted() async {
        var blocked = bar("WK", used: 0.1, window: QuotaWindow.week, resetsIn: 2, now: now)
        blocked.isBlocked = true
        let opencode = snapshot(.opencode, now: now, rows: [blocked])
        let grok = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 144, now: now),
        ])
        #expect(await orderedVendors(from: [opencode, grok]) == [.grok, .opencode])
    }

    @Test("a hand-entered cycle counts for ordering but never for exhaustion")
    func cycleOrdersButDoesNotExhaust() async {
        // A cycle 29/30 of the way through is the nearest deadline, so it
        // should sort first — but it must not brand the vendor spent.
        let devpass = snapshot(.devpass, now: now, rows: [
            bar("WK", used: 0.0, window: QuotaWindow.week, resetsIn: 100, now: now),
            bar("MO", used: 0.97, window: 30 * 86_400, resetsIn: 20, now: now, elapsedOnly: true),
        ])
        let grok = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 144, now: now),
        ])

        #expect(devpass.isQuotaExhausted == false)
        #expect(QuotaManager.sortBand(devpass) == 0)
        #expect(await orderedVendors(from: [grok, devpass]) == [.devpass, .grok])
    }

    @Test("vendors sharing a reset time keep a stable, canonical order")
    func tiesAreStable() async {
        let rows = [bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 50, now: now)]
        let kiro = snapshot(.kiro, now: now, rows: rows)
        let claude = snapshot(.claude, now: now, rows: rows)
        // Canonical order puts Claude first, and the tie must not shuffle.
        #expect(await orderedVendors(from: [kiro, claude]) == [.claude, .kiro])
    }

    @Test("a vendor's own bars run longest period first")
    func barsRunLongestFirst() {
        // Assigned shortest-first, as several providers naturally build them.
        let snap = snapshot(.opencode, now: now, rows: [
            bar("5H", used: 0.1, window: QuotaWindow.fiveHours, resetsIn: 2, now: now),
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 40, now: now),
            bar("MO", used: 0.3, window: 30 * 86_400, resetsIn: 200, now: now),
        ])
        #expect(snap.bars.map(\.label) == ["MO", "WK", "5H"])
        #expect(snap.quotaBars.map(\.label) == ["MO", "WK", "5H"])
    }

    @Test("a window with no period sorts last and keeps its relative order")
    func undatedBarsSortLast() {
        // Kiro's bonus pool and overage allowance have no window length; only
        // the monthly credit allowance does.
        let snap = snapshot(.kiro, now: now, rows: [
            bar("BN", used: 0.5, window: nil, resetsIn: nil, now: now),
            bar("MO", used: 0.3, window: 30 * 86_400, resetsIn: 200, now: now),
            bar("OV", used: 0.0, window: nil, resetsIn: nil, now: now),
        ])
        #expect(snap.bars.map(\.label) == ["MO", "BN", "OV"])
    }

    @Test("longestWindowReset falls back to the snapshot's own reset")
    func fallbackReset() {
        let reset = now.addingTimeInterval(3600)
        let snap = QuotaSnapshot(
            id: "x", vendorId: .grok, displayName: "Grok", category: .aiSubscriptions,
            metric: .subscription(tierName: "t", renewalDate: reset),
            status: .measured(.none), resetsAt: reset, lastUpdated: now,
            auxiliaryInfo: nil)
        #expect(snap.longestWindowReset == reset)
    }

    private func orderedVendors(from snapshots: [QuotaSnapshot]) async -> [VendorIdentifier] {
        let manager = manager(snapshots)
        _ = await manager.forceRefresh()
        return await manager.sortedSnapshots().map(\.vendorId)
    }
}
