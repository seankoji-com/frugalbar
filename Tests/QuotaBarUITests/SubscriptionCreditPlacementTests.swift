import Foundation
import Testing
import QuotaBarCore
@testable import QuotaBarUI

@Suite("Subscription credit placement")
struct SubscriptionCreditPlacementTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("fractional credits round to whole credits without changing quota")
    func fractionalSubscriptionCredits() throws {
        let amount = try #require(Decimal(string: "60085.4229770000"))
        let metric = MetricType.credits(remaining: amount, unitName: "credits")
        var snap = QuotaSnapshot(id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .percentage(usedFraction: 0.5, displayDetails: nil),
            status: .measured(.warning), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.5, label: "5H"))
        snap.apiCredits = [APICreditEntry(id: "openai.api-credits", vendorId: .openai,
                                        label: "Usage credits", metric: metric)]
        let p = MetricRowPresentation(snapshot: snap, now: now)
        #expect(p.subscriptionCredits.first?.figure == "60,085 credits")
        #expect(p.subscriptionCredits.first?.spoken.contains("60,085 credits remaining") == true)
        #expect(MetricRowPresentation.value(for: metric) == "60,085 credits")
        #expect(BalanceSeries.Unit.credits(name: "credits").format(-amount) == "-60,085 credits")
        #expect(CreditText.format(0) == "0")
        #expect(CreditText.format(Decimal(string: "0.00000001")!) == "0")
        #expect(CreditText.format(Decimal(string: "2.5")!) == "3")
        #expect(snap.consumptionFraction == 0.5)
        #expect(snap.displayBars.count == 1)
        #expect(snap.status == .measured(.warning))
        let balance = QuotaSnapshot(id: "credits", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: metric, status: .measured(.none), resetsAt: nil,
            lastUpdated: now, auxiliaryInfo: nil)
        #expect(MetricDetailPresentation.rawFigure(balance) == "60,085 credits remaining")
        #expect(balance.consumptionFraction == nil)
    }

    @Test("a reset ticket's tooltip states its published expiry, never an invented one")
    func resetTicketExpiry() throws {
        let expiry = try #require(ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z"))
        let credits = try #require(MetricRowPresentation.ResetCredits(
            total: 3, expiries: [expiry, nil]))
        let before = expiry.addingTimeInterval(-86_400)
        #expect(credits.expiryText(at: 0, now: before) == "Expires 17 Jul 2026")
        #expect(credits.expiryText(at: 1, now: before) == "Expiry not published")
        #expect(credits.expiryText(at: 2, now: before) == "Expiry not published")
        #expect(credits.expiryText(at: -1, now: before) == "Expiry not published")
        let expired = try #require(MetricRowPresentation.ResetCredits(total: 1, expiries: [expiry]))
        #expect(expired.expiryText(at: 0, now: expiry.addingTimeInterval(86_400)) == "Expired 17 Jul 2026")
    }

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

    @Test("the org monthly entitlement draws its own line and stays out of quota")
    func monthlyEntitlementPlacement() throws {
        let grant = try #require(try ClaudeMonthlyCredit.decode(Data(
            #"{"status":"linked","monthly_credit_usd":"123.45","next_grant_at":"2027-02-15T14:49:22Z"}"#.utf8), now: now))
        var snapshot = QuotaSnapshot(id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        #expect(MetricRowPresentation(snapshot: snapshot, now: now).monthlyCreditLine == nil)
        snapshot.monthlyAPICredit = grant
        let p = MetricRowPresentation(snapshot: snapshot, now: now)
        // The entitlement belongs to the linked Console organisation and is
        // not the promo-credit pool, so it keeps its own line even when no
        // promo credit is published.
        #expect(p.monthlyCreditLine == "Org monthly credit: $123.45 per month")
        #expect(p.monthlyCreditDetail?.contains("Next credit") == true)
        #expect(p.monthlyPromo == nil)
        #expect(p.subscriptionCredits.isEmpty)
        #expect(snapshot.apiCredits.isEmpty)
        #expect(snapshot.consumptionFraction == nil)
        #expect(snapshot.quotaBars.isEmpty)
        #expect(snapshot.monthlyAPICredit == grant)
    }

    @Test("the org monthly entitlement is spoken with its next credit date")
    func monthlyCreditSpokenLabel() throws {
        let grant = try #require(try ClaudeMonthlyCredit.decode(Data(
            #"{"status":"linked","monthly_credit_usd":"123.45","next_grant_at":"2027-02-15T14:49:22Z"}"#.utf8), now: now))
        var snapshot = QuotaSnapshot(id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        func spoken(_ snapshot: QuotaSnapshot) -> String {
            MetricRowPresentation(snapshot: snapshot, now: now).combinedAccessibilityLabel(
                windows: nil, forecast: nil, creditsStale: false)
        }
        #expect(!spoken(snapshot).contains("Org monthly credit"))
        snapshot.monthlyAPICredit = grant
        let current = spoken(snapshot)
        #expect(current.contains("Org monthly credit"))
        #expect(current.contains("$123.45"))
        #expect(current.contains("Next credit"))
        snapshot.monthlyAPICredit?.refreshFailed = true
        #expect(spoken(snapshot).contains("Stale monthly credit reading"))
    }

    @Test("a model-scoped window is spoken on its own line and stays out of plan-wide figures")
    func scopedWindowSpeech() {
        var snapshot = QuotaSnapshot(id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(.warning), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row2: DualBarMetrics(primaryFraction: 0.57, label: "WK", windowLength: QuotaWindow.week))
        snapshot.scopedBars = [DualBarMetrics(
            primaryFraction: 0.75,
            expectedPaceFraction: 0.5,
            label: "Fable",
            resetsAt: now.addingTimeInterval(5 * 86_400),
            windowLength: QuotaWindow.week)]
        let p = MetricRowPresentation(snapshot: snapshot, now: now)
        #expect(p.scopedSpeech?.contains("Fable weekly 75% used") == true)
        #expect(p.scopedSpeech?.contains("resets in 5 days") == true)
        // The scoped cap is not a plan-wide bar: it cannot drive exhaustion,
        // the menu-bar urgency or the advice engine's worst window.
        #expect(snapshot.quotaBars.map(\.label) == ["WK"])
        #expect(snapshot.status == .measured(.warning))
        #expect(p.combinedAccessibilityLabel(windows: nil, forecast: nil, creditsStale: false)
            .contains("Fable weekly 75% used"))
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
