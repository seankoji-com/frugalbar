import Foundation
import Testing
@testable import QuotaBarUI
import QuotaBarCore

/// The banked reset credits a row draws: one ticket glyph per credit, capped,
/// with the count always spoken because the glyph run is a shape channel.
@Suite("Reset credit tickets")
struct ResetCreditTicketsTests {

    private typealias Credits = MetricRowPresentation.ResetCredits

    private func snapshot(available: Int?, applicable: Int? = nil) -> QuotaSnapshot {
        var snap = QuotaSnapshot(
            id: "openai", vendorId: .openai, displayName: "OpenAI", category: .aiSubscriptions,
            metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0), auxiliaryInfo: nil
        )
        snap.resetCreditsAvailable = available
        snap.resetCreditsApplicable = applicable
        return snap
    }

    @Test("one ticket per banked credit")
    func oneTicketPerCredit() throws {
        let credits = try #require(Credits(total: 3))
        #expect(credits.tickets == 3)
        #expect(credits.overflow == 0)
        #expect(credits.total == 3)
    }

    @Test("past the cap the overflow count carries the rest, never a vague +")
    func overflowIsExact() throws {
        let credits = try #require(Credits(total: 7))
        #expect(credits.tickets == Credits.maxTickets)
        #expect(credits.overflow == 2)
        // The strip is truncated, the *count* is not: five glyphs and "+2" is
        // seven, and the spoken form says seven.
        #expect(credits.total == 7)
        #expect(credits.spoken == "7 banked reset credits")
    }

    @Test("expiry storage is capped at rendered tickets and keeps missing entries nil")
    func expiryStorageIsCapped() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let credits = try #require(Credits(total: Int.max, expiries: [expiry, nil]))
        #expect(credits.tickets == Credits.maxTickets)
        #expect(credits.overflow == Int.max - Credits.maxTickets)
        #expect(credits.expiries == [expiry, nil, nil, nil, nil])
    }

    @Test("task cancellation and Reduce Motion stop an active glint")
    func reduceMotionToggleClearsGlint() {
        let active = GoldenTicketGlintState.motionAdjusted(isGlinting: true, reduceMotion: false)
        #expect(active)
        #expect(!GoldenTicketGlintState.shouldContinueAnimation(
            isCancelled: true, reduceMotion: false
        ))
        let afterCancellation = GoldenTicketGlintState.motionAdjusted(
            isGlinting: active, reduceMotion: true
        )
        #expect(!afterCancellation)
        #expect(!GoldenTicketGlintState.shouldContinueAnimation(
            isCancelled: false, reduceMotion: true
        ))
        #expect(!GoldenTicketGlintState.motionAdjusted(
            isGlinting: afterCancellation, reduceMotion: false
        ))
    }

    @Test("a single credit is spoken in the singular")
    func singularSpoken() throws {
        let credits = try #require(Credits(total: 1))
        #expect(credits.tickets == 1)
        #expect(credits.spoken == "1 banked reset credit")
    }

    /// A vendor that published no figure and a vendor that published zero are
    /// different facts, but neither draws a strip — "0 reset credits" is noise
    /// on every account that never held one.
    @Test("no figure and an explicit zero both draw nothing")
    func absentAndZeroDrawNothing() {
        #expect(Credits(total: nil) == nil)
        #expect(Credits(total: 0) == nil)
        #expect(Credits(total: -1) == nil)
    }

    @Test("the row exposes the strip only when the vendor published a count")
    func rowExposesStrip() throws {
        let three = MetricRowPresentation(snapshot: snapshot(available: 3))
        #expect(try #require(three.resetCredits).tickets == 3)

        let none = MetricRowPresentation(snapshot: snapshot(available: nil))
        #expect(none.resetCredits == nil)

        // The applicable count is a different fact (how many can be redeemed
        // now) and must not change how many tickets are drawn.
        let partly = MetricRowPresentation(snapshot: snapshot(available: 3, applicable: 1))
        #expect(try #require(partly.resetCredits).tickets == 3)
    }
}
