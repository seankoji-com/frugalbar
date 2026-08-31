import Testing
import Foundation
@testable import QuotaBarCore

/// Fixed UTC calendar. The renewal maths is calendar arithmetic, so a test that
/// used `.current` would pass or fail depending on the runner's timezone.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    utc.date(from: DateComponents(
        timeZone: TimeZone(identifier: "UTC"),
        year: year, month: month, day: day, hour: hour))!
}

@Suite("SubscriptionCycle")
struct SubscriptionCycleTests {

    @Test("the next renewal is the first one strictly after now")
    func nextRenewal() {
        let cycle = SubscriptionCycle(anchorDate: date(2026, 1, 15), cadence: .monthly)
        #expect(cycle.renewal(after: date(2026, 3, 10), calendar: utc) == date(2026, 3, 15))
        // Exactly on the renewal, the *next* one is what is still ahead.
        #expect(cycle.renewal(after: date(2026, 3, 15), calendar: utc) == date(2026, 4, 15))
    }

    @Test("a future anchor extrapolates backwards to the renewal actually next up")
    func futureAnchor() {
        // Someone who enters "renews 1 December" on a monthly plan means the
        // 1st of every month. Counting only forwards would tell them their
        // next renewal is six months out.
        let cycle = SubscriptionCycle(anchorDate: date(2026, 12, 1), cadence: .monthly)
        #expect(cycle.renewal(after: date(2026, 6, 1), calendar: utc) == date(2026, 7, 1))
        #expect(cycle.renewal(after: date(2026, 6, 15), calendar: utc) == date(2026, 7, 1))
        // An annual plan has no earlier instalment to fall back to this year.
        let annual = SubscriptionCycle(anchorDate: date(2026, 12, 1), cadence: .annual)
        #expect(annual.renewal(after: date(2026, 6, 1), calendar: utc) == date(2026, 12, 1))
    }

    @Test("a 31st anchor clamps into short months without drifting afterwards")
    func monthEndClamping() {
        // The bug a fixed 30-day interval produces: after February the renewal
        // day slides earlier every month and never recovers.
        let cycle = SubscriptionCycle(anchorDate: date(2026, 1, 31), cadence: .monthly)
        #expect(cycle.renewal(after: date(2026, 2, 1), calendar: utc) == date(2026, 2, 28))
        #expect(cycle.renewal(after: date(2026, 3, 1), calendar: utc) == date(2026, 3, 31))
        #expect(cycle.renewal(after: date(2026, 4, 1), calendar: utc) == date(2026, 4, 30))
        #expect(cycle.renewal(after: date(2026, 5, 1), calendar: utc) == date(2026, 5, 31))
    }

    @Test("a leap day anchor lands on the 28th in common years")
    func leapDayAnchor() {
        let cycle = SubscriptionCycle(anchorDate: date(2024, 2, 29), cadence: .annual)
        #expect(cycle.renewal(after: date(2025, 1, 1), calendar: utc) == date(2025, 2, 28))
        #expect(cycle.renewal(after: date(2028, 1, 1), calendar: utc) == date(2028, 2, 29))
    }

    @Test("weekly and annual cadences step by their own unit")
    func otherCadences() {
        let weekly = SubscriptionCycle(anchorDate: date(2026, 1, 1), cadence: .weekly)
        #expect(weekly.renewal(after: date(2026, 1, 10), calendar: utc) == date(2026, 1, 15))

        let annual = SubscriptionCycle(anchorDate: date(2020, 6, 5), cadence: .annual)
        #expect(annual.renewal(after: date(2026, 1, 1), calendar: utc) == date(2026, 6, 5))
    }

    @Test("the window is the real month length, not a 30-day constant")
    func windowLength() {
        let cycle = SubscriptionCycle(anchorDate: date(2026, 1, 1), cadence: .monthly)
        // February 2026 is 28 days; March is 31.
        #expect(cycle.windowLength(endingAt: date(2026, 3, 1), calendar: utc) == TimeInterval(28 * 86_400))
        #expect(cycle.windowLength(endingAt: date(2026, 4, 1), calendar: utc) == TimeInterval(31 * 86_400))
    }

