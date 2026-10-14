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
        // The value, in the vendor's own currency, worded by `MoneyText.format`
        // — the one deterministic money rule this row and a provider row both
        // print with. `MetricRowPresentation.currency` delegates to it as well,
        // because a locale-based formatter rendered a USD figure as
        // "USD 179.50" on an en_AU machine while the same row's subtitle, a few
        // points to the left, printed "$179.50". There is one rule and both
        // surfaces read it, which is why this asserts against `MoneyText` itself
        // rather than a second spelling of it.
        #expect(p.figure == "$179.50")
        #expect(p.figure == MoneyText.format(Decimal(string: "179.50")!, code: "USD"))
        #expect(p.figure.contains("179.50"))
        // The two units are never interchangeable.
        #expect(!p.figure.contains("credit"))
        #expect(p.detail == "$200.00 monthly limit")
        #expect(p.spoken.contains("179.50"))
    }

    /// The card speaks the money it draws. The row helper it used to forward
    /// the money case to renders through the *process locale*, which on an
    /// en_AU machine reads "USD 1,234.50" — so a card that drew "$1234.50" and
    /// announced "USD 1,234.50" would re-enter the figure/note disagreement it
    /// exists to prevent, through the spoken channel. A four-figure balance
    /// separates the two renderers on any locale, grouping or not.
    @Test("the spoken figure is the same money the card draws")
    func spokenMoneyIsTheDrawnMoney() {
        let metric = MetricType.currency(balance: Decimal(string: "1234.5")!,
                                         limit: Decimal(string: "2000")!,
                                         spent: nil, currencyCode: "USD")
        let p = APICreditEntryPresentation(entry: entry(metric))
        #expect(p.figure == "$1234.50")
        #expect(p.spoken.contains(p.figure))
    }

    /// An Anthropic promo credit published with `remaining_dollars` and no
    /// `limit_dollars` takes this path: a balance, a nil limit and a nil spent.
    /// The wording has to be the balance's, because printing that figure under
    /// "spent" asserts something nobody measured, and it must carry the same
    /// figure the row draws rather than a second rendering of it.
    @Test("a currency entry with no limit is worded as its balance")
    func moneyWithNoLimitIsWordedAsABalance() {
        let metric = MetricType.currency(balance: Decimal(string: "12.34")!,
                                         limit: nil, spent: nil, currencyCode: "USD")
        let wording = MetricRowPresentation.spoken(for: metric)
        #expect(wording == "$12.34 balance")

        // Worded by the shared rule, not by a copy of it: the card's spoken form
        // is `MetricRowPresentation.spoken`'s, so the two cannot drift.

        // The entry this path is reachable from is Anthropic's promo credit,
        // which always carries a note ("Expires …" or "Cloud-session credit"),
        // so the balance wording sits inside the spoken string rather than at
        // its end.
        let p = APICreditEntryPresentation(entry: entry(metric, detail: "Cloud-session credit"))
        #expect(p.figure == "$12.34")
        #expect(p.spoken.contains(p.figure))
        #expect(p.spoken.contains(wording))
        #expect(!p.spoken.contains("spent"))
        #expect(!p.spoken.contains("remaining"))
    }

    /// A count of credits is not a money figure, so the nil-limit money path
    /// must not be reachable for one.
    @Test("a credit count never reaches the money wording")
    func creditCountNeverTakesTheMoneyPath() {
        let p = APICreditEntryPresentation(entry: entry(.credits(remaining: 250, unitName: "credits")))
        #expect(!p.spoken.contains("balance"))
        #expect(p.spoken.hasSuffix("250 credits remaining"))
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
