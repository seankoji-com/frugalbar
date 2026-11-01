import Foundation
import Testing
@testable import QuotaBarCore

@Suite("OpenAI monthly API credit")
struct OpenAIMonthlyCreditTests {
    private func date(_ text: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)!
    }

    private var now: Date { date("2026-10-24T00:00:00Z") }

    private func summary(_ grants: String, totals: String = #""total_granted":230,"total_used":42.34,"total_available":187.66"#) -> Data {
        Data(#"""
        {"object":"credit_summary",\#(totals),
         "grants":{"object":"list","data":[\#(grants)]}}
        """#.utf8)
    }

    private let monthly = #"""
    {"object":"credit_grant","grant_amount":200,"used_amount":12.34,
     "effective_at":"2026-10-19T00:25:31Z","expires_at":"2026-11-19T00:25:31Z",
     "grant_type":"promotion"}
    """#

    private let purchased = #"""
    {"object":"credit_grant","grant_amount":30,"used_amount":0,
     "effective_at":"2025-11-19T00:25:31Z","expires_at":"2026-11-19T00:25:31Z"}
    """#

    @Test("the monthly grant supplies its own allowance and remaining figure")
    func decodesMonthlyGrant() throws {
        let credit = try #require(try OpenAIMonthlyCredit.decode(summary(monthly), now: now))
        #expect(credit.grantUSD == 200)
        #expect(credit.remainingUSD == Decimal(string: "187.66"))
        #expect(credit.periodStart == date("2026-10-19T00:25:31Z"))
        #expect(credit.periodEnd == date("2026-11-19T00:25:31Z"))
        #expect(credit.measuredAt == now)

        let entry = credit.entry
        #expect(entry.id == "openai.monthly-credit")
        #expect(entry.vendorId == .openai)
        #expect(entry.label == "Monthly credit")
        #expect(entry.isMonthlyPromo)
        #expect(entry.extendsSubscription)
        // The grant's issue date is kept on the reading, not used as the
        // billing month's start for the pace marker.
        #expect(credit.periodStart == date("2026-10-19T00:25:31Z"))
        #expect(entry.monthlyPeriodStart == nil)
        #expect(entry.monthlyPeriodEnd == date("2026-11-19T00:25:31Z"))
        #expect(entry.metric == .currency(balance: Decimal(string: "187.66")!, limit: 200,
                                           spent: nil, currencyCode: "USD"))
        #expect(entry.detail == "$200.00 monthly credit")
    }

    /// The Platform's summary totals purchased credits as well. A purchased
    /// grant that still holds money must not become the monthly bar's
    /// denominator, and `total_available` must not be used at all.
    @Test("purchased credits are never folded into the monthly grant")
    func ignoresPurchasedCredits() throws {
        let credit = try #require(try OpenAIMonthlyCredit.decode(
            summary(monthly + "," + purchased,
                    totals: #""total_granted":230,"total_used":12.34,"total_available":217.66"#),
            now: now))
        #expect(credit.grantUSD == 200)
        #expect(credit.remainingUSD == Decimal(string: "187.66"))
        #expect(credit.entry.metric == .currency(balance: Decimal(string: "187.66")!, limit: 200,
                                                  spent: nil, currencyCode: "USD"))
    }

    /// The live Platform payload has no grant labels. The API-credits grant is
    /// the one whose expiry is the ChatGPT subscription's cycle end; the other
    /// grant is a longer-lived purchased pool. This is the exact shape seen on
    /// the account this feature was built for.
    @Test("an unlabelled grant is identified by the subscription cycle end")
    func identifiesBySubscriptionCycleEnd() throws {
        let actualNow = date("2026-11-02T00:00:00Z")
        let cycleEnd = date("2026-11-19T00:25:31Z")
        let apiCredit = #"""
        {"object":"credit_grant","grant_amount":116,"used_amount":0,
         "effective_at":"2026-11-01T02:15:38Z","expires_at":"2026-11-19T00:25:31Z"}
        """#
        let purchased = #"""
        {"object":"credit_grant","grant_amount":5,"used_amount":2.01776339,
         "effective_at":"2026-02-01T00:00:00Z","expires_at":"2027-03-01T00:00:00Z"}
        """#
        // A second monthly-span grant with a different expiry must be excluded
        // by the cycle-end match, not merely by its duration.
        let otherMonthly = #"""
        {"object":"credit_grant","grant_amount":50,"used_amount":0,
         "effective_at":"2026-10-25T00:00:00Z","expires_at":"2026-11-24T00:00:00Z"}
        """#
        let credit = try #require(try OpenAIMonthlyCredit.decode(
            summary(apiCredit + "," + purchased + "," + otherMonthly), now: actualNow,
            expectedPeriodEnd: cycleEnd))
        #expect(credit.grantUSD == 116)
        #expect(credit.remainingUSD == 116)
        #expect(credit.periodEnd == cycleEnd)
        // Without the cycle end, the API sends no label and no row is safe.
        #expect(try OpenAIMonthlyCredit.decode(
            summary(apiCredit + "," + purchased + "," + otherMonthly),
            now: actualNow) == nil)
    }

    @Test("an expired grant or a summary with no grants yields no monthly credit")
    func requiresCurrentGrant() throws {
        let expired = #"""
        {"object":"credit_grant","grant_amount":200,"used_amount":12.34,
         "effective_at":"2026-09-19T00:25:31Z","expires_at":"2026-10-19T00:25:31Z",
         "grant_type":"promotion"}
        """#
        #expect(try OpenAIMonthlyCredit.decode(summary(expired), now: now) == nil)
        // An annual Business grant is a real grant, but not the monthly row.
        let annual = #"""
        {"object":"credit_grant","grant_amount":6000,"used_amount":0,
         "effective_at":"2026-01-01T00:00:00Z","expires_at":"2027-01-01T00:00:00Z",
         "grant_type":"promotion"}
        """#
        #expect(try OpenAIMonthlyCredit.decode(summary(annual), now: now) == nil)
        // A 30-day purchased grant is still not identified as the subscription
        // benefit. Duration alone is not eligibility.
        let shortPurchased = #"""
        {"object":"credit_grant","grant_amount":30,"used_amount":0,
         "effective_at":"2026-10-20T00:25:31Z","expires_at":"2026-11-19T00:25:31Z"}
        """#
        #expect(try OpenAIMonthlyCredit.decode(summary(shortPurchased), now: now) == nil)
        // Without a start, remaining lifetime cannot establish the period.
        let noStart = #"""
        {"object":"credit_grant","grant_amount":200,"used_amount":12.34,
         "expires_at":"2026-11-19T00:25:31Z","grant_type":"promotion"}
        """#
        #expect(try OpenAIMonthlyCredit.decode(summary(noStart), now: now) == nil)
        // A creation timestamp is not an effective start; the period must be
        // published, not inferred from when the row was created.
        let createdAt = #"""
        {"object":"credit_grant","grant_amount":200,"used_amount":10,
         "created_at":"2026-10-20T00:25:31Z","expires_at":"2026-11-19T00:25:31Z",
         "grant_type":"promotion"}
        """#
        #expect(try OpenAIMonthlyCredit.decode(summary(createdAt), now: now) == nil)
        #expect(try OpenAIMonthlyCredit.decode(summary(""), now: now) == nil)
        #expect(try OpenAIMonthlyCredit.decode(
            Data(#"{"object":"credit_summary","total_available":187.66}"#.utf8), now: now) == nil)
        // A grant whose allowance or remaining figure was withheld is not a
        // reading, even when the summary totals are present.
        let noUsed = #"""
        {"object":"credit_grant","grant_amount":200,
         "effective_at":"2026-10-19T00:25:31Z","expires_at":"2026-11-19T00:25:31Z",
         "grant_type":"promotion"}
        """#
        #expect(try OpenAIMonthlyCredit.decode(summary(noUsed), now: now) == nil)
        // A remaining figure larger than its own grant is refused, not clamped.
        let over = #"""
        {"object":"credit_grant","grant_amount":10,"remaining_amount":11,
         "effective_at":"2026-10-19T00:25:31Z","expires_at":"2026-11-19T00:25:31Z",
         "grant_type":"promotion"}
        """#
        #expect(try OpenAIMonthlyCredit.decode(summary(over), now: now) == nil)
        // Two matching monthly grants are ambiguous: the summary does not say
        // which supersedes the other, so neither is chosen.
        #expect(try OpenAIMonthlyCredit.decode(
            summary(monthly + "," + monthly.replacingOccurrences(of: "200", with: "50")),
            now: now) == nil)
    }

    @Test("a published remaining figure is used when no used figure exists")
    func publishedRemaining() throws {
        let grant = #"""
        {"object":"credit_grant","grant_amount":200,"remaining_amount":150.5,
         "effective_at":"2026-10-19T00:25:31Z","expires_at":"2026-11-19T00:25:31Z",
         "grant_type":"promotion"}
        """#
        let credit = try #require(try OpenAIMonthlyCredit.decode(summary(grant), now: now))
        #expect(credit.remainingUSD == Decimal(string: "150.5"))
    }

    @Test("an unlabelled grant is not a candidate for the monthly benefit")
    func requiresLabel() throws {
        let unlabelled = #"""
        {"object":"credit_grant","grant_amount":50,"used_amount":0,
         "effective_at":"2026-10-20T00:25:31Z","expires_at":"2026-11-19T00:25:31Z"}
        """#
        let labelled = #"""
        {"object":"credit_grant","grant_amount":200,"used_amount":20,
         "effective_at":"2026-10-19T00:25:31Z","expires_at":"2026-11-19T00:25:31Z",
         "description":"ChatGPT subscription API credits"}
        """#
        #expect(try OpenAIMonthlyCredit.decode(summary(unlabelled), now: now) == nil)
        // With the subscription's cycle end, the unlabelled grant is eligible
        // and the labelled one is excluded unless it expires there too.
        let cycleEnd = date("2026-11-19T00:25:31Z")
        let byCycle = try #require(try OpenAIMonthlyCredit.decode(
            summary(unlabelled), now: now, expectedPeriodEnd: cycleEnd))
        #expect(byCycle.grantUSD == 50)
        let credit = try #require(try OpenAIMonthlyCredit.decode(
            summary(unlabelled + "," + labelled), now: now))
        #expect(credit.grantUSD == 200)
        #expect(credit.remainingUSD == 180)
    }

    @Test("the session keeps the last grant and marks a failed refresh")
    func sessionState() throws {
        var state = OpenAIMonthlyCreditSessionState()
        let first = try #require(try OpenAIMonthlyCredit.decode(summary(monthly), now: now))
        let payload = String(data: summary(monthly), encoding: .utf8)!
        state.observe(payload: payload, now: now)
        #expect(state.credit == first)
        #expect(state.attemptedAt == now)
        #expect(state.hasObserved)

        // A malformed payload is not a new reading.
        state.observe(payload: "not json", now: now.addingTimeInterval(10))
        #expect(state.credit?.grantUSD == 200)
        #expect(state.credit?.refreshFailed == true)

        // A valid summary that no longer carries a current monthly grant
        // clears the row instead of freezing the old figure.
        state.observe(payload: #"{"object":"credit_summary","total_available":0}"#,
                      now: now.addingTimeInterval(20))
        #expect(state.credit == nil)
    }

    @Test("a failed subscription lookup keeps the last cycle end and grant")
    func cycleEndFailureKeepsCredit() throws {
        var state = OpenAIMonthlyCreditSessionState()
        let cycleEnd = date("2026-11-19T00:25:31Z")
        let at = date("2026-11-02T00:00:00Z")
        let grant = #"""
        {"object":"credit_grant","grant_amount":116,"used_amount":0,
         "effective_at":"2026-11-01T02:15:38Z","expires_at":"2026-11-19T00:25:31Z"}
        """#
        state.setExpectedPeriodEnd(cycleEnd)
        state.observe(payload: String(data: summary(grant), encoding: .utf8)!, now: at)
        #expect(state.credit?.grantUSD == 116)
        // The lookup failed this pass; that is not evidence the cycle ended.
        state.setExpectedPeriodEnd(nil)
        #expect(state.expectedPeriodEnd == cycleEnd)
        #expect(state.credit?.grantUSD == 116)
    }

    @Test("the session generation and connection reset with a disconnect")
    func sessionGeneration() {
        var state = OpenAIMonthlyCreditSessionState()
        let generation = state.generation
        let opened = state.openConnection(alreadyEnabled: false, hasPage: false)
        #expect(opened)
        #expect(state.generation != generation)
        state.credit = OpenAIMonthlyCredit(grantUSD: 200, remainingUSD: 180,
            periodStart: now, periodEnd: now.addingTimeInterval(30 * 86_400), measuredAt: now)
        state.reset()
        #expect(state.credit == nil)
        #expect(state.attemptedAt == nil)
        #expect(!state.hasObserved)
        #expect(state.generation != generation)
    }
}