    @Test("days remaining rounds up, so a renewal tonight is not '0 days'")
    func daysRemainingRoundsUp() {
        let cycle = SubscriptionCycle(anchorDate: date(2026, 3, 15), cadence: .monthly)
        #expect(cycle.daysRemaining(from: date(2026, 3, 14, 16), calendar: utc) == 1)
        #expect(cycle.daysRemaining(from: date(2026, 3, 1), calendar: utc) == 14)
    }

    @Test("the cycle row reports elapsed time, never consumption")
    func cycleRow() throws {
        let cycle = SubscriptionCycle(anchorDate: date(2026, 3, 1), cadence: .monthly)
        // Fifteen days into a 31-day March.
        let row = try #require(cycle.cycleRow(now: date(2026, 3, 16), calendar: utc))

        #expect(row.label == "CYCLE")
        #expect(row.resetsAt == date(2026, 4, 1))
        #expect(row.windowLength == TimeInterval(31 * 86_400))
        #expect(abs(try #require(row.primaryFraction) - 15.0 / 31.0) < 0.0001)
        #expect(row.usedText == "16 days left in monthly cycle")
    }

    @Test("a recorded cost appears in the row, and an absent one invents nothing")
    func costText() throws {
        let priced = SubscriptionCycle(
            anchorDate: date(2026, 3, 1), cadence: .monthly, cost: Decimal(string: "79")!)
        let text = try #require(priced.cycleRow(now: date(2026, 3, 16), calendar: utc)?.usedText)
        #expect(text.contains("79"))
        #expect(text.contains("/monthly"))

        let unpriced = SubscriptionCycle(anchorDate: date(2026, 3, 1), cadence: .monthly)
        let plain = try #require(unpriced.cycleRow(now: date(2026, 3, 16), calendar: utc)?.usedText)
        #expect(!plain.contains("/monthly"))
    }

    @Test("a singular day is not written as '1 days'")
    func singularDay() throws {
        let cycle = SubscriptionCycle(anchorDate: date(2026, 3, 15), cadence: .monthly)
        let row = try #require(cycle.cycleRow(now: date(2026, 3, 14, 16), calendar: utc))
        #expect(row.usedText == "1 day left in monthly cycle")
    }

    @Test("the pace fraction stays inside 0…1 across the whole period")
    func fractionBounds() throws {
        let cycle = SubscriptionCycle(anchorDate: date(2026, 1, 1), cadence: .monthly)
        for day in 1...28 {
            let fraction = try #require(
                cycle.cycleRow(now: date(2026, 2, day, 12), calendar: utc)?.primaryFraction)
            #expect(fraction >= 0 && fraction <= 1)
        }
    }
}

/// `StoreTests` below mutates one process-wide preference store — real
/// `UserDefaults`, shared by every test in the process — so its tests are
/// serialized against each other. They used to also race against
/// `QuotaManagerExtendedTests`' `forceRefresh()` calls, which read that same
/// store through `QuotaManager.attachingCycleRow`; a cycle written here for
/// `.devpass` could leak into an unrelated sort-order assertion running
/// concurrently. `attachingCycleRow` now takes its cycle as a plain
/// parameter instead of reading the store itself, so `AttachTests` below no
/// longer touches `UserDefaults` at all, and this is the only suite that
/// still needs the store to be real.
@Suite("Subscription cycle persistence", .serialized)
struct SubscriptionCyclePersistenceTests {

    @Suite("SubscriptionCycleStore")
    struct StoreTests {

        private func clear() {
            for vendor in VendorIdentifier.allCases {
                SubscriptionCycleStore.set(nil, for: vendor)
            }
        }

        @Test("a cycle round-trips through preferences")
        func roundTrip() {
            clear()
            defer { clear() }

            let cycle = SubscriptionCycle(
                anchorDate: date(2026, 5, 9), cadence: .annual,
                cost: Decimal(string: "179")!, currencyCode: "GBP")
            SubscriptionCycleStore.set(cycle, for: .devpass)

            let loaded = SubscriptionCycleStore.cycle(for: .devpass)
            #expect(loaded?.cadence == .annual)
            #expect(loaded?.cost == Decimal(string: "179"))
            #expect(loaded?.currencyCode == "GBP")
            #expect(loaded?.anchorDate == date(2026, 5, 9))
        }

