import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// "Blocked" has one definition (`QuotaSnapshot.isAccountBlocked`, read
/// through `GlancePresentation.Pool.isBlocked`). Three rounds each found a
/// surface that derived it on its own and missed the account badge; this
/// asks every surface about the same account-blocked pool at once.
@Suite("Account-level block reads the same everywhere")
struct AccountBlockedConsistencyTests {
    private typealias Fixtures = GlanceFixtures
    private let now = GlanceFixtures.now

    /// Command Code's `limited`: windows well under 100%, the account stopped.
    private var limited: QuotaSnapshot {
        Fixtures.snapshot("commandcode", .commandcode, "Command Code", [
            Fixtures.bar("5H", 0.2, resetsInHours: 3, windowHours: 5),
            Fixtures.bar("WK", 0.4, resetsInHours: 48, windowHours: 168),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
    }

    private var usableOpenCode: QuotaSnapshot {
        Fixtures.snapshot("opencode-go:a", .opencode, "Workspace A", [
            Fixtures.bar("5H", 0.1, resetsInHours: 3, windowHours: 5),
        ])
    }

    @Test("glance pool, Back soon, grid subtitle and inspector all say blocked")
    func everySurfaceAgrees() throws {
        let glance = GlancePresentation(snapshots: [limited, usableOpenCode], now: now)
        let pool = try #require(glance.pools.first { $0.id == "commandcode" })
        #expect(pool.state == .spent)
        #expect(pool.isBlocked)
        #expect(glance.backSoon.first { $0.pool.id == "commandcode" }?.isBlocked == true)
        #expect(!glance.ranking.contains { $0.pool.id == "commandcode" })

        let grid = ProviderGridPresentation(snapshots: [limited, usableOpenCode],
                                            serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now)
        let group = try #require(grid.groups.first { $0.id == .deepseek })
        let gridPool = try #require(group.pools.first { $0.id == "commandcode" })
        #expect(gridPool.isBlocked)
        #expect(group.subtitle == "1 usable · 1 blocked")
        // Its cells draw blocked, not as healthy 20% / 40% bars, and its
        // figures are not averaged into the group as headroom.
        #expect(!gridPool.windows.isEmpty && gridPool.windows.values.allSatisfy { $0.isSpent && $0.bar.isBlocked })
        #expect(group.summary(for: .fiveHour) == .average(remaining: 0.9, reported: 1, count: 2))

        let solo = ProviderGridPresentation(snapshots: [limited],
                                            serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now)
        #expect(solo.groups.first?.subtitle == "1 blocked")

        let inspector = MetricDetailPresentation(snapshot: limited, now: now)
        #expect(inspector.summary.state == .blocked)
        #expect(inspector.summary.headline == "Blocked by the vendor")
    }

    @Test("a pool the user exhausted is spent, not blocked")
    func exhaustedIsNotBlocked() throws {
        let spent = Fixtures.snapshot("commandcode", .commandcode, "Command Code", [
            Fixtures.bar("WK", 1.0, resetsInHours: 48, windowHours: 168),
        ], badge: "Exhausted", urgency: .critical)
        let glance = GlancePresentation(snapshots: [spent], now: now)
        #expect(glance.pools.first?.isBlocked == false)
        let grid = ProviderGridPresentation(snapshots: [spent],
                                            serviceOrder: ProviderDisplayPreferences.defaultOrder, now: now)
        #expect(grid.groups.first?.subtitle == "1 spent")
        #expect(MetricDetailPresentation(snapshot: spent, now: now).summary.state == .exhausted)
    }
}
