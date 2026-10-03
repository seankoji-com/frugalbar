import Testing
import Foundation
@testable import QuotaBarCore

@Suite("QuotaResetDetector")
struct QuotaResetDetectorTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ vendor: VendorIdentifier,
        bars: [DualBarMetrics],
        measured: Bool = true
    ) -> QuotaSnapshot {
        var s = QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: "T", renewalDate: nil),
            status: measured ? .measured(.none) : .unavailable(.notConfigured),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        s.row1 = bars.first
        s.row2 = bars.dropFirst().first
        return s
    }

    private func bar(_ label: String, resetsAt: Date?, fraction: Double = 0.5, elapsedOnly: Bool = false) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: fraction, label: label, measuresElapsedTimeOnly: elapsedOnly,
                       resetsAt: resetsAt, windowLength: QuotaWindow.fiveHours)
    }

    @Test("a passed reset time replaced by a later one fires")
    func rolloverFires() {
        let old = now.addingTimeInterval(-30)
        let new = now.addingTimeInterval(QuotaWindow.fiveHours)
        let events = QuotaResetDetector.detect(
            previous: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: old, fraction: 0.9)])],
            current: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: new, fraction: 0.0)])],
            now: now)
        #expect(events == [QuotaResetEvent(vendorId: .claude, displayName: "Claude", barLabel: "5H", resetsAt: new)])
    }

    @Test("reset time still in the future does not fire, however far it moves")
    func futureResetDoesNotFire() {
        let old = now.addingTimeInterval(600)
        let new = now.addingTimeInterval(QuotaWindow.fiveHours)
        let events = QuotaResetDetector.detect(
            previous: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: old)])],
            current: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: new)])],
            now: now)
        #expect(events.isEmpty)
    }

    @Test("a few seconds of drift in a rolling window is not a reset")
    func driftDoesNotFire() {
        let old = now.addingTimeInterval(-5)
        let new = old.addingTimeInterval(QuotaResetDetector.minimumAdvance)
        let events = QuotaResetDetector.detect(
            previous: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: old)])],
            current: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: new)])],
            now: now)
        #expect(events.isEmpty)
    }

    @Test("a fraction drop without a new reset time is not a reset")
    func fractionDropAloneDoesNotFire() {
        let events = QuotaResetDetector.detect(
            previous: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: nil, fraction: 0.9)])],
            current: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: nil, fraction: 0.0)])],
            now: now)
        #expect(events.isEmpty)
    }

    @Test("an unavailable reading on either side never fires")
    func unmeasuredDoesNotFire() {
        let old = now.addingTimeInterval(-30)
        let new = now.addingTimeInterval(3600)
        let before = snapshot(.claude, bars: [bar("5H", resetsAt: old)])
        let after = snapshot(.claude, bars: [bar("5H", resetsAt: new)])
        #expect(QuotaResetDetector.detect(
            previous: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: old)], measured: false)],
            current: [.claude: after], now: now).isEmpty)
        #expect(QuotaResetDetector.detect(
            previous: [.claude: before],
            current: [.claude: snapshot(.claude, bars: [bar("5H", resetsAt: new)], measured: false)],
            now: now).isEmpty)
    }

    @Test("elapsed-time-only cycle bars are ignored")
    func elapsedOnlyIgnored() {
        let old = now.addingTimeInterval(-30)
        let new = now.addingTimeInterval(30 * 86_400)
        let events = QuotaResetDetector.detect(
            previous: [.devpass: snapshot(.devpass, bars: [bar("MO", resetsAt: old, elapsedOnly: true)])],
            current: [.devpass: snapshot(.devpass, bars: [bar("MO", resetsAt: new, elapsedOnly: true)])],
            now: now)
        #expect(events.isEmpty)
    }

    @Test("only the window that rolled over is reported")
    func onlyRolledWindowReported() {
        let past = now.addingTimeInterval(-30)
        let week = now.addingTimeInterval(3 * 86_400)
        let events = QuotaResetDetector.detect(
            previous: [.claude: snapshot(.claude, bars: [bar("WK", resetsAt: week), bar("5H", resetsAt: past)])],
            current: [.claude: snapshot(.claude, bars: [bar("WK", resetsAt: week), bar("5H", resetsAt: now.addingTimeInterval(18_000))])],
            now: now)
        #expect(events.map(\.barLabel) == ["5H"])
    }

    @Test("observer reports resets across polls, and only once")
    func observerEdgeTriggered() async {
        let observer = QuotaNotificationObserver()
        let first = snapshot(.claude, bars: [bar("5H", resetsAt: now.addingTimeInterval(60))])
        let second = snapshot(.claude, bars: [bar("5H", resetsAt: now.addingTimeInterval(18_060))])

        #expect(await observer.observeTransitions(current: [first], now: now).resets.isEmpty)
        let later = now.addingTimeInterval(120)
        #expect(await observer.observeTransitions(current: [second], now: later).resets.count == 1)
        #expect(await observer.observeTransitions(current: [second], now: later.addingTimeInterval(120)).resets.isEmpty)
    }

    @Test("a reset event built without a reset time still compiles and compares")
    func resetsAtDefaultsToNil() {
        #expect(QuotaResetEvent(vendorId: .claude, displayName: "Claude", barLabel: "5H").resetsAt == nil)
    }

    @Test("stored reset-alert vendors decode, dropping unknown values")
    func storedVendorsDecode() {
        #expect(CredentialStore.resetAlertVendors(fromStored: nil).isEmpty)
        #expect(CredentialStore.resetAlertVendors(fromStored: ["claude", "retired", "github_rest"])
                == [.claude, .githubRest])
    }
}