        @Test("setting nil clears one vendor without disturbing the others")
        func clearOne() {
            clear()
            defer { clear() }

            SubscriptionCycleStore.set(SubscriptionCycle(anchorDate: date(2026, 1, 1)), for: .devpass)
            SubscriptionCycleStore.set(SubscriptionCycle(anchorDate: date(2026, 2, 2)), for: .grok)
            SubscriptionCycleStore.set(nil, for: .devpass)

            #expect(SubscriptionCycleStore.cycle(for: .devpass) == nil)
            #expect(SubscriptionCycleStore.cycle(for: .grok)?.anchorDate == date(2026, 2, 2))
        }

        @Test("an unconfigured vendor has no cycle")
        func unconfigured() {
            clear()
            defer { clear() }
            #expect(SubscriptionCycleStore.cycle(for: .kiro) == nil)
        }
    }
}

/// Exercises `QuotaManager.attachingCycleRow`'s merge logic directly, passing
/// the cycle as an argument rather than going through `SubscriptionCycleStore`
/// — this suite is pure and needs no isolation from anything else.
@Suite("QuotaManager cycle rows")
struct AttachTests {

    private func snapshot(
        vendor: VendorIdentifier = .devpass,
        row1: DualBarMetrics? = nil,
        row2: DualBarMetrics? = nil,
        row3: DualBarMetrics? = nil,
        resetsAt: Date? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.5, displayDetails: nil),
            status: .measured(.none), resetsAt: resetsAt, lastUpdated: Date(),
            auxiliaryInfo: nil, row1: row1, row2: row2, row3: row3)
    }

    private func bar(_ label: String) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: 0.5, label: label)
    }

    @Test("no configured cycle leaves the snapshot untouched")
    func noCycle() {
        let original = snapshot()
        #expect(QuotaManager.attachingCycleRow(to: original, cycle: nil) == original)
    }

    @Test("the cycle row takes the first free slot")
    func firstFreeSlot() {
        let cycle = SubscriptionCycle(anchorDate: Date())

        #expect(QuotaManager.attachingCycleRow(to: snapshot(), cycle: cycle).row1?.label == "CYCLE")

        let withOne = QuotaManager.attachingCycleRow(to: snapshot(row1: bar("MO")), cycle: cycle)
        #expect(withOne.row1?.label == "MO")
        #expect(withOne.row2?.label == "CYCLE")

        let withTwo = QuotaManager.attachingCycleRow(
            to: snapshot(row1: bar("MO"), row2: bar("WK")), cycle: cycle)
        #expect(withTwo.row3?.label == "CYCLE")
    }

    @Test("three informative vendor windows already fill the snapshot, so theirs win")
    func vendorWindowsWin() {
        let now = Date()
        let full = snapshot(
            row1: DualBarMetrics(primaryFraction: 0.5, label: "A", resetsAt: now.addingTimeInterval(30 * 86_400), windowLength: 30 * 86_400),
            row2: DualBarMetrics(primaryFraction: 0.5, label: "B", resetsAt: now.addingTimeInterval(7 * 86_400), windowLength: 7 * 86_400),
            row3: DualBarMetrics(primaryFraction: 0.5, label: "C", resetsAt: now.addingTimeInterval(5 * 3600), windowLength: 5 * 3600))
        let result = QuotaManager.attachingCycleRow(to: full, cycle: SubscriptionCycle(anchorDate: Date()))
        #expect(result.bars.map(\.label) == ["A", "B", "C"])
    }

    @Test("a vendor row with neither a reset nor a window is replaced, not three real windows")
    func uninformativeFilledSlotIsReplaced() {
        // Kiro's shape: MO has a real reset, but BN/OV can both come back
        // with no window to plan around. A cycle recorded for a vendor like
        // this used to be dropped silently — the Settings editor still
        // showed it as tracked, but it never rendered anywhere.
        let now = Date()
        let full = snapshot(
            row1: DualBarMetrics(
                primaryFraction: 0.5, label: "MO",
                resetsAt: now.addingTimeInterval(30 * 86_400), windowLength: 30 * 86_400),
            row2: bar("A"),
            row3: bar("B"))
        let result = QuotaManager.attachingCycleRow(to: full, cycle: SubscriptionCycle(anchorDate: now))
        #expect(result.row1?.label == "MO")
        #expect(result.row2?.label == "CYCLE")
        #expect(result.row3?.label == "B")
    }

    @Test("a vendor that published no reset adopts the user's renewal date")
    func adoptsRenewalDate() {
        let result = QuotaManager.attachingCycleRow(
            to: snapshot(resetsAt: nil), cycle: SubscriptionCycle(anchorDate: Date()))
        #expect(result.resetsAt != nil)
        #expect(result.resetsAt == result.row1?.resetsAt)
    }

    @Test("a vendor-published reset is never overwritten by a hand-entered one")
    func vendorResetWins() {
        let vendorReset = Date(timeIntervalSince1970: 1_800_000_000)
        let result = QuotaManager.attachingCycleRow(
            to: snapshot(resetsAt: vendorReset), cycle: SubscriptionCycle(anchorDate: Date()))
        #expect(result.resetsAt == vendorReset)
    }

    @Test("a cycle bar is drawn but never counted as consumable headroom")
    func cycleIsNotHeadroom() {
        // The bug this pins: DevPass with every credit unspent but three
        // weeks into its month advertised "97% remaining", then "10%
        // remaining" — a countdown read as a fuel gauge. `bars` still
        // carries it (the popover draws it); `quotaBars` must not.
        let result = QuotaManager.attachingCycleRow(
            to: snapshot(row1: DualBarMetrics(primaryFraction: 0.0, label: "WK")),
            cycle: SubscriptionCycle(anchorDate: Date()))

        // Longest window first: the cycle's month outranks the undated
        // stand-in bar, which has no period to rank by.
        #expect(result.bars.map(\.label) == ["CYCLE", "WK"])
        #expect(result.quotaBars.map(\.label) == ["WK"])
    }

    @Test("a nearly elapsed cycle does not make an untouched plan look exhausted")
    func lateCycleIsNotExhaustion() throws {
        // 29 days into a 30-day period: the cycle bar sits near 1.0.
        let anchor = Calendar.current.date(byAdding: .day, value: -29, to: Date())!
        let result = QuotaManager.attachingCycleRow(
            to: snapshot(row1: DualBarMetrics(primaryFraction: 0.0, label: "WK")),
            cycle: SubscriptionCycle(anchorDate: anchor, cadence: .monthly))
        let cycle = try #require(result.bars.first { $0.label == "CYCLE" })

        #expect(try #require(cycle.primaryFraction) > 0.9)
        // Nothing that reasons about spend may see it.
        #expect(result.quotaBars.allSatisfy { $0.primaryFractionOrUnmeasured == 0 })
    }

    @Test("an unreadable provider still gets its countdown — the case it matters most for")
    func unavailableSnapshotKeepsCycle() {
        let placeholder = QuotaManager.unavailableSnapshot(
            for: DevPassQuotaProvider(), reason: .notConfigured)
        let result = QuotaManager.attachingCycleRow(
            to: placeholder, cycle: SubscriptionCycle(anchorDate: Date()))
        #expect(result.status == .unavailable(.notConfigured))
        #expect(result.row1?.label == "CYCLE")
    }

    @Test("removingStaleCycleRow lets an already-attached cycle countdown be recomputed against a later now")
    func staleCycleRowCanBeRefreshed() {
        // The bug this pins: attachingCycleRow only ever fills a *free* row
        // slot, so calling it again on a snapshot that already carries a
        // cycle row was a no-op — a provider outage left the countdown
        // frozen at whatever it read on the last successful fetch.
        // removingStaleCycleRow clears just that row (and the resetsAt it
        // adopted) so the countdown can be recomputed from scratch.
        let cycle = SubscriptionCycle(anchorDate: Date(), cadence: .monthly)
        let attached = QuotaManager.attachingCycleRow(to: snapshot(), cycle: cycle, now: Date())
        let firstFraction = attached.row1?.primaryFraction

        let stale = QuotaManager.removingStaleCycleRow(from: attached)
        #expect(stale.row1 == nil)
        #expect(stale.resetsAt == nil)

        // Ten days later, still inside the same monthly period — the
        // renewal date is unchanged, but meaningfully more of it has
        // elapsed.
        let later = Date().addingTimeInterval(10 * 86_400)
        let refreshed = QuotaManager.attachingCycleRow(to: stale, cycle: cycle, now: later)
        let laterFraction = refreshed.row1?.primaryFraction

        #expect(refreshed.row1 != nil)
        #expect(laterFraction != nil && firstFraction != laterFraction)
    }
}
