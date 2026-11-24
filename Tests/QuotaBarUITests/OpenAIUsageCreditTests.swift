import AppKit
import SwiftUI
import Foundation
import Testing
import QuotaBarCore
@testable import QuotaBarUI

@Suite("Agreed ChatGPT credit layout")
struct OpenAIUsageCreditTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(balance: Decimal? = 59_641, total: Decimal = 75_000, expiry: Date? = nil) -> APICreditEntry {
        APICreditEntry(id: "openai.api-credits", vendorId: .openai, label: "Usage credits",
            metric: .credits(remaining: balance, unitName: "credits"),
            creditGrant: OpenAICreditGrant(total: total, expiresAt: expiry))
    }

    private func snapshot() -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro 200", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.24, label: "WK"), planName: "Pro 200")
        snapshot.resetCreditsAvailable = 1
        snapshot.resetCreditExpiries = [now.addingTimeInterval(12 * 86_400)]
        snapshot.apiCredits = [entry(expiry: now.addingTimeInterval(68 * 86_400))]
        return snapshot
    }

    @Test("the agreed bar replaces the balance line without altering the quota")
    func creditBar() throws {
        let snap = snapshot()
        let p = MetricRowPresentation(snapshot: snap, now: now)
        let credits = try #require(p.openAIUsageCredit)
        #expect(abs(credits.fraction - Double(75_000 - 59_641) / 75_000) < 0.0000001)
        #expect(credits.percentText == "20% used")
        #expect(credits.totalText == "of 75,000")
        #expect(credits.expiryText == "Expires in 68 days")
        #expect(p.subscriptionCredits.isEmpty)
        #expect(snap.consumptionFraction == nil)
        #expect(snap.quotaBars.first?.primaryFraction == 0.24)
        #expect(snap.quotaBars.count == 1)
        #expect(snap.status == .measured(.none))
        let spoken = p.combinedAccessibilityLabel(windows: nil, forecast: nil, creditsStale: false)
        #expect(spoken.contains("20% used"))
        #expect(spoken.contains("12 days remaining"))
        #expect(spoken.contains("Expires in 68 days"))
        #expect(!spoken.contains("credits remaining"))
    }

    @Test("missing grant, unmetered credits or a new top-up cannot fabricate usage")
    func absentOrObsoleteGrant() {
        for credit in [entry(balance: nil), entry(balance: 75_001), entry(total: 0), entry(balance: -1)] {
            #expect(OpenAIUsageCreditPresentation(entry: credit, now: now, isStale: false) == nil)
        }
        var snap = snapshot()
        snap.apiCredits = [APICreditEntry(id: "openai.api-credits", vendorId: .openai,
            label: "Usage credits", metric: .credits(remaining: 59_641, unitName: "credits"))]
        let p = MetricRowPresentation(snapshot: snap, now: now)
        #expect(p.openAIUsageCredit == nil)
        #expect(p.subscriptionCredits.first?.figure == "59,641 credits")
        #expect(OpenAIUsageCreditPresentation(entry: entry(balance: 75_000), now: now, isStale: false)?.fraction == 0)
        #expect(OpenAIUsageCreditPresentation(entry: entry(balance: 0), now: now, isStale: false)?.fraction == 1)
    }

    @Test("expiry countdowns share the render clock and never roll into a new grant")
    func countdowns() throws {
        #expect(CreditExpiryText.countdown(nil, now: now) == "Expiry not published")
        #expect(CreditExpiryText.countdown(now, now: now) == "Expired")
        #expect(CreditExpiryText.countdown(now.addingTimeInterval(-1), now: now) == "Expired")
        #expect(CreditExpiryText.countdown(now.addingTimeInterval(1), now: now) == "Expires in 1 day")
        #expect(CreditExpiryText.countdown(now.addingTimeInterval(86_401), now: now) == "Expires in 2 days")
        #expect(CreditExpiryText.remaining(nil, now: now) == "Expiry not published")
        #expect(CreditExpiryText.remaining(now, now: now) == "Expired")
        #expect(CreditExpiryText.remaining(now.addingTimeInterval(-1), now: now) == "Expired")
        #expect(CreditExpiryText.remaining(now.addingTimeInterval(1), now: now) == "1d remaining")
        #expect(CreditExpiryText.remaining(now.addingTimeInterval(86_401), now: now) == "2d remaining")
        #expect(CreditExpiryText.remaining(now.addingTimeInterval(.greatestFiniteMagnitude), now: now)
            == "Expiry not published")
        #expect(CreditExpiryText.remainingSpoken(nil, now: now) == "Expiry not published")
        #expect(CreditExpiryText.remainingSpoken(now, now: now) == "Expired")
        #expect(CreditExpiryText.remainingSpoken(now.addingTimeInterval(1), now: now) == "1 day remaining")
        #expect(CreditExpiryText.remainingSpoken(now.addingTimeInterval(86_401), now: now) == "2 days remaining")
        #expect(CreditExpiryText.remainingSpoken(now.addingTimeInterval(.greatestFiniteMagnitude), now: now)
            == "Expiry not published")
        let tickets = try #require(MetricRowPresentation.ResetCredits(total: 7,
            expiries: [now.addingTimeInterval(86_400), nil, now], now: now))
        #expect(tickets.expiryCountdown(at: 0) == "1d remaining")
        #expect(tickets.expiryCountdown(at: 1) == "No expiry")
        #expect(tickets.expiryCountdown(at: 2) == "Expired")
        #expect(tickets.expiryCountdown(at: 4) == "No expiry")
        #expect(tickets.overflow == 2)
        let stale = try #require(OpenAIUsageCreditPresentation(entry: entry(expiry: now), now: now, isStale: true))
        #expect(stale.expiryText == "Expired")
        #expect(stale.fraction > 0 && stale.fraction < 1)
        #expect(stale.spoken.contains("stale"))
    }

}
