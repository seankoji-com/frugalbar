import AppKit
import SwiftUI
import Testing
import QuotaBarCore
@testable import QuotaBarUI

@Suite("Monthly promo credit")
struct MonthlyPromoCreditTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-10-24T00:00:00Z") }
    private var end: Date { date("2026-11-05T00:00:00Z") }

    private func entry(balance: Decimal = 0, limit: Decimal? = 100, end: Date? = nil) -> APICreditEntry {
        APICreditEntry(id: "claude.promo-credit", vendorId: .claude, label: "Promo credit",
            metric: .currency(balance: balance, limit: limit, spent: nil, currencyCode: "USD"),
            currencyBasis: .prepaidCredit, monthlyPeriodEnd: end)
    }

    @Test("zero promo balance stays in Claude with a full bar, pace marker and day countdown")
    func exhaustedPromo() throws {
        let promo = entry(end: end)
        var snapshot = QuotaSnapshot(id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .percentage(usedFraction: 0.2, displayDetails: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.2, label: "WK"))
        snapshot.apiCredits = [promo]
        let row = MetricRowPresentation(snapshot: snapshot, now: now)
        let p = try #require(row.monthlyPromo)
        #expect(promo.extendsSubscription)
        #expect(snapshot.apiCredits.filter { !$0.extendsSubscription }.isEmpty)
        #expect(row.subscriptionCredits.isEmpty)
        #expect(p.figure == "$0.00 left")
        #expect(p.fraction == 1)
        #expect(abs(try #require(p.paceMarker) - 19.0 / 31) < 0.00001)
        #expect(p.dayCountdown == "12d")
        #expect(MetricSectionView.showsPaceLegend(for: [snapshot], now: now))
        #expect(snapshot.consumptionFraction == 0.2)
        #expect(snapshot.displayBars.count == 1)
        #expect(snapshot.status == .measured(.none))
        #expect(row.combinedAccessibilityLabel(windows: nil, forecast: nil, creditsStale: false)
            .contains("Monthly promo credit, $0.00 left, subscription month ends in 12 days"))
        snapshot.staleReading = StaleReading(reason: .offline, at: now)
        let stale = try #require(MetricRowPresentation(snapshot: snapshot, now: now).monthlyPromo)
        #expect(stale.fraction == p.fraction)
        #expect(stale.spoken.contains("stale, the last poll failed"))
    }

    @Test("missing limit or date never invents a bar, marker or countdown")
    func missingPublishedFacts() {
        let uncapped = MonthlyPromoCreditPresentation(entry: entry(limit: nil, end: end), now: now, isStale: false)
        #expect(uncapped.fraction == nil)
        #expect(uncapped.paceMarker == nil)
        #expect(uncapped.dayCountdown == "12d")
        let noDate = MonthlyPromoCreditPresentation(entry: entry(), now: now, isStale: false)
        #expect(noDate.fraction == 1)
        #expect(noDate.paceMarker == nil)
        #expect(noDate.dayCountdown == nil)
        let noLimit = MonthlyPromoCreditPresentation(entry: entry(limit: 0, end: end), now: now, isStale: false)
        #expect(noLimit.fraction == nil)
        #expect(noLimit.paceMarker == nil)
        for promo in [entry(limit: nil, end: end), entry(), entry(limit: 0, end: end)] {
            var snapshot = QuotaSnapshot(id: "claude", vendorId: .claude, displayName: "Claude",
                category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
                status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
            snapshot.apiCredits = [promo]
            #expect(!MetricSectionView.showsPaceLegend(for: [snapshot], now: now))
        }
    }

    @Test("the promo colour uses the tick it draws, including at exhaustion")
    func promoColors() {
        let spent = MonthlyPromoCreditPresentation(entry: entry(end: end), now: now, isStale: false)
        #expect(spent.paceMarker != nil)
        #expect(DualBarProgressView.stateColor(for: spent.barMetrics,
            presentedPaceMarker: spent.paceMarker) == Theme.errorBold)
        let nearlySpent = MonthlyPromoCreditPresentation(entry: entry(balance: Decimal(string: "0.01")!, end: end),
            now: now, isStale: false)
        #expect(nearlySpent.isExhausted)
        #expect(MonthlyPromoCreditView.figureColor(for: nearlySpent) == Theme.error)
        let ahead = MonthlyPromoCreditPresentation(entry: entry(balance: 10, end: end), now: now, isStale: false)
        #expect(DualBarProgressView.stateColor(for: ahead.barMetrics,
            presentedPaceMarker: ahead.paceMarker) == Color(red: 0.96, green: 0.72, blue: 0.15))
    }

    @Test("the promo uses the shared calendar month across Sydney daylight saving")
    func daylightSavingMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Australia/Sydney"))
        let end = date("2026-10-15T00:00:00+11:00")
        let p = MonthlyPromoCreditPresentation(entry: entry(end: end),
            now: date("2026-09-30T00:00:00+10:00"), isStale: false, calendar: calendar)
        let length = try #require(p.barMetrics.windowLength)
        #expect(abs(length - (30 * 86_400.0 - 3600)) < 0.00001)
        let marker = try #require(p.paceMarker)
        let expectedMarker = (15 * 86_400.0) / (30 * 86_400.0 - 3600)
        #expect(abs(marker - expectedMarker) < 0.00001)
        #expect(p.dayCountdown == "15d")
    }

    @Test("calendar month length, partial days and passed periods retain the published end")
    func calendarBoundaries() throws {
        let leapEnd = date("2028-03-01T00:00:00Z")
        let halfway = MonthlyPromoCreditPresentation(entry: entry(balance: 25, end: leapEnd),
            now: date("2028-02-15T12:00:00Z"), isStale: false)
        #expect(halfway.fraction == 0.75)
        #expect(halfway.paceMarker == 0.5)
        #expect(halfway.dayCountdown == "15d")
        #expect(halfway.barMetrics.isMeaningfullyAheadOfPace)
        let passed = MonthlyPromoCreditPresentation(entry: entry(end: end),
            now: end.addingTimeInterval(1), isStale: false)
        #expect(passed.dayCountdown == "0d")
        #expect(passed.paceMarker == nil)
        #expect(passed.fraction == 1)
        let before = MonthlyPromoCreditPresentation(entry: entry(end: end),
            now: date("2026-10-01T00:00:00Z"), isStale: false)
        #expect(before.paceMarker == nil)
    }

    @Test("ticket strip and exact usage credits fit one line at the title inset")
    @MainActor
    func creditLineFits() {
        var snapshot = QuotaSnapshot(id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        snapshot.apiCredits = [APICreditEntry(id: "openai.api-credits", vendorId: .openai,
            label: "Usage credits", metric: .credits(remaining: Decimal(string: "60085.422977")!, unitName: "credits"))]
        let creditOnly = NSHostingView(rootView: MetricRowView(snapshot: snapshot, isGrouped: true).frame(width: 332))
        let creditOnlyHeight = creditOnly.fittingSize.height
        for count in [2, 5, 7] {
            snapshot.resetCreditsAvailable = count
            let p = MetricRowPresentation(snapshot: snapshot, now: now)
            let natural = NSHostingView(rootView: SubscriptionCreditLineView(presentation: p).fixedSize())
            let constrained = NSHostingView(rootView: SubscriptionCreditLineView(presentation: p).frame(width: 332))
            #expect(natural.fittingSize.width <= 332)
            #expect(constrained.fittingSize.height < 22)
            let row = NSHostingView(rootView: MetricRowView(snapshot: snapshot, isGrouped: true).frame(width: 332))
            #expect(abs(row.fittingSize.height - creditOnlyHeight) < 1)
        }
    }

    @Test("the production Claude row actually draws its promo credit")
    @MainActor
    func promoIsRenderedInsideRow() {
        var snapshot = QuotaSnapshot(id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        let without = NSHostingView(rootView: MetricRowView(snapshot: snapshot).frame(width: 332)).fittingSize.height
        snapshot.apiCredits = [entry(end: end)]
        let withPromo = NSHostingView(rootView: MetricRowView(snapshot: snapshot).frame(width: 332)).fittingSize.height
        #expect(withPromo - without > 40)
    }
}
