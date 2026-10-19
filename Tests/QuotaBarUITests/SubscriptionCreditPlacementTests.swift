import Foundation
import Testing
import QuotaBarCore
@testable import QuotaBarUI

@Suite("Subscription credit placement")
struct SubscriptionCreditPlacementTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Codex usage credits stay with the plan and leave its quota figures unchanged")
    func creditsBelongToSubscription() {
        let credit = APICreditEntry(id: "openai.api-credits", vendorId: .openai,
            label: "Usage credits", metric: .credits(remaining: 62_500, unitName: "credits"))
        var snap = QuotaSnapshot(id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .percentage(usedFraction: 1, displayDetails: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 1, label: "5H"))
        let originalFraction = snap.consumptionFraction
        snap.apiCredits = [credit]
        let presentation = MetricRowPresentation(snapshot: snap, now: now)
        #expect(credit.extendsSubscription)
        #expect(snap.apiCredits.filter { !$0.extendsSubscription }.isEmpty)
        #expect(presentation.subscriptionCredits.count == 1)
        let digits = presentation.subscriptionCredits.first?.figure.filter(\.isNumber)
        #expect(digits == "62500")
        #expect(presentation.subscriptionCredits.first?.figure.hasSuffix("credits") == true)
        #expect(presentation.subscriptionCredits.first?.figure.contains("$") == false)
        #expect(presentation.subscriptionCredits.first?.detail == nil)
        #expect(presentation.subscriptionCredits.first?.spoken.contains("Usage credits") == true)
        #expect(snap.consumptionFraction == originalFraction)
        #expect(presentation.isExhausted)

        snap.staleReading = StaleReading(reason: .offline, at: now)
        let stale = MetricRowPresentation(snapshot: snap, now: now)
        #expect(stale.subscriptionCredits == presentation.subscriptionCredits)
        #expect(stale.subscriptionCredits.first?.spoken(stale: true).contains("stale") == true)
        #expect(stale.staleNote != nil)
    }

    @Test("Claude monthly entitlement is a separate line with no balance or quota")
    func monthlyEntitlementPlacement() throws {
        let grant = try #require(ClaudeMonthlyCredit.decode(Data(
            #"{"status":"linked","monthly_credit_usd":"123.45","next_grant_at":"2027-02-15T14:49:22Z"}"#.utf8), now: now))
        var snapshot = QuotaSnapshot(id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        #expect(MetricRowPresentation(snapshot: snapshot, now: now).monthlyCreditLine == nil)
        snapshot.monthlyAPICredit = grant
        let p = MetricRowPresentation(snapshot: snapshot, now: now)
        #expect(p.monthlyCreditLine == "Monthly API credit: $123.45 per month")
        #expect(p.monthlyCreditDetail?.contains("Next credit") == true)
        #expect(p.subscriptionCredits.isEmpty)
        #expect(snapshot.apiCredits.isEmpty)
        #expect(snapshot.consumptionFraction == nil)
        #expect(snapshot.quotaBars.isEmpty)
        #expect(MetricRowPresentation(snapshot: snapshot, now: now.addingTimeInterval(300))
            .monthlyCreditDetail?.contains("Stale monthly credit") == true)
    }

    @Test("other credit pools remain separate and missing credits draw nothing")
    func otherPoolsRemainSeparate() {
        let credit = APICreditEntry(id: "claude.extra-usage", vendorId: .claude,
            label: "API credits", metric: .credits(remaining: 100, unitName: "credits"))
        #expect(!credit.extendsSubscription)
        let snap = QuotaSnapshot(id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        #expect(MetricRowPresentation(snapshot: snap, now: now).subscriptionCredits.isEmpty)
    }

    @Test("a missing quota response names the vendor's reason instead of denying an API exists")
    func staleReasonIsSpecific() {
        let reason = UnavailableReason.unsupported("Muse reported no subscription usage")
        let display = MetricRowPresentation.staleDisplay(StaleReading(reason: reason, at: now), figuresAt: now, now: now)
        #expect(reason.headline == "No quota reading")
        #expect(display?.visible.contains("Muse reported no subscription usage") == true)
        #expect(display?.spoken.contains("Muse reported no subscription usage") == true)
    }
}
