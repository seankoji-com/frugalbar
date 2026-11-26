import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// One answer to "do these figures describe now?" (`GlancePresentation.Freshness`),
/// read by the pick, the menu bar, the grid, the inspector and the burndown.
@Suite("Freshness: a pool's figures describe now, or say they do not")
struct GlanceFreshnessTests {
    private typealias Fixtures = GlanceFixtures
    private let now = GlanceFixtures.now

    /// A weekly window whose published reset passed an hour ago, no reading since.
    private var expired: QuotaSnapshot {
        Fixtures.snapshot("claude-primary", .claude, "Primary",
                          [Fixtures.bar("WK", 0.45, resetsInHours: -1, windowHours: 168)])
    }
    private var codex: QuotaSnapshot {
        Fixtures.snapshot("codex", .openai, "Codex", [Fixtures.bar("WK", 0.34, resetsInHours: 120, windowHours: 168)])
    }

    @Test("an expired window's pool is awaiting a reading, never a pick or 'Healthy'")
    func expiredWindowIsNotCurrent() throws {
        let glance = GlancePresentation(snapshots: [expired], now: now)
        let pool = try #require(glance.pools.first)
        #expect(pool.freshness == .awaitingReset)
        #expect(glance.ranking.isEmpty)
        #expect(glance.menuTitle.tone == .unknown)

        let grid = ProviderGridPresentation(snapshots: [expired], serviceOrder: [], now: now)
        let gridPool = try #require(grid.groups.first?.pools.first)
        #expect(gridPool.isAwaitingReset)
        #expect(!gridPool.isUsable)
        #expect(grid.groups.first?.subtitle?.contains("awaiting reading") == true)

        let summary = MetricDetailPresentation(snapshot: expired, now: now).summary
        guard case .awaitingReading = summary.state else {
            Issue.record("expected .awaitingReading, got \(summary.state)")
            return
        }
        #expect(summary.headline != "Healthy")
        #expect(summary.paceVerdict == nil)

        // A current pool beside it is still the pick.
        let mixed = GlancePresentation(snapshots: [expired, codex], now: now)
        #expect(mixed.ranking.first?.pool.id == "codex")
    }

    @Test("a spent pool whose reset passed reads 'reset passed', not 'return not published'")
    func passedReturnIsOwed() {
        let spent = Fixtures.snapshot("claude-secondary", .claude, "Secondary",
                                      [Fixtures.bar("WK", 1.0, resetsInHours: -0.5, windowHours: 168)],
                                      urgency: .critical)
        let title = GlancePresentation(snapshots: [spent], now: now).menuTitle
        #expect(title.text.contains("reset passed"))
        #expect(!title.text.contains("not published"))
    }

    @Test("a bonus pick says it spends a bonus that expires")
    func bonusPick() throws {
        let kiro = Fixtures.snapshot("kiro", .kiro, "Kiro", [
            Fixtures.bar("MO", 1.0, resetsInHours: 300, windowHours: 720),
            Fixtures.bar("BN", 0.3, resetsInHours: 100, windowHours: nil, role: .bonus),
        ])
        let glance = GlancePresentation(snapshots: [kiro], now: now)
        let pick = try #require(glance.ranking.first)
        #expect(pick.binding.bar.allowanceRole == .bonus)
        #expect(glance.menuTitle.text.contains("on bonus"))
        let useNow = UseNowPresentation(glance: glance)
        #expect(useNow.detail?.hasPrefix("On bonus allowance") == true)
        #expect(useNow.detail?.contains("expires in") == true)
        #expect(useNow.detail?.contains("resets in") == false)
    }

    @Test("with no pick, the popover line counts down in Subscriptions' unit")
    func noPickCountdownMatchesGrid() throws {
        let spent = Fixtures.snapshot("claude-secondary", .claude, "Secondary",
                                      [Fixtures.bar("WK", 1.0, resetsInHours: 38, windowHours: 168)],
                                      urgency: .critical)
        let glance = GlancePresentation(snapshots: [spent], now: now)
        let compact = try #require(ResetCountdownBadge.compact(now.addingTimeInterval(38 * 3600), now: now))
        #expect(UseNowPresentation(glance: glance).headline.contains("next \(compact)"))
        #expect(glance.menuTitle.text.contains("next 38h"))
    }

