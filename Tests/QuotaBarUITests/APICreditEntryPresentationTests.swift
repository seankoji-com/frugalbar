import Foundation
import Testing
@testable import QuotaBarUI
import QuotaBarCore

/// The prepaid API credit entries the popover draws in their own card.
///
/// The load-bearing property is that a figure stays in the unit the vendor
/// published it in: a credit count is a count of credits, never money, and
/// money is never a count. Reformattng one as the other invents a number.
@Suite("API credit entry presentation")
struct APICreditEntryPresentationTests {

    private func entry(_ metric: MetricType, detail: String? = nil) -> APICreditEntry {
        APICreditEntry(
            id: "x", vendorId: .openai, label: "API credits",
            metric: metric, detail: detail, source: "test payload"
        )
    }

    @Test("a credit count is drawn in credits, never as money")
    func creditCountIsNotMoney() {
        let p = APICreditEntryPresentation(entry: entry(.credits(remaining: 250, unitName: "credits")))
        #expect(p.figure == "250 credits")
        #expect(!p.figure.contains("$"))
        #expect(p.title == "OpenAI API credits")
        #expect(p.spoken == "OpenAI API credits, 250 credits remaining")
    }

    /// A figure carried over from a failed poll must be spoken as old. The row
    /// speaks its figure and its note in one breath, so a screen reader has no
    /// other channel for the fact — and the same figure is drawn in the vendor's
    /// own quota row, which does say it.
    @Test("a stale entry says so in words, and a current one says nothing extra")
    func staleEntryIsSpoken() {
        let p = APICreditEntryPresentation(entry: entry(.credits(remaining: 250, unitName: "credits")))
        #expect(p.spoken(stale: false) == p.spoken)
        #expect(p.spoken(stale: true) == "\(p.spoken), stale, the last poll failed")
        #expect(p.spoken(stale: true) != p.spoken)
    }

    /// A six-figure count keeps its grouping so it can be read at a glance, and
    /// strips back to exactly the figure the vendor published — whatever
    /// separator this machine's locale uses.
    @Test("a large credit count round-trips and is still not money")
    func largeCreditCountRoundTrips() {
        let p = APICreditEntryPresentation(entry: entry(.credits(remaining: 62_500, unitName: "credits")))
        #expect(p.figure.hasSuffix("credits"))
        #expect(!p.figure.contains("$"))
        let digits = p.figure.compactMap { $0.isNumber ? $0 : nil }
        #expect(Int(String(digits)) == 62_500)
    }

    /// The vendor saying the pool is unlimited is stated, not counted: a count
    /// there would have to be invented.
    @Test("an unlimited pool is said, not counted")
    func unlimitedIsSpoken() {
        let p = APICreditEntryPresentation(entry: entry(.credits(remaining: nil, unitName: "credits")))
        #expect(p.figure == "Unlimited")
        #expect(p.spoken.contains("unlimited"))
    }

    @Test("a money balance is drawn as money, never as a count of credits")
    func moneyBalanceIsNotACount() {
        let metric = MetricType.currency(balance: Decimal(string: "179.50")!,
                                         limit: Decimal(string: "200")!,
                                         spent: nil, currencyCode: "USD")
        let p = APICreditEntryPresentation(entry: entry(metric, detail: "$200.00 monthly limit"))
        // The value, in the vendor's own currency, through the one deterministic
        // money formatter the provider rows also print with (`MoneyText`) — so
        // the credit card and a provider row can never disagree on how a dollar
        // figure reads. `MetricRowPresentation.currency` stays locale-based and
        // is deliberately *not* what this is asserted against.
        #expect(p.figure == "$179.50")
        #expect(p.figure == MoneyText.format(Decimal(string: "179.50")!, code: "USD"))
        #expect(p.figure.contains("179.50"))
        // The two units are never interchangeable.
        #expect(!p.figure.contains("credit"))
        #expect(p.detail == "$200.00 monthly limit")
        #expect(p.spoken.contains("179.50"))
    }

    /// The whole point of a separate card: nothing here is a quota. A count of
    /// credits has no cap to be a fraction *of*, so it can never drive a bar,
    /// an urgency band or the menu-bar icon — which all read a snapshot's
    /// consumption fraction.
    @Test("a credits metric contributes no consumption fraction")
    func creditsMetricHasNoFraction() {
        for metric: MetricType in [
            .credits(remaining: 250, unitName: "credits"),
            .credits(remaining: nil, unitName: "credits"),
        ] {
            let snap = QuotaSnapshot(
                id: "openai", vendorId: .openai, displayName: "OpenAI",
                category: .apiSpendAndCredits, metric: metric,
                status: .measured(.none), resetsAt: nil,
                lastUpdated: Date(timeIntervalSince1970: 0), auxiliaryInfo: nil
            )
            #expect(snap.consumptionFraction == nil)
        }
    }
}
