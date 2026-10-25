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
        #expect(spoken.contains("Expires in 12 days"))
        #expect(spoken.contains("Expires in 68 days"))
        #expect(!spoken.contains("credits remaining"))
        let group = try #require(PopoverRowGrouping.groups(for: [snap]).first)
        #expect(group.header == "ChatGPT")
        #expect(group.headerPlan == "Pro 200")
        #expect(group.suppressPlan)
        #expect(PopoverRowGrouping.subtitle(for: snap, suppressPlan: group.suppressPlan, presentation: p).isEmpty)
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
        let tickets = try #require(MetricRowPresentation.ResetCredits(total: 7,
            expiries: [now.addingTimeInterval(86_400), nil, now], now: now))
        #expect(tickets.expiryCountdown(at: 0) == "Expires in 1 day")
        #expect(tickets.expiryCountdown(at: 1) == "Expiry not published")
        #expect(tickets.expiryCountdown(at: 2) == "Expired")
        #expect(tickets.expiryCountdown(at: 4) == "Expiry not published")
        #expect(tickets.overflow == 2)
        let stale = try #require(OpenAIUsageCreditPresentation(entry: entry(expiry: now), now: now, isStale: true))
        #expect(stale.expiryText == "Expired")
        #expect(stale.fraction > 0 && stale.fraction < 1)
        #expect(stale.spoken.contains("stale"))
    }

    @Test("production row renders the blue credit bar at the 332pt content width")
    @MainActor func renderedBar() throws {
        func bluePixels(_ grant: Bool) throws -> Int {
            var snap = snapshot()
            if !grant { snap.apiCredits = [] }
            let host = NSHostingView(rootView: MetricRowView(snapshot: snap, isGrouped: true, suppressPlan: true)
                .frame(width: 332).background(Theme.card).environment(\.colorScheme, .dark))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width == 332)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let c = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if c.blueComponent > 0.9, c.blueComponent - c.redComponent > 0.25,
                       c.greenComponent > 0.65 { count += 1 }
                }
            }
            return count
        }
        #expect(try bluePixels(true) > bluePixels(false) + 100)
    }
}
