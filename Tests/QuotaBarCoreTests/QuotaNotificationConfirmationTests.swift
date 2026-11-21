import Testing
import Foundation
@testable import QuotaBarCore

/// A restore or a recovery is a candidate until the next *fresh* read of the
/// same instance agrees. Built from the Antigravity glitch of 2026-11-21: one
/// poll served Argon WK at 0% with a reset of "request time + 7 days", and the
/// next poll served the old figures and the old reset again.
@Suite("QuotaNotificationObserver confirmation")
struct QuotaNotificationConfirmationTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let poll: TimeInterval = 120

    private func snapshot(
        _ vendor: VendorIdentifier = .antigravityArgon,
        fraction: Double?,
        resetsAt: Date?,
        at lastUpdated: Date,
        urgency: Urgency = .none,
        stale: Bool = false
    ) -> QuotaSnapshot {
        var s = QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: "T", renewalDate: nil),
            status: .measured(urgency), resetsAt: nil, lastUpdated: lastUpdated, auxiliaryInfo: nil)
        s.row1 = DualBarMetrics(primaryFraction: fraction, label: "WK",
                                resetsAt: resetsAt, windowLength: QuotaWindow.week)
        if stale { s.staleReading = StaleReading(reason: .offline, at: lastUpdated + 1) }
        return s
    }

    private func at(_ polls: Double) -> Date { now.addingTimeInterval(polls * poll) }

    @Test("baseline, glitch, cached repeat, fresh rebound: no restore and no recovery")
    func glitchThenCachedRepeatThenRebound() async {
        let observer = QuotaNotificationObserver()
        let oldReset = now.addingTimeInterval(4 * 86_400)
        let glitchReset = at(1).addingTimeInterval(QuotaWindow.week)
        let baseline = snapshot(fraction: 1.0, resetsAt: oldReset, at: at(0), urgency: .critical)
        let glitch = snapshot(fraction: 0.0, resetsAt: glitchReset, at: at(1))
        let rebound = snapshot(fraction: 1.0, resetsAt: oldReset, at: at(3), urgency: .critical)

        var all = QuotaTransitions(recoveries: [], resets: [])
        for (snap, time) in [(baseline, at(0)), (glitch, at(1)), (glitch, at(2)), (rebound, at(3)),
                             (rebound, at(4))] {
            let t = await observer.observeTransitions(current: [snap], now: time)
            all = QuotaTransitions(recoveries: all.recoveries + t.recoveries,
                                   resets: all.resets + t.resets,
                                   restores: all.restores + t.restores)
        }
        #expect(all.restores.isEmpty)
        #expect(all.recoveries.isEmpty)
        #expect(all.resets.isEmpty)
    }

    @Test("baseline, drop, fresh matching read: exactly one restore, with the candidate's figures")
    func confirmedRestore() async {
        let observer = QuotaNotificationObserver()
        let reset = now.addingTimeInterval(3 * 86_400)
        _ = await observer.observeTransitions(
            current: [snapshot(fraction: 0.8, resetsAt: reset, at: at(0))], now: at(0))
        let candidate = await observer.observeTransitions(
            current: [snapshot(fraction: 0.05, resetsAt: reset, at: at(1))], now: at(1))
        #expect(candidate.restores.isEmpty)
        // Rolling resets drift a few seconds per request; within the
        // tolerance that is the same window.
        let confirmed = await observer.observeTransitions(
            current: [snapshot(fraction: 0.06, resetsAt: reset.addingTimeInterval(30), at: at(2))],
            now: at(2))
        #expect(confirmed.restores == [UsageRestoredEvent(
            vendorId: .antigravityArgon, displayName: VendorIdentifier.antigravityArgon.displayName,
            barLabel: "WK", previousFraction: 0.8, currentFraction: 0.05, resetsAt: reset)])
        let after = await observer.observeTransitions(
            current: [snapshot(fraction: 0.06, resetsAt: reset, at: at(3))], now: at(3))
        #expect(after.restores.isEmpty)
    }

    @Test("a reset that moves about one poll forward on every read never confirms")
    func movingResetNeverConfirms() async {
        let observer = QuotaNotificationObserver()
        let reset = now.addingTimeInterval(3 * 86_400)
        var restores: [UsageRestoredEvent] = []
        restores += await observer.observeTransitions(
            current: [snapshot(fraction: 0.9, resetsAt: reset, at: at(0))], now: at(0)).restores
        for step in 1...4 {
            let moved = reset.addingTimeInterval(Double(step) * poll)
            restores += await observer.observeTransitions(
                current: [snapshot(fraction: 0.0, resetsAt: moved, at: at(Double(step)))],
                now: at(Double(step))).restores
        }
        #expect(restores.isEmpty)
    }

    @Test("a retained snapshot after a failed poll neither confirms nor discards")
    func staleRepeatWaits() async {
        let observer = QuotaNotificationObserver()
        let reset = now.addingTimeInterval(3 * 86_400)
        _ = await observer.observeTransitions(
            current: [snapshot(fraction: 0.8, resetsAt: reset, at: at(0))], now: at(0))
        _ = await observer.observeTransitions(
            current: [snapshot(fraction: 0.05, resetsAt: reset, at: at(1))], now: at(1))
        // Newer timestamp but carried-over figures: not a fresh read.
        let stale = await observer.observeTransitions(
            current: [snapshot(fraction: 1.0, resetsAt: reset, at: at(2), stale: true)], now: at(2))
        #expect(stale.restores.isEmpty)
        let fresh = await observer.observeTransitions(
            current: [snapshot(fraction: 0.05, resetsAt: reset, at: at(3))], now: at(3))
        #expect(fresh.restores.count == 1)
        let next = await observer.observeTransitions(
            current: [snapshot(fraction: 0.05, resetsAt: reset, at: at(4))], now: at(4))
        #expect(next.restores.isEmpty)
    }

    @Test("a critical, healthy, critical blip raises no recovery; a held recovery raises one")
    func recoveryNeedsConfirmation() async {
        let reset = now.addingTimeInterval(3 * 86_400)
        let blip = QuotaNotificationObserver()
        var recoveries: [QuotaRecoveryEvent] = []
        for (step, urgency) in [Urgency.critical, .none, .critical].enumerated() {
            recoveries += await blip.observeTransitions(
                current: [snapshot(fraction: 0.5, resetsAt: reset, at: at(Double(step)), urgency: urgency)],
                now: at(Double(step))).recoveries
        }
        #expect(recoveries.isEmpty)

        let held = QuotaNotificationObserver()
        recoveries = []
        for (step, urgency) in [Urgency.critical, .none, .none, .none].enumerated() {
            recoveries += await held.observeTransitions(
                current: [snapshot(fraction: 0.5, resetsAt: reset, at: at(Double(step)), urgency: urgency)],
                now: at(Double(step))).recoveries
        }
        #expect(recoveries == [QuotaRecoveryEvent(
            vendorId: .antigravityArgon, displayName: VendorIdentifier.antigravityArgon.displayName)])
    }

    /// The popover's ⟳ runs the observer as well as the schedule. Seeing the
    /// candidate's own snapshot again from that call must not confirm it, and
    /// the user's fresh rebound must discard it before the next tick.
    @Test("candidate, the same snapshot again, then a manual fresh rebound: no event")
    func manualRefreshRebound() async {
        let observer = QuotaNotificationObserver()
        let reset = now.addingTimeInterval(3 * 86_400)
        let glitch = snapshot(fraction: 0.0, resetsAt: reset, at: at(1))
        _ = await observer.observeTransitions(
            current: [snapshot(fraction: 0.9, resetsAt: reset, at: at(0))], now: at(0))
        var restores = await observer.observeTransitions(current: [glitch], now: at(1)).restores
        restores += await observer.observeTransitions(current: [glitch], now: at(1.2)).restores
        restores += await observer.observeTransitions(
            current: [snapshot(fraction: 0.9, resetsAt: reset, at: at(1.5))], now: at(1.5)).restores
        restores += await observer.observeTransitions(
            current: [snapshot(fraction: 0.9, resetsAt: reset, at: at(2))], now: at(2)).restores
        #expect(restores.isEmpty)
    }
}
