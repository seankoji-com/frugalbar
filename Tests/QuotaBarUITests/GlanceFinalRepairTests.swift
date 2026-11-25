import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// The continuation's final repair: allowances that have expired, readings
/// that are not current, and Wallet figures that must not claim more than
/// they are.
@Suite("Final repair: expiry, currency of figures, Wallet roles")
struct GlanceFinalRepairTests {
    private typealias Fixtures = GlanceFixtures
    private let now = GlanceFixtures.now

    @Test("an expired bonus is not open, so it is never 'Best available'")
    func expiredBonusIsNotAPick() {
        let kiro = Fixtures.snapshot("kiro", .kiro, "Kiro", [
            Fixtures.bar("MO", 1.0, resetsInHours: 300, windowHours: 720),
            Fixtures.bar("BN", 0.3, resetsInHours: -2, windowHours: nil, role: .bonus),
        ])
        let glance = GlancePresentation(snapshots: [kiro], now: now)
        #expect(glance.pools.first?.state == .spent)
        #expect(glance.ranking.isEmpty)
    }

    @Test("a pool on its bonus is counted 'on bonus', not 'usable'")
    func onBonusSubtitle() {
        let kiro = Fixtures.snapshot("kiro", .kiro, "Kiro", [
            Fixtures.bar("MO", 1.0, resetsInHours: 300, windowHours: 720),
            Fixtures.bar("BN", 0.3, resetsInHours: 100, windowHours: nil, role: .bonus),
        ])
        let grid = ProviderGridPresentation(snapshots: [kiro], serviceOrder: [], now: now)
        #expect(grid.groups.first?.subtitle == "0 usable · 1 on bonus")
    }

    @Test("an expired window leads the inspector, with no forecast or pace from another window")
    func inspectorFocusesExpiredWindow() {
        let snapshot = Fixtures.snapshot("claude", .claude, "Claude", [
            Fixtures.bar("5H", 0.2, resetsInHours: -0.5, windowHours: 5),
            Fixtures.bar("WK", 0.7, resetsInHours: 60, windowHours: 168),
        ])
        let summary = MetricDetailPresentation(snapshot: snapshot, now: now).summary
        guard case .awaitingReading = summary.state else {
            Issue.record("expected .awaitingReading, got \(summary.state)")
            return
        }
        #expect(summary.focusLabel == "5H")
        #expect(summary.paceVerdict == nil)
    }

    @Test("a spent window that has since reset awaits a reading, not 'Exhausted'")
    func resetSpentWindowAwaitsReading() {
        let snapshot = Fixtures.snapshot("claude", .claude, "Claude", [
            Fixtures.bar("WK", 1.0, resetsInHours: -1, windowHours: 168),
        ], urgency: .critical)
        guard case .awaitingReading = MetricDetailPresentation(snapshot: snapshot, now: now).summary.state else {
            Issue.record("a reset spent window still read as exhausted")
            return
        }
    }

    @Test("group averages count only pools whose figures describe now")
    func averagesSkipAwaitingPools() {
        let current = Fixtures.snapshot("claude-a", .claude, "A", [Fixtures.bar("WK", 0.2, resetsInHours: 60, windowHours: 168)])
        let expired = Fixtures.snapshot("claude-b", .claude, "B", [Fixtures.bar("WK", 0.9, resetsInHours: -1, windowHours: 168)])
        let grid = ProviderGridPresentation(snapshots: [current, expired], serviceOrder: [], now: now)
        #expect(grid.groups.first?.summary(for: .weekly) == .average(remaining: 0.8, reported: 1, count: 2))
    }

    @Test("a balance figure that already says what it is gets no 'left' under it")
    func walletRoleNeverContradictsTheFigure() {
        #expect(WalletPresentation.role(for: .currency(balance: 12, limit: nil, spent: nil, currencyCode: "USD"),
                                        label: "$12.00 spent", basis: .lifetimeSpend) == nil)
        #expect(WalletPresentation.role(for: .currency(balance: 3, limit: 10, spent: nil, currencyCode: "USD"),
                                        label: "$3.00 left of $10.00") == nil)
        #expect(WalletPresentation.role(for: .currency(balance: 42, limit: nil, spent: nil, currencyCode: "USD"),
                                        label: "$42.00") == "left")
        #expect(WalletPresentation.role(for: .currency(balance: -1, limit: nil, spent: nil, currencyCode: "USD"),
                                        label: "-$1.00") == nil)
    }
}
