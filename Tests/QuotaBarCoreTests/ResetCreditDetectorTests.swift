import Testing
import Foundation
@testable import QuotaBarCore

@Suite("ResetCreditDetector")
struct ResetCreditDetectorTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(credits: Int?, measured: Bool = true, applicable: Int? = nil) -> QuotaSnapshot {
        var s = QuotaSnapshot(
            id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: "Plus", renewalDate: nil),
            status: measured ? .measured(.none) : .unavailable(.timedOut),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        s.resetCreditsAvailable = credits
        s.resetCreditsApplicable = applicable
        return s
    }

    private func detect(_ before: QuotaSnapshot?, _ after: QuotaSnapshot) -> [ResetCreditGrantedEvent] {
        ResetCreditDetector.detect(
            previous: before.map { [.openai: $0] } ?? [:], current: [.openai: after])
    }

    @Test("a rising count fires with both counts")
    func riseFires() {
        #expect(detect(snapshot(credits: 0), snapshot(credits: 1)) == [
            ResetCreditGrantedEvent(vendorId: .openai, displayName: "OpenAI", previousCount: 0, currentCount: 1),
        ])
        #expect(detect(snapshot(credits: 1), snapshot(credits: 3)).first?.currentCount == 3)
    }

    /// A count that drops out of one poll and comes back is not a grant. The
    /// old `?? 0` turned every such flap into a fresh banner (the event id
    /// carries the poll time, so dedup could not catch it).
    @Test("an absent count on either poll never fires, so a field that flaps is silent")
    func absentCountNeverFires() {
        #expect(detect(snapshot(credits: nil), snapshot(credits: 1)).isEmpty)
        #expect(detect(snapshot(credits: nil), snapshot(credits: 0)).isEmpty)
        #expect(detect(snapshot(credits: 2), snapshot(credits: nil)).isEmpty)
        // 2 → nil → 2: the balance never changed.
        #expect(detect(snapshot(credits: nil), snapshot(credits: 2)).isEmpty)
    }

    @Test("the first poll after launch fires nothing")
    func firstPollSilent() {
        #expect(detect(nil, snapshot(credits: 2)).isEmpty)
    }

    /// Regression guard: a lost reading is not "zero credits". Without the
    /// measured check, every outage would re-announce existing credits.
    @Test("an unmeasured previous poll never fires")
    func unmeasuredPreviousSilent() {
        #expect(detect(snapshot(credits: nil, measured: false), snapshot(credits: 2)).isEmpty)
        #expect(detect(snapshot(credits: 0), snapshot(credits: 2, measured: false)).isEmpty)
    }

    /// The redeemable count flips with window state; only the banked total
    /// is a grant.
    @Test("a change in the redeemable count alone never fires")
    func applicableChangeSilent() {
        #expect(detect(snapshot(credits: 2, applicable: 0), snapshot(credits: 2, applicable: 2)).isEmpty)
        #expect(detect(snapshot(credits: 2, applicable: nil), snapshot(credits: 2, applicable: 1)).isEmpty)
    }

    @Test("an unchanged, falling or absent current count never fires")
    func noRiseSilent() {
        #expect(detect(snapshot(credits: 2), snapshot(credits: 2)).isEmpty)
        #expect(detect(snapshot(credits: 2), snapshot(credits: 1)).isEmpty)
        #expect(detect(snapshot(credits: 0), snapshot(credits: nil)).isEmpty)
    }
}
