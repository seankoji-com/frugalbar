import AppKit
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Configured Gemini API credit placement")
@MainActor
struct GeminiAPICreditPlacementTests {

    private let now = ISO8601DateFormatter().date(from: "2026-11-20T13:00:00Z")!
    private let configuredAt = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!

    private func credit() throws -> GeminiAPICredit {
        try #require(GeminiAPICredit(
            currencyCode: "AUD",
            prepaidBalance: Decimal(string: "12")!,
            monthlyCredit: Decimal(string: "7.50")!,
            monthlySpendCap: Decimal(string: "25")!,
            configuredAt: configuredAt))
    }

    private func snapshot(_ vendor: VendorIdentifier, credit: GeminiAPICredit? = nil,
                          status: ProviderStatus = .measured(.none)) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(
            id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
            status: status, resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: status.confidence == .measured
                ? DualBarMetrics(primaryFraction: 0.25, label: "5H", windowLength: QuotaWindow.fiveHours)
                : nil,
            row2: status.confidence == .measured
                ? DualBarMetrics(primaryFraction: 0.4, label: "WK", windowLength: QuotaWindow.week)
                : nil,
            planName: "Google AI Pro")
        snapshot.geminiAPICredit = credit
        return snapshot
    }

    @Test("the configured credit draws only the API credit line")
    func drawsOnlyTheBudget() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let p = try #require(GeminiAPICreditPresentation(
            credit: try credit(), now: now, calendar: utc))

        #expect(p.budget.amountText == "A$25.00")
        #expect(p.spoken.contains("API credit A$25.00"))
        #expect(p.spoken.contains("configured 20 November 2026"))
        #expect(p.spoken.contains("not a vendor reading"))
        // The prepaid balance and monthly grant stay in Settings, not the row.
        #expect(!p.spoken.contains("Prepaid balance"))
        #expect(!p.spoken.contains("A$12.00"))
        #expect(!p.spoken.contains("A$7.50"))
    }

    @Test("the spend cap is a monthly API credit line, filled with calendar time")
    func budgetIsCalendarMonthProgress() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let p = try #require(GeminiAPICreditPresentation(
            credit: try credit(), now: now, calendar: utc))
        let budget = p.budget

        // 20 Nov 13:00 UTC is 19 days 13 hours into November's 30 days.
        let expected = (19.0 + 13.0 / 24.0) / 30.0
        #expect(abs(budget.fraction - expected) < 0.00001)
        #expect(budget.percentText == "65%")
        #expect(budget.countdown == "11d")
        #expect(budget.spoken.contains("API credit A$25.00"))
        #expect(budget.spoken.contains("65% of the calendar month elapsed"))
        #expect(budget.spoken.contains("11 days left in the month"))
        // The bar is time, never spend: Google publishes no API-key spend.
        #expect(budget.spoken.contains("not spend"))
        #expect(p.spoken.contains(budget.spoken))
    }

    @Test("the budget fill never reads the prepaid balance or the monthly credit")
    func budgetIsNotABalanceFraction() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let configured = try credit()
        let different = try #require(GeminiAPICredit(
            currencyCode: "AUD", prepaidBalance: 0, monthlyCredit: 0,
            monthlySpendCap: Decimal(string: "25")!, configuredAt: configuredAt))
        let a = try #require(GeminiAPICreditPresentation(
            credit: configured, now: now, calendar: utc))
        let b = try #require(GeminiAPICreditPresentation(
            credit: different, now: now, calendar: utc))

        #expect(a.budget == b.budget)
        // A balance-derived fill would draw 100% at an empty balance; a
        // cap-derived fill would ignore the month entirely.
        let fraction = a.budget.fraction
        #expect(fraction != 1)
        #expect(abs(fraction - 0.5) > 0.1)
    }

    @Test("a credit without a cap draws nothing and keeps its figures in Settings")
    func noCapNoBudget() throws {
        let noCap = try #require(GeminiAPICredit(
            currencyCode: "AUD", prepaidBalance: 12, monthlyCredit: Decimal(string: "7.50")!,
            monthlySpendCap: nil, configuredAt: configuredAt))
        #expect(GeminiAPICreditPresentation(credit: noCap, now: now) == nil)
    }

    @Test("the Gemini settings prompt distinguishes empty input from a bad amount")
    func settingsPrompt() throws {
        #expect(GeminiAPICreditSettingsView.problem(
            credit: nil, balance: .empty, monthly: .empty, cap: .empty,
            currencyCode: "AUD") == .empty)
        #expect(GeminiAPICreditSettingsView.problem(
            credit: nil, balance: .invalid, monthly: .empty, cap: .empty,
            currencyCode: "AUD") == .invalid)
        #expect(GeminiAPICreditSettingsView.problem(
            credit: nil, balance: .empty, monthly: .empty, cap: .empty,
            currencyCode: "AUDX") == .invalid)
        let capOnly = try #require(GeminiAPICredit(
            currencyCode: "AUD", monthlySpendCap: 25, configuredAt: configuredAt))
        #expect(GeminiAPICreditSettingsView.problem(
            credit: capOnly, balance: .empty, monthly: .empty, cap: .value(25),
            currencyCode: "AUD") == .none)
    }

    @Test("the budget countdown counts calendar days across a fall-back month")
    func budgetCountdownAcrossFallBack() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 1 Nov 2026 00:00 PDT; the month ends 1 Dec 00:00 PST, 30 days later
        // plus one hour. Dividing seconds rounded that up to 31d.
        let start = try #require(ISO8601DateFormatter().date(from: "2026-11-01T07:00:00Z"))
        let p = try #require(GeminiAPICreditPresentation(
            credit: try credit(), now: start, calendar: calendar))
        #expect(p.budget.countdown == "30d")
        #expect(p.budget.percentText == "0%")
    }

    @Test("the budget meter follows the calendar month, including February")
    func budgetCalendarBoundaries() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let february = try #require(ISO8601DateFormatter().date(from: "2028-02-15T00:00:00Z"))
        let p = try #require(GeminiAPICreditPresentation(
            credit: try credit(), now: february, calendar: utc))
        let budget = p.budget
        #expect(abs(budget.fraction - 14.0 / 29.0) < 0.00001)
        #expect(budget.percentText == "48%")
        #expect(budget.countdown == "15d")
    }

    @Test("only the Gemini row carries the configured credit")
    func onlyGeminiHostsIt() throws {
        let configured = try credit()
        let gemini = MetricRowPresentation(snapshot: snapshot(.gemini, credit: configured), now: now)
        #expect(gemini.geminiAPICredit?.budget.amountText == "A$25.00")
        #expect(gemini.subscriptionCredits.isEmpty)

        let argon = MetricRowPresentation(
            snapshot: snapshot(.antigravityArgon, credit: configured), now: now)
        let claude = MetricRowPresentation(
            snapshot: snapshot(.antigravityClaude, credit: configured), now: now)
        #expect(argon.geminiAPICredit == nil)
        #expect(claude.geminiAPICredit == nil)

        // It is not an API-credit entry, so the separate credits card and the
        // balance-history reader never see it.
        #expect(snapshot(.gemini, credit: configured).apiCredits.isEmpty)
        #expect(BalanceSeries.all(of: snapshot(.gemini, credit: configured)).isEmpty)

        #expect(MetricRowPresentation(snapshot: snapshot(.gemini), now: now).geminiAPICredit == nil)
    }

    @Test("the configured line is spoken on a measured row and an unavailable one")
    func spokenOnBothStates() throws {
        let configured = try credit()
        func label(_ status: ProviderStatus) -> String {
            MetricRowPresentation(snapshot: snapshot(.gemini, credit: configured, status: status), now: now)
                .combinedAccessibilityLabel(windows: nil, forecast: nil, creditsStale: false)
        }
        for status: ProviderStatus in [.measured(.none), .unavailable(.badResponse)] {
            let text = label(status)
            #expect(text.contains("API credit A$25.00"))
            #expect(text.contains("not a vendor reading"))
            #expect(!text.contains("Prepaid balance"))
            #expect(!text.contains("A$12.00"))
            #expect(!text.contains("A$7.50"))
            // The budget line is spoken once, not once from the unavailable
            // base label and again from the combined label.
            #expect(text.components(separatedBy: "API credit A$25.00").count == 2)
        }
    }

    @Test("the configured line adds height without changing the quota presentation")
    func addsHeightWithoutChangingQuota() throws {
        func height(_ credit: GeminiAPICredit?) -> CGFloat {
            let row = MetricRowView(snapshot: snapshot(.gemini, credit: credit))
                .frame(width: Theme.popoverWidth - 2 * Theme.edgeMargin - 2 * Theme.cardPadding)
            let host = NSHostingView(rootView: row)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let without = height(nil)
        let with = height(try credit())
        #expect(with > without)

        let plain = MetricRowPresentation(snapshot: snapshot(.gemini), now: now)
        let configured = MetricRowPresentation(
            snapshot: snapshot(.gemini, credit: try credit()), now: now)
        #expect(plain.fraction == configured.fraction)
        #expect(plain.urgency == configured.urgency)
        #expect(plain.valueLabel == configured.valueLabel)
        #expect(plain.isExhausted == configured.isExhausted)
        #expect(configured.geminiAPICredit != nil)
    }

    @Test("the budget line adds its own height")
    @MainActor
    func budgetAddsHeight() throws {
        func height(_ credit: GeminiAPICredit?) -> CGFloat {
            let row = MetricRowView(snapshot: snapshot(.gemini, credit: credit))
                .frame(width: Theme.popoverWidth - 2 * Theme.edgeMargin - 2 * Theme.cardPadding)
            let host = NSHostingView(rootView: row)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let withoutCap = try #require(GeminiAPICredit(
            currencyCode: "AUD", prepaidBalance: 12, monthlyCredit: Decimal(string: "7.50")!,
            monthlySpendCap: nil, configuredAt: configuredAt))
        // A credit with no cap draws nothing, so the saved cap is the whole line.
        #expect(height(try credit()) > height(withoutCap))
    }

    @Test("the configured credit stays inside the Antigravity service block")
    func groupingUnchanged() throws {
        let configured = try credit()
        let snapshots = [snapshot(.gemini, credit: configured),
                         snapshot(.antigravityArgon, credit: configured),
                         snapshot(.antigravityClaude, credit: configured)]
        let groups = PopoverRowGrouping.groups(for: snapshots)
        #expect(groups.count == 1)
        #expect(groups.first?.header == "Antigravity")
        #expect(groups.first?.snapshots.map(\.vendorId)
            == [.gemini, .antigravityArgon, .antigravityClaude])
        #expect(groups.first?.snapshots.first?.geminiAPICredit == configured)
        // The field is attached only to Gemini's row; even a stray value on
        // another pool's snapshot is never drawn as that pool's credit.
        let presentations = (groups.first?.snapshots ?? []).map {
            MetricRowPresentation(snapshot: $0, now: now)
        }
        #expect(presentations.first?.geminiAPICredit != nil)
        #expect(presentations.dropFirst().allSatisfy { $0.geminiAPICredit == nil })
    }
}
