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
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

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
        #expect(p.percentText == "100%")
        #expect(p.resetText == "Resets in 12 days")
        #expect(p.fraction == 1)
        #expect(abs(try #require(p.paceMarker) - 19.0 / 31) < 0.00001)
        #expect(p.dayCountdown == "12d")
        #expect(MetricSectionView.showsPaceLegend(for: [snapshot], now: now))
        #expect(snapshot.consumptionFraction == 0.2)
        #expect(snapshot.displayBars.count == 1)
        #expect(snapshot.status == .measured(.none))
        #expect(row.combinedAccessibilityLabel(windows: nil, forecast: nil, creditsStale: false)
            .contains("Usage credits, 100% used, resets in 12 days"))
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
    @MainActor
    func promoColors() {
        let spent = MonthlyPromoCreditPresentation(entry: entry(end: end), now: now, isStale: false)
        #expect(spent.paceMarker != nil)
        // Quota-window policy hides a spent window's tick; the promo row
        // presents its own, and that is what the bar draws.
        #expect(spent.barMetrics.paceMarker == nil)
        #expect(DualBarProgressView(metrics: spent.barMetrics, showsLabel: false,
            presentedPaceMarker: spent.paceMarker).drawnPaceMarker == spent.paceMarker)
        #expect(DualBarProgressView.stateColor(for: spent.barMetrics,
            presentedPaceMarker: spent.paceMarker) == Theme.errorBold)
        let nearlySpent = MonthlyPromoCreditPresentation(entry: entry(balance: Decimal(string: "0.01")!, end: end),
            now: now, isStale: false)
        #expect(nearlySpent.isExhausted)
        #expect(MonthlyPromoCreditView.figureColor(for: nearlySpent) ==
            DualBarProgressView.stateColor(for: nearlySpent.barMetrics,
                                           presentedPaceMarker: nearlySpent.paceMarker))
        let ahead = MonthlyPromoCreditPresentation(entry: entry(balance: 10, end: end), now: now, isStale: false)
        #expect(DualBarProgressView.stateColor(for: ahead.barMetrics,
            presentedPaceMarker: ahead.paceMarker) == Color(red: 0.96, green: 0.72, blue: 0.15))
    }

    @Test("the promo row draws its even-use tick even when fully used")
    @MainActor
    func renderedSpentMarker() throws {
        func whitePixels(_ presentation: MonthlyPromoCreditPresentation) throws -> Int {
            let host = NSHostingView(rootView: MonthlyPromoCreditView(presentation: presentation)
                .frame(width: 332).background(Theme.card).environment(\.colorScheme, .dark))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.redComponent > 0.9, c.greenComponent > 0.9, c.blueComponent > 0.9 { count += 1 }
                }
            }
            return count
        }
        let spent = MonthlyPromoCreditPresentation(entry: entry(end: end), now: now, isStale: false)
        let withoutMarker = MonthlyPromoCreditPresentation(entry: entry(end: nil), now: now, isStale: false)
        #expect(withoutMarker.paceMarker == nil)
        // The tick is the only near-white mark in the row; its fill, figure
        // and labels are all darker tones.
        #expect(try whitePixels(spent) > whitePixels(withoutMarker) + 8)
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

    @Test("ticket expiry lines fit the name column and preserve a separate balance fallback")
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
            let natural = NSHostingView(rootView: SubscriptionCreditLineView(presentation: p, showsTickets: false).fixedSize())
            let constrained = NSHostingView(rootView: SubscriptionCreditLineView(presentation: p, showsTickets: false).frame(width: 332))
            #expect(natural.fittingSize.width <= 332)
            #expect(constrained.fittingSize.height < 22)
            let tickets = NSHostingView(rootView: ResetTicketsView(credits: p.resetCredits!).frame(width: 112))
            #expect(tickets.fittingSize.width == 112)
            #expect(tickets.fittingSize.height >= CGFloat(min(count, ResetCreditTicketLimit.maxCount)) * 12)
            #expect(tickets.fittingSize.height < 125)
            let row = NSHostingView(rootView: MetricRowView(snapshot: snapshot, isGrouped: true).frame(width: 332))
            #expect(row.fittingSize.width == 332)
            #expect(row.fittingSize.height > creditOnlyHeight)
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
        #expect(withPromo - without > 30)
    }

    /// The OpenAI grant is the same monthly-credit anatomy as Claude's promo.
    /// Its grant issue date is not the subscription cycle start, so the row
    /// derives a calendar month ending at the subscription cycle end.
    @Test("the OpenAI monthly grant uses the subscription month and draws in the row")
    @MainActor
    func openAIMonthlyCredit() throws {
        let start = date("2026-10-19T00:25:31Z")
        let end = date("2026-11-19T00:25:31Z")
        let credit = OpenAIMonthlyCredit(
            grantUSD: 200, remainingUSD: 50, periodStart: start, periodEnd: end,
            measuredAt: date("2026-11-09T00:25:31Z"))
        let entry = credit.entry
        let presentation = MonthlyPromoCreditPresentation(
            entry: entry, now: date("2026-11-09T00:25:31Z"), isStale: false,
            calendar: utc)
        #expect(entry.isMonthlyPromo)
        #expect(entry.extendsSubscription)
        // The grant's issue date is not the billing cycle's start.
        #expect(entry.monthlyPeriodStart == nil)
        #expect(presentation.fraction == 0.75)
        #expect(presentation.percentText == "75%")
        #expect(presentation.resetText == "Resets in 10 days")
        #expect(presentation.dayCountdown == "10d")
        #expect(try #require(presentation.barMetrics.windowLength) == 31 * 86_400.0)
        #expect(abs(try #require(presentation.paceMarker) - 21.0 / 31) < 0.00001)
        #expect(presentation.spoken.contains("$50.00 of $200.00 remaining"))

        var snapshot = QuotaSnapshot(id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.2, label: "5H"))
        let without = NSHostingView(rootView: MetricRowView(snapshot: snapshot, isGrouped: true)
            .frame(width: 332)).fittingSize.height
        snapshot.openAIMonthlyCredit = credit
        let row = MetricRowPresentation(snapshot: snapshot, now: date("2026-11-09T00:25:31Z"))
        let promo = try #require(row.monthlyPromo)
        #expect(promo.fraction == 0.75)
        #expect(row.subscriptionCredits.isEmpty)
        // The grant is a presentation row only: the quota reading is unchanged.
        #expect(snapshot.row1?.primaryFraction == 0.2)
        #expect(snapshot.status == .measured(.none))
        #expect(row.combinedAccessibilityLabel(windows: nil, forecast: nil, creditsStale: false)
            .contains("Monthly credit, 75% used"))
        // The billing read is independent: a quota outage does not make this
        // grant stale. Only the session's own failed refresh does.
        var quotaStale = snapshot
        quotaStale.staleReading = StaleReading(reason: .offline, at: now)
        let current = try #require(MetricRowPresentation(snapshot: quotaStale,
            now: date("2026-11-09T00:25:31Z")).monthlyPromo)
        #expect(!current.spoken.contains("stale"))
        var failedCredit = credit
        failedCredit.refreshFailed = true
        var billingFailed = snapshot
        billingFailed.openAIMonthlyCredit = failedCredit
        let stale = try #require(MetricRowPresentation(snapshot: billingFailed,
            now: date("2026-11-09T00:25:31Z")).monthlyPromo)
        #expect(stale.spoken.contains("stale, the last poll failed"))
        let withPromo = NSHostingView(rootView: MetricRowView(snapshot: snapshot, isGrouped: true)
            .frame(width: 332)).fittingSize.height
        #expect(withPromo - without > 30)
    }

    /// The API-credits grant is prorated from its issue date, but the row is a
    /// month of the subscription. The marker must follow the billing cycle
    /// (19 Oct–19 Nov), not the 18-day prorated grant (1–19 Nov).
    @Test("a prorated OpenAI grant keeps the subscription month's pace")
    func proratedGrantUsesSubscriptionMonth() throws {
        let credit = OpenAIMonthlyCredit(
            grantUSD: 116, remainingUSD: 116,
            periodStart: date("2026-11-01T02:15:38Z"),
            periodEnd: date("2026-11-19T00:25:31Z"),
            measuredAt: date("2026-11-01T12:00:00Z"))
        let entry = credit.entry
        #expect(entry.monthlyPeriodStart == nil)
        let presentation = MonthlyPromoCreditPresentation(
            entry: entry, now: date("2026-11-01T12:00:00Z"), isStale: false,
            calendar: utc)
        #expect(try #require(presentation.barMetrics.windowLength) == 31 * 86_400.0)
        let marker = try #require(presentation.paceMarker)
        // 19 Oct 00:25:31 → 1 Nov 12:00 is ~13.48 of 31 days.
        #expect(marker > 0.40 && marker < 0.50)
    }

    /// The OpenAI grant publishes no cycle start. The row falls back to the
    /// local calendar month ending at the cycle end, so across a DST change
    /// that window is an hour longer than the fixed-offset billing cycle.
    /// Pin the documented approximation rather than claiming an exact cycle.
    @Test("an OpenAI grant uses the calendar-month approximation across DST")
    func openAICalendarMonthApproximationAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let end = date("2026-11-19T00:25:31Z")
        let entry = APICreditEntry(
            id: "openai.monthly-credit", vendorId: .openai, label: "Monthly credit",
            metric: .currency(balance: 100, limit: 200, spent: nil, currencyCode: "USD"),
            currencyBasis: .prepaidCredit, monthlyPeriodEnd: end)
        let presentation = MonthlyPromoCreditPresentation(
            entry: entry, now: date("2026-11-09T00:25:31Z"), isStale: false,
            calendar: calendar)
        // 18 Oct 19:25:31 EDT → 19 Nov 00:25:31Z is 31 days plus the DST hour.
        #expect(try #require(presentation.barMetrics.windowLength) == 31 * 86_400.0 + 3_600)
        let marker = try #require(presentation.paceMarker)
        #expect(abs(marker - 21.0 / 31) < 0.001)
    }

    /// A 30-day grant must not borrow a 31-day calendar month: the exact
    /// published span is the only length its even-use marker may use.
    @Test("an exact grant span wins over the calendar-month fallback")
    func exactGrantSpan() throws {
        let start = date("2026-10-10T00:00:00Z")
        let end = date("2026-11-09T00:00:00Z")
        let presentation = MonthlyPromoCreditPresentation(
            entry: APICreditEntry(
                id: "openai.monthly-credit", vendorId: .openai, label: "Monthly credit",
                metric: .currency(balance: 100, limit: 200, spent: nil, currencyCode: "USD"),
                currencyBasis: .prepaidCredit, monthlyPeriodEnd: end, monthlyPeriodStart: start),
            now: date("2026-10-25T00:00:00Z"), isStale: false)
        #expect(try #require(presentation.barMetrics.windowLength) == 30 * 86_400.0)
        #expect(abs(try #require(presentation.paceMarker) - 0.5) < 0.00001)
        #expect(presentation.fraction == 0.5)
    }
}
