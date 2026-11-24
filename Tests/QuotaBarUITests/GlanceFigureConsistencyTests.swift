import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// One figure, one state, everywhere: the boundaries where a rounded figure
/// or a passed time used to say something the state did not.
@Suite("Glance figures never cross a state boundary")
struct GlanceFigureConsistencyTests {
    private typealias Fixtures = GlanceFixtures
    private let now = GlanceFixtures.now

    @Test("a window under the spent threshold never prints 100%, and a nonzero one never prints 0%")
    func percentBoundaries() {
        #expect(GlancePresentation.usedPercentText(0.995) == "99%")
        #expect(GlancePresentation.usedPercentText(0.9962) == "99%")
        #expect(GlancePresentation.usedPercentText(QuotaSnapshot.exhaustionThreshold) == "100%")
        #expect(GlancePresentation.usedPercentText(1) == "100%")
        #expect(GlancePresentation.usedPercentText(0) == "0%")
        #expect(GlancePresentation.usedPercentText(0.003) == "<1%")
        #expect(GlancePresentation.usedPercentWords(0.003) == "under 1 percent")
        // The inspector's window line prints the popover's figure.
        let line = MetricDetailPresentation.windowLine(Fixtures.bar("WK", 0.9962, resetsInHours: 20, windowHours: 168), now: now)
        #expect(line.percentText == "99%")
        #expect(line.accessibilityLabel.contains("99 percent used"))
    }

    @Test("a passed reset is due, never 'now' or 'resets in now'")
    func passedResetIsDue() {
        let passed = now.addingTimeInterval(-90)
        #expect(GlancePresentation.countdown(passed, now: now) == "due")
        #expect(GlancePresentation.countdown(now.addingTimeInterval(10), now: now) == "<1m")
        #expect(ResetCountdownBadge.compact(passed, now: now) == "due")
        #expect(ResetCountdownBadge.spokenClause(forCompact: "due") == "reset due, awaiting a reading")
        let window = GlancePresentation.window(for: Fixtures.bar("WK", 0.2, resetsInHours: -0.1, windowHours: 168), now: now)
        #expect(!GlancePresentation.reason(window, now: now).contains("in due"))
    }

    @Test("a spent bonus or paid overage never makes a usable plan 'Exhausted' in the inspector")
    func supplementaryNeverDecidesTheVerdict() {
        let kiro = Fixtures.snapshot("kiro", .kiro, "Kiro", [
            Fixtures.bar("MO", 0.3, resetsInHours: 300, windowHours: 720),
            Fixtures.bar("BN", 1.0, resetsInHours: 100, windowHours: nil, role: .bonus),
        ])
        let summary = MetricDetailPresentation(snapshot: kiro, now: now).summary
        #expect(summary.state != .exhausted)
        #expect(summary.focusLabel == "MO")
        #expect(GlancePresentation(snapshots: [kiro], now: now).pools.first?.state == .usable)
    }

    @Test("only balances configured: the menu bar says so, never that a read failed")
    func balanceOnlyMenuTitle() {
        let openRouter = Fixtures.snapshot("openrouter", .openrouter, "OpenRouter", [], category: .apiSpendAndCredits)
        let title = GlancePresentation(snapshots: [openRouter], now: now).menuTitle
        #expect(title.text == "No subscriptions")
        #expect(!title.spoken.contains("could be read"))
    }
}