    @Test("an account block's cells show the block with no window countdown")
    func accountBlockedCellsHaveNoReset() throws {
        let limited = Fixtures.snapshot("commandcode", .commandcode, "Command Code", [
            Fixtures.bar("MO", 0.4, resetsInHours: 48, windowHours: 720),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        let grid = ProviderGridPresentation(snapshots: [limited], serviceOrder: [], now: now)
        let pool = try #require(grid.groups.first?.pools.first)
        #expect(pool.windows.values.allSatisfy { $0.bar.resetsAt == nil && $0.bar.isBlocked })
        let summary = MetricDetailPresentation(snapshot: limited, now: now).summary
        #expect(summary.resetText == nil)
        #expect(summary.remedy?.contains("has not published when the block lifts") == true)
    }

    @Test("a block the vendor dated shows its pool's reset, and every surface agrees")
    func datedAccountBlockKeepsItsReset() throws {
        // Command Code's real shape: both rolling windows read zero with no
        // reset, the credit gauge is spent and publishes its billing-cycle end,
        // and `limited` is set by that pool running out.
        var limited = Fixtures.snapshot("commandcode", .commandcode, "Command Code", [
            Fixtures.bar("5H", 0.0, resetsInHours: nil, windowHours: 5),
            Fixtures.bar("WK", 0.0, resetsInHours: nil, windowHours: 168),
            Fixtures.bar("MO", 0.9995, resetsInHours: 240, windowHours: 720),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        limited.accountBlockIsDated = true
        let reset = now.addingTimeInterval(240 * 3600)

        let glance = GlancePresentation(snapshots: [limited], now: now)
        let pool = try #require(glance.pools.first)
        #expect(pool.state == .spent)
        #expect(pool.isBlocked)
        #expect(pool.returnsAt == reset)
        let back = try #require(glance.backSoon.first)
        #expect(back.returnText == GlancePresentation.countdown(reset, now: now))

        let grid = ProviderGridPresentation(snapshots: [limited], serviceOrder: [], now: now)
        let gridPool = try #require(grid.groups.first?.pools.first)
        // The cell keeps the reset (so its countdown is drawn) and still reads
        // as the block, not as a healthy bar.
        #expect(gridPool.windows[.monthly]?.bar.resetsAt == reset)
        #expect(gridPool.windows[.monthly]?.bar.isBlocked == true)
        #expect(grid.groups.first?.nextReturn == reset)

        let summary = MetricDetailPresentation(snapshot: limited, now: now).summary
        #expect(summary.state == .blocked)
        #expect(summary.resetText != nil)
        #expect(summary.remedy?.contains("until the pool it used up resets") == true)
    }

    @Test("a window the vendor blocked itself keeps its published reset in the cell")
    func vendorBlockedWindowKeepsItsCellReset() throws {
        // The reported OpenCode Go row: the account badge is set and the
        // monthly window the vendor marked `rate-limited` (and still gave a
        // percentage and a reset) drew "⊘ MO" with no countdown at all.
        let limited = Fixtures.snapshot("opencode-go:legacy", .opencode, "OpenCode Go", [
            Fixtures.bar("5H", 0.0, resetsInHours: 5, windowHours: 5),
            Fixtures.bar("WK", 0.0, resetsInHours: 100, windowHours: 168),
            Fixtures.bar("MO", 1.0, resetsInHours: 336, windowHours: 720, blocked: true),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        let reset = now.addingTimeInterval(336 * 3600)

        let grid = ProviderGridPresentation(snapshots: [limited], serviceOrder: [], now: now)
        let group = try #require(grid.groups.first)
        let pool = try #require(group.pools.first)
        let month = try #require(pool.windows[.monthly])
        // Still the block, and now its own date.
        #expect(month.bar.isBlocked)
        #expect(month.bar.resetsAt == reset)
        #expect(grid.countdown(month.bar.resetsAt) != nil)
        #expect(group.nextReturn == reset)
        // The sibling windows the badge alone blocked keep no countdown.
        #expect(pool.windows[.weekly]?.bar.resetsAt == nil)
    }

    @Test("the burndown draws no projection for a pool that is blocked or stale now")
    func burndownCurrentForSnapshot() {
        let reset = now.addingTimeInterval(120 * 3600)
        let burndown = BurndownPresentation.Burndown(
            barLabel: "WK", windowStart: nil, resetsAt: reset, actual: [], ideal: nil,
            projection: [.init(date: now, remainingFraction: 0.5), .init(date: reset, remainingFraction: 0.1)],
            nowRemaining: 0.5, latestReading: nil)
        var stale = codex
        stale.staleReading = StaleReading(reason: .offline, at: now)
        #expect(burndown.current(for: stale, now: now).projection == nil)
        #expect(burndown.current(for: codex, now: now).projection != nil)
    }

    @Test("a recorded projection is dropped once the live snapshot describes another window",
          arguments: ["spent", "new reset", "other window blocked", "reset passed"])
    func burndownProjectionNeedsTheSameUsableWindow(change: String) {
        let reset = now.addingTimeInterval(120 * 3600)
        let burndown = BurndownPresentation.Burndown(
            barLabel: "WK", windowStart: nil, resetsAt: reset, actual: [], ideal: nil,
            projection: [.init(date: now, remainingFraction: 0.5), .init(date: reset, remainingFraction: 0.1)],
            nowRemaining: 0.5, latestReading: nil)
        let bars: [DualBarMetrics]
        switch change {
        case "spent": bars = [Fixtures.bar("WK", 1.0, resetsInHours: 120, windowHours: 168)]
        case "new reset": bars = [Fixtures.bar("WK", 0.1, resetsInHours: 160, windowHours: 168)]
        case "other window blocked": bars = [Fixtures.bar("5H", 0.4, resetsInHours: 2, windowHours: 5, blocked: true),
                                             Fixtures.bar("WK", 0.34, resetsInHours: 120, windowHours: 168)]
        default: bars = [Fixtures.bar("5H", 0.2, resetsInHours: -0.5, windowHours: 5),
                         Fixtures.bar("WK", 0.34, resetsInHours: 120, windowHours: 168)]
        }
        let live = Fixtures.snapshot("codex", .openai, "Codex", bars)
        #expect(burndown.current(for: live, now: now).projection == nil)
    }

    @Test("a balance span under an hour is said in minutes")
    func shortSpan() throws {
        let points = [BalancePoint(measuredAt: now, value: 10), BalancePoint(measuredAt: now.addingTimeInterval(300), value: 9)]
        let trend = try #require(BalanceSparklinePresentation.make(from: points))
        #expect(trend.spanDescription == "over 5 minutes")
    }

    @Test("the footer neither counts events it has not read nor times a skipped check")
    func coldFooter() {
        #expect(FooterActionsView.eventsLabel(count: 0, readFailed: false, notYetRead: true).contains("not read yet"))
        let unset = Fixtures.snapshot("kiro", .kiro, "Kiro", [], status: .unavailable(.notConfigured))
        #expect(SystemHealthSummary.compute(from: [unset]).lastAttemptAt == nil)
    }

    @Test("Wallet figures say what they are, and a carried-over trend says so")
    func walletRoleWordsAndCarriedTrend() throws {
        let rows = WalletPresentation(snapshots: Fixtures.batchWithWallet, now: now).rows
        #expect(rows.contains { $0.figureRole == "grant" })
        #expect(rows.contains { $0.figureRole == "left" })
        let points = [BalancePoint(measuredAt: now.addingTimeInterval(-86_400), value: 10),
                      BalancePoint(measuredAt: now, value: 9)]
        let trend = try #require(BalanceSparklinePresentation.make(from: points))
        let kept = WalletRowViewSpeech.trendPhrase(base: "OpenRouter", trend: trend, carriedOver: true, now: now)
        #expect(kept.contains("earlier read"))
        #expect(kept.contains("last recorded"))
    }
}
