import Testing
import Foundation
@testable import QuotaBarCore

/// A provider that returns exactly the snapshot it was handed.
private struct FixedProvider: QuotaProvider {
    let vendorId: VendorIdentifier
    let displayName = "Fixed"
    let category: MetricCategory = .aiSubscriptions
    let snapshot: QuotaSnapshot

    /// The snapshot's own id, so a test can serve several instances of one
    /// vendor (OpenCode Go workspaces) without them collapsing onto one cache
    /// key.
    var instanceID: String { snapshot.id }

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

    // MARK: - Custom order

    @Test("in a custom order an exhausted vendor moves to the bottom and the rest keep their places")
    func customOrderPutsExhaustedLast() async {
        // The user's own order, with the spent one in the middle. Its place is
        // a statement about where they want to look, not about where work
        // should go — a vendor with every window spent is not somewhere to
        // send work however high it sits in the list.
        let preferences = ProviderDisplayPreferences(
            ordering: .custom,
            order: [.claude, .copilot, .grok, .openrouter]
        )
        let claude = snapshot(.claude, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 100, now: now),
        ])
        let copilot = snapshot(.copilot, now: now, rows: [
            bar("MO", used: 1.0, window: 30 * 86_400, resetsIn: 1, now: now),
        ])
        let grok = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 140, now: now),
        ])
        // No window at all: not exhausted, so it keeps its place among the live.
        let openrouter = snapshot(.openrouter, now: now)

        let ordered = await orderedIDs(
            from: [claude, copilot, grok, openrouter], preferences: preferences)

        #expect(ordered == ["claude", "grok", "openrouter", "copilot"])
    }

    @Test("the custom split uses the same exhausted rule as the automatic sort")
    func customSplitSharesTheExhaustedDefinition() async {
        // Claude's five-hour bucket is spent while its week has headroom. The
        // automatic sort already calls that exhausted — a vendor with even one
        // spent window is not somewhere to start work right now — and the
        // custom split must not invent a second, gentler definition, or the
        // same row would sort one way in one mode and another way in the other.
        let preferences = ProviderDisplayPreferences(
            ordering: .custom, order: [.claude, .grok]
        )
        let claude = snapshot(.claude, now: now, rows: [
            bar("5H", used: 1.0, window: QuotaWindow.fiveHours, resetsIn: 1, now: now),
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 100, now: now),
        ])
        let grok = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 200, now: now),
        ])
        #expect(QuotaManager.sortBand(claude) == 2)

        let ordered = await orderedIDs(from: [claude, grok], preferences: preferences)

        #expect(ordered == ["grok", "claude"])
    }

    @Test("custom order keeps one vendor's workspaces together, placed by their best instance")
    func customOrderKeepsWorkspacesTogether() async {
        // Alpha is spent, Beta is not: the block stays at OpenCode's place in
        // the user's list rather than half of it dropping to the bottom, and
        // the two instances keep the order they were arranged in.
        let preferences = ProviderDisplayPreferences(
            ordering: .custom, order: [.claude, .opencode, .grok]
        )
        let claude = snapshot(.claude, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 100, now: now),
        ])
        let alpha = instance(
            .opencode, id: "opencode-go-alpha", now: now,
            rows: [bar("MO", used: 1.0, window: 30 * 86_400, resetsIn: 1, now: now)])
        let beta = instance(
            .opencode, id: "opencode-go-beta", now: now,
            rows: [bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 140, now: now)])
        let grok = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 200, now: now),
        ])

        let ordered = await orderedIDs(
            from: [claude, alpha, beta, grok], preferences: preferences)

        #expect(ordered == ["claude", "opencode-go-alpha", "opencode-go-beta", "grok"])
    }

    @Test("custom order moves a vendor block whose every workspace is spent")
    func customOrderMovesFullySpentWorkspaceBlock() async {
        let preferences = ProviderDisplayPreferences(
            ordering: .custom, order: [.opencode, .grok]
        )
        let alpha = instance(
            .opencode, id: "opencode-go-alpha", now: now,
            rows: [bar("MO", used: 1.0, window: 30 * 86_400, resetsIn: 1, now: now)])
        let beta = instance(
            .opencode, id: "opencode-go-beta", now: now,
            rows: [bar("WK", used: 1.0, window: QuotaWindow.week, resetsIn: 2, now: now)])
        let grok = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 200, now: now),
        ])

        let ordered = await orderedIDs(from: [alpha, beta, grok], preferences: preferences)

        #expect(ordered == ["grok", "opencode-go-alpha", "opencode-go-beta"])
    }

    @Test("an automatic order still sorts by deadline, band by band")
    func automaticOrderIsUnchanged() async {
        // The custom split must not leak into `.automatic`, which already
        // places a spent vendor last by band.
        let preferences = ProviderDisplayPreferences(ordering: .automatic)
        let spent = snapshot(.copilot, now: now, rows: [
            bar("MO", used: 1.0, window: 30 * 86_400, resetsIn: 1, now: now),
        ])
        let undated = snapshot(.openrouter, now: now)
        let grok = snapshot(.grok, now: now, rows: [
            bar("WK", used: 0.2, window: QuotaWindow.week, resetsIn: 200, now: now),
        ])
        #expect(await orderedVendors(from: [spent, undated, grok]) == [.grok, .openrouter, .copilot])
        let ordered = await orderedIDs(from: [spent, undated, grok], preferences: preferences)
        #expect(ordered == ["grok", "openrouter", "copilot"])
    }

    private func instance(
        _ vendor: VendorIdentifier,
        id: String,
        now: Date,
        rows: [DualBarMetrics] = []
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id, vendorId: vendor, displayName: id,
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.1, displayDetails: nil),
            status: .measured(.none),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: rows.count > 0 ? rows[0] : nil,
            row2: rows.count > 1 ? rows[1] : nil,
            row3: rows.count > 2 ? rows[2] : nil
        )
    }

    private func orderedVendors(from snapshots: [QuotaSnapshot]) async -> [VendorIdentifier] {
        let manager = manager(snapshots)
        _ = await manager.forceRefresh()
        return await manager.sortedSnapshots().map(\.vendorId)
    }

    /// The same read, but with the display preferences a test hands it, and
    /// keyed by instance id so several instances of one vendor are tellable
    /// apart.
    private func orderedIDs(
        from snapshots: [QuotaSnapshot],
        preferences: ProviderDisplayPreferences
    ) async -> [String] {
        let manager = QuotaManager(
            cachePolicy: CachePolicy(
                cacheTTL: 30, backgroundRefreshInterval: 120, perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { snapshots.map { FixedProvider(vendorId: $0.vendorId, snapshot: $0) } },
            displayPreferences: { preferences }
        )
        _ = await manager.forceRefresh()
        return await manager.sortedSnapshots().map(\.id)
    }
}
