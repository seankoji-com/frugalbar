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

    @Test("each pool keeps its own label and the account's own money format")
    func figuresAreLabelledApart() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let p = GeminiAPICreditPresentation(credit: try credit(), calendar: utc)

        #expect(p.figures.map(\.label) == ["Prepaid balance", "Monthly credit", "Monthly spend cap"])
        #expect(p.figures.map(\.figure) == ["A$12.00", "A$7.50", "A$25.00"])
        #expect(p.configuredNote == "Configured 20 Nov 2026")
        #expect(p.spoken.contains("not a vendor reading"))
        #expect(p.spoken.contains("Prepaid balance A$12.00"))
        #expect(p.spoken.contains("Monthly credit A$7.50"))
        #expect(p.spoken.contains("Monthly spend cap A$25.00"))
    }

    @Test("only the Gemini row carries the configured credit")
    func onlyGeminiHostsIt() throws {
        let configured = try credit()
        let gemini = MetricRowPresentation(snapshot: snapshot(.gemini, credit: configured), now: now)
        #expect(gemini.geminiAPICredit?.figures.count == 3)
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
            #expect(text.contains("Gemini API credit"))
            #expect(text.contains("not a vendor reading"))
            #expect(text.contains("A$12.00"))
            #expect(text.contains("A$7.50"))
            #expect(text.contains("A$25.00"))
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
