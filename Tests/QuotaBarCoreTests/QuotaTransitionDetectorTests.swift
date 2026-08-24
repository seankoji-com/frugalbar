import Testing
import Foundation
@testable import QuotaBarCore

/// Covers `QuotaTransitionDetector` (pure diffing) and `QuotaNotificationObserver`
/// (the actor that keeps "previous" state across polls) together, since the
/// edge-triggered behaviour only shows up across repeated `observe()` calls.
@Suite("QuotaTransitionDetector / QuotaNotificationObserver")
struct QuotaTransitionDetectorTests {

    // MARK: - Snapshot builders

    private func measured(_ vendor: VendorIdentifier, urgency: Urgency) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: "T", renewalDate: nil),
            status: .measured(urgency), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil)
    }

    private func unavailable(
        _ vendor: VendorIdentifier, _ reason: UnavailableReason = .notConfigured
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions, metric: .subscription(tierName: reason.headline, renewalDate: nil),
            status: .unavailable(reason), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: reason.remedy)
    }

    // MARK: - QuotaTransitionDetector (pure)

    @Test("critical to none fires once")
    func criticalToNoneFires() {
        let events = QuotaTransitionDetector.detect(
            previous: [.claude: measured(.claude, urgency: .critical)],
            current: [.claude: measured(.claude, urgency: .none)]
        )
        #expect(events == [QuotaRecoveryEvent(vendorId: .claude, displayName: "Claude")])
    }

    @Test("critical to warning still counts as regaining headroom")
    func criticalToWarningFires() {
        let events = QuotaTransitionDetector.detect(
            previous: [.claude: measured(.claude, urgency: .critical)],
            current: [.claude: measured(.claude, urgency: .warning)]
        )
        #expect(events == [QuotaRecoveryEvent(vendorId: .claude, displayName: "Claude")])
    }

    @Test("critical to critical does not fire")
    func criticalToCriticalDoesNotFire() {
        let events = QuotaTransitionDetector.detect(
            previous: [.claude: measured(.claude, urgency: .critical)],
            current: [.claude: measured(.claude, urgency: .critical)]
        )
        #expect(events.isEmpty)
    }

    @Test("critical to unavailable does not fire — a lost reading is not recovery")
    func criticalToUnavailableDoesNotFire() {
        let events = QuotaTransitionDetector.detect(
            previous: [.claude: measured(.claude, urgency: .critical)],
            current: [.claude: unavailable(.claude)]
        )
        #expect(events.isEmpty)
    }

    @Test("unavailable to none does not fire — no prior critical reading to recover from")
    func unavailableToNoneDoesNotFire() {
        let events = QuotaTransitionDetector.detect(
            previous: [.claude: unavailable(.claude)],
            current: [.claude: measured(.claude, urgency: .none)]
        )
        #expect(events.isEmpty)
    }

    @Test("no prior entry for a vendor never fires")
    func noPriorEntryDoesNotFire() {
        let events = QuotaTransitionDetector.detect(
            previous: [:],
            current: [.claude: measured(.claude, urgency: .none)]
        )
        #expect(events.isEmpty)
    }

    // MARK: - QuotaNotificationObserver (edge-triggered across polls)

    @Test("first-ever observe call never fires, however critical the initial reading")
    func firstObserveNeverFires() async {
        let observer = QuotaNotificationObserver()
        let events = await observer.observe(current: [measured(.claude, urgency: .critical)])
        #expect(events.isEmpty)
    }

    @Test("a second observe call with the same healthy state does not re-fire")
    func repeatedHealthyStateDoesNotRefire() async {
        let observer = QuotaNotificationObserver()
        _ = await observer.observe(current: [measured(.claude, urgency: .critical)])
        let recovered = await observer.observe(current: [measured(.claude, urgency: .none)])
        #expect(recovered == [QuotaRecoveryEvent(vendorId: .claude, displayName: "Claude")])

        // Same healthy reading again: already fired for this transition, must stay silent.
        let repeated = await observer.observe(current: [measured(.claude, urgency: .none)])
        #expect(repeated.isEmpty)
    }
}
