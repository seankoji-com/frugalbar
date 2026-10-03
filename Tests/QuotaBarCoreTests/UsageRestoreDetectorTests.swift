import Testing
import Foundation
@testable import QuotaBarCore

@Suite("UsageRestoreDetector")
struct UsageRestoreDetectorTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ vendor: VendorIdentifier,
        bars: [DualBarMetrics],
        measured: Bool = true,
        credits: Int? = nil
    ) -> QuotaSnapshot {
        var s = QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: "T", renewalDate: nil),
            status: measured ? .measured(.none) : .unavailable(.notConfigured),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        s.row1 = bars.first
        s.row2 = bars.dropFirst().first
        s.resetCreditsAvailable = credits
        return s
    }

    private func bar(_ label: String, fraction: Double?, resetsAt: Date?, elapsedOnly: Bool = false) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: fraction, label: label, measuresElapsedTimeOnly: elapsedOnly,
                       resetsAt: resetsAt, windowLength: QuotaWindow.fiveHours)
    }

    private func detect(_ before: QuotaSnapshot, _ after: QuotaSnapshot) -> [UsageRestoredEvent] {
        UsageRestoreDetector.detect(
            previous: [before.vendorId: before], current: [after.vendorId: after], now: now)
    }

    @Test("a large drop before an unchanged future reset fires with the measured figures")
    func restoreFires() {
        let reset = now.addingTimeInterval(4 * 86_400)
        let events = detect(
            snapshot(.openai, bars: [bar("WK", fraction: 0.73, resetsAt: reset)]),
            snapshot(.openai, bars: [bar("WK", fraction: 0.02, resetsAt: reset)]))
        #expect(events == [UsageRestoredEvent(
            vendorId: .openai, displayName: "OpenAI", barLabel: "WK",
            previousFraction: 0.73, currentFraction: 0.02, resetsAt: reset)])
    }

    @Test("a drop of exactly the threshold fires; just under does not")
    func thresholdBoundary() {
        let reset = now.addingTimeInterval(3600)
        #expect(detect(
            snapshot(.claude, bars: [bar("5H", fraction: 0.45, resetsAt: reset)]),
            snapshot(.claude, bars: [bar("5H", fraction: 0.30, resetsAt: reset)])).count == 1)
        #expect(detect(
            snapshot(.claude, bars: [bar("5H", fraction: 0.45, resetsAt: reset)]),
            snapshot(.claude, bars: [bar("5H", fraction: 0.31, resetsAt: reset)])).isEmpty)
    }

    /// A vendor-wide reset can move the clock as well as the counter. The old
    /// reset had not passed, so this is a restore that restarted the window —
    /// and `QuotaResetDetector` stays silent, because it needs the old reset
    /// time to have passed. Neither announcing it twice nor not at all.
    @Test("a drop with an advanced reset while the old reset was still ahead fires as a restarted window")
    func restoreThatRestartedTheWindow() {
        let oldReset = now.addingTimeInterval(60)
        let newReset = oldReset.addingTimeInterval(QuotaWindow.fiveHours)
        let before = snapshot(.claude, bars: [bar("5H", fraction: 0.9, resetsAt: oldReset)])
        let after = snapshot(.claude, bars: [bar("5H", fraction: 0.0, resetsAt: newReset)])
        let events = detect(before, after)
        #expect(events.count == 1)
        #expect(events.first?.windowRestarted == true)
        #expect(events.first?.resetsAt == newReset)
        #expect(QuotaResetDetector.detect(
            previous: [.claude: before], current: [.claude: after], now: now).isEmpty)
    }

    @Test("a drop with an unchanged reset is a restore that kept its window")
    func restoreKeptTheWindow() {
        let reset = now.addingTimeInterval(3600)
        let events = detect(
            snapshot(.claude, bars: [bar("5H", fraction: 0.9, resetsAt: reset)]),
            snapshot(.claude, bars: [bar("5H", fraction: 0.1, resetsAt: reset)]))
        #expect(events.first?.windowRestarted == false)
    }

    @Test("drift within the reset detector's tolerance still counts as the same window")
    func driftWithinTolerance() {
        let oldReset = now.addingTimeInterval(3600)
        let newReset = oldReset.addingTimeInterval(QuotaResetDetector.minimumAdvance)
        #expect(detect(
            snapshot(.claude, bars: [bar("5H", fraction: 0.9, resetsAt: oldReset)]),
            snapshot(.claude, bars: [bar("5H", fraction: 0.1, resetsAt: newReset)])).count == 1)
    }

    /// Regression guard: a previous reset that has already passed means the
    /// drop is the scheduled reset itself.
    @Test("a previous reset time already in the past never fires")
    func pastResetIsNotARestore() {
        let past = now.addingTimeInterval(-30)
        #expect(detect(
            snapshot(.claude, bars: [bar("5H", fraction: 0.9, resetsAt: past)]),
            snapshot(.claude, bars: [bar("5H", fraction: 0.0, resetsAt: past)])).isEmpty)
    }

    @Test("missing reset times on either side never fire")
    func missingResetTimes() {
        let reset = now.addingTimeInterval(3600)
        #expect(detect(
            snapshot(.claude, bars: [bar("5H", fraction: 0.9, resetsAt: nil)]),
            snapshot(.claude, bars: [bar("5H", fraction: 0.0, resetsAt: reset)])).isEmpty)
        #expect(detect(
            snapshot(.claude, bars: [bar("5H", fraction: 0.9, resetsAt: reset)]),
            snapshot(.claude, bars: [bar("5H", fraction: 0.0, resetsAt: nil)])).isEmpty)
    }

    @Test("an unmeasured snapshot or a nil fraction on either side never fires")
    func unmeasuredNeverFires() {
        let reset = now.addingTimeInterval(3600)
        let good = snapshot(.claude, bars: [bar("5H", fraction: 0.9, resetsAt: reset)])
        let low = snapshot(.claude, bars: [bar("5H", fraction: 0.0, resetsAt: reset)])
        #expect(detect(snapshot(.claude, bars: [bar("5H", fraction: 0.9, resetsAt: reset)], measured: false), low).isEmpty)
        #expect(detect(good, snapshot(.claude, bars: [bar("5H", fraction: 0.0, resetsAt: reset)], measured: false)).isEmpty)
        #expect(detect(good, snapshot(.claude, bars: [bar("5H", fraction: nil, resetsAt: reset)])).isEmpty)
    }

    @Test("elapsed-time-only bars are ignored")
    func elapsedOnlyIgnored() {
        let reset = now.addingTimeInterval(86_400)
        #expect(detect(
            snapshot(.devpass, bars: [bar("MO", fraction: 0.9, resetsAt: reset, elapsedOnly: true)]),
            snapshot(.devpass, bars: [bar("MO", fraction: 0.1, resetsAt: reset, elapsedOnly: true)])).isEmpty)
    }

    @Test("no previous reading fires nothing")
    func firstPollSilent() {
        let reset = now.addingTimeInterval(3600)
        let events = UsageRestoreDetector.detect(
            previous: [:],
            current: [.claude: snapshot(.claude, bars: [bar("5H", fraction: 0.0, resetsAt: reset)])],
            now: now)
        #expect(events.isEmpty)
    }

    @Test("the observer surfaces restores without also reporting a reset")
    func observerReportsRestoreOnly() async {
        let observer = QuotaNotificationObserver()
        let reset = now.addingTimeInterval(3 * 86_400)
        _ = await observer.observeTransitions(
            current: [snapshot(.openai, bars: [bar("WK", fraction: 0.8, resetsAt: reset)])], now: now)
        let t = await observer.observeTransitions(
            current: [snapshot(.openai, bars: [bar("WK", fraction: 0.05, resetsAt: reset)])],
            now: now.addingTimeInterval(120))
        #expect(t.restores.count == 1)
        #expect(t.resets.isEmpty)
        #expect(t.creditGrants.isEmpty)
    }
}
