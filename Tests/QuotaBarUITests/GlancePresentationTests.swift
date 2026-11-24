import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Glance presentation")
struct GlancePresentationTests {
    typealias F = GlanceFixtures
    let now = GlanceFixtures.now

    // MARK: Mixed-provider scenario

    @Test("the mixed-provider batch ranks by headroom at risk")
    func realBatchRanking() {
        let glance = GlancePresentation(snapshots: F.batch, now: now)
        #expect(glance.ranking.map(\.pool.name) == [
            "Argon · Account 2", "Claude · Account 2", "Gamma",
            "Gemini · Account 2", "Primary", "Gemini · Account 1", "Workspace 5",
        ])
        #expect(glance.strip.count == 3)
        #expect(glance.ranking.allSatisfy { !$0.isCaveat })
        let scores = glance.ranking.prefix(3).compactMap(\.score)
        #expect(abs(scores[0] - 1.157) < 0.002)
        #expect(abs(scores[1] - 1.004) < 0.002)
        #expect(abs(scores[2] - 0.900) < 0.002)
    }

    @Test("the pick's reason names its binding window, floored")
    func realBatchReasons() {
        let glance = GlancePresentation(snapshots: F.batch, now: now)
        #expect(glance.strip.map(\.reason) == [
            "99% WK left · resets in 6d", "98% WK left · resets in 7d", "87% MO left · resets in 29d",
        ])
    }

    @Test("ahead of pace is flagged where usage is 20 points past even pace early in the window")
    func realBatchPace() {
        let glance = GlancePresentation(snapshots: F.batch, now: now)
        let flagged = glance.ranking.filter(\.pool.isAheadOfPace).map(\.pool.name)
        #expect(Set(flagged) == ["Gemini · Account 2", "Primary", "Gemini · Account 1", "Workspace 5"])
    }

    @Test("every spent pool is in Back soon, soonest first, and none is in Services")
    func realBatchBackSoon() {
        let glance = GlancePresentation(snapshots: F.batch, now: now)
        #expect(glance.backSoon.map(\.pool.name) == [
            "Delta", "Codex", "Claude · Account 1", "Secondary", "Argon · Account 1",
            "OpenDesign", "Command Code", "Alpha", "Beta",
        ])
        #expect(glance.backSoon.map(\.returnText) == ["39h", "44h", "2d", "3d", "5d", "5d", "12d", "17d", "17d"])
        let inServices = Set(glance.services.flatMap(\.pools).map(\.id))
        #expect(glance.backSoon.allSatisfy { !inServices.contains($0.pool.id) })
        #expect(glance.foldedServices == ["Codex", "OpenDesign", "Command Code"])
    }

    @Test("saved service positions apply independently of the recommendations and returns")
    func savedServicesOrder() {
        let original = GlancePresentation(snapshots: F.batch, now: now)
        let reordered = GlancePresentation(
            snapshots: F.batch, now: now,
            serviceOrder: [.opencode, .antigravityArgon, .claude, .gemini, .commandcode, .opendesign, .openai]
        )
        #expect(Array(reordered.services.map(\.name).prefix(3)) == ["OpenCode Go", "Antigravity", "Claude Code"])
        #expect(reordered.foldedServices == ["Command Code", "OpenDesign", "Codex"])
        #expect(reordered.ranking == original.ranking)
        #expect(reordered.backSoon == original.backSoon)
        #expect(reordered.services.first { $0.name == "Antigravity" }
            == original.services.first { $0.name == "Antigravity" })
    }

    @Test("balance services follow the saved order in the Wallet")
    func savedWalletOrder() {
        let snapshots = [
            F.balance("openrouter", .openrouter, "OpenRouter", 0),
            F.balance("deepseek", .deepseek, "DeepSeek", 0),
        ]
        let glance = GlancePresentation(snapshots: snapshots, now: now, serviceOrder: [.deepseek, .openrouter])

        #expect(glance.services.isEmpty)
        #expect(glance.walletSnapshots.map(\.vendorId) == [.deepseek, .openrouter])
    }

    @Test("the menu bar title is the top pick, with the account named")
    func realBatchMenuTitle() {
        let glance = GlancePresentation(snapshots: F.batch, now: now)
        #expect(glance.menuTitle.text == "Account 2 · 99% WK · 6d")
        #expect(glance.menuTitle.vendor == .antigravityArgon)
        #expect(glance.menuTitle.tone == .normal)
    }

    // MARK: Rules

    @Test("countdowns use one unit, rounded: minutes, then hours under two days, then days")
    func countdownRounds() {
        let at = { (hours: Double) in now.addingTimeInterval(hours * 3600) }
        #expect(GlancePresentation.countdown(at(43.9), now: now) == "44h")
        #expect(GlancePresentation.countdown(at(38.5), now: now) == "39h")
        #expect(GlancePresentation.countdown(at(2.7), now: now) == "3h")
        #expect(GlancePresentation.countdown(at(0.25), now: now) == "15m")
        #expect(GlancePresentation.countdown(at(47.4), now: now) == "47h")
        #expect(GlancePresentation.countdown(at(48), now: now) == "2d")
        #expect(GlancePresentation.countdown(at(402.8), now: now) == "17d")
        #expect(GlancePresentation.countdown(at(-1), now: now) == "now")
        #expect(GlancePresentation.countdownSpoken(at(1), now: now) == "1 hour")
        #expect(GlancePresentation.countdownSpoken(at(125), now: now) == "5 days")
    }

    @Test("a near-empty monthly window vetoes a fresh weekly one")
    func monthlyFloorVetoes() {
        let pool = F.snapshot("p", .opencode, "Veto", [
            F.bar("WK", 0.0, resetsInHours: 10, windowHours: 168),
            F.bar("MO", 0.85, resetsInHours: 300, windowHours: 720)])
        let other = F.snapshot("q", .opencode, "Fine", [F.bar("WK", 0.5, resetsInHours: 100, windowHours: 168)])
        let glance = GlancePresentation(snapshots: [pool, other], now: now)
        #expect(glance.ranking.map(\.pool.name) == ["Fine"])
    }

    @Test("a 5H window sets no floor: 10% left in 5H does not demote a WK pick")
    func fiveHourSetsNoFloor() {
        let pool = F.snapshot("p", .claude, "Busy 5H", [
            F.bar("5H", 0.9, resetsInHours: 2, windowHours: 5),
            F.bar("WK", 0.3, resetsInHours: 100, windowHours: 168)])
        let glance = GlancePresentation(snapshots: [pool], now: now)
        #expect(glance.ranking.first?.isCaveat == false)
        #expect(glance.ranking.first?.binding.bar.label == "WK")
    }

    @Test("a spent 5H window sends the pool to Back soon")
    func spentFiveHourGates() {
        let pool = F.snapshot("p", .claude, "Gated", [
            F.bar("5H", 1.0, resetsInHours: 2, windowHours: 5),
            F.bar("WK", 0.3, resetsInHours: 100, windowHours: 168)])
        let glance = GlancePresentation(snapshots: [pool], now: now)
        #expect(glance.ranking.isEmpty)
        #expect(glance.backSoon.map(\.returnText) == ["2h"])
    }

    @Test("a billing cycle bar is never headroom and never a gate")
    func cycleIsNotQuota() {
        var cycle = F.bar("CYCLE", 0.95, resetsInHours: 20, windowHours: 720)
        cycle.measuresElapsedTimeOnly = true
        let withCycle = F.snapshot("p", .devpass, "DevPass", [F.bar("WK", 0.4, resetsInHours: 50, windowHours: 168), cycle])
        let onlyCycle = F.snapshot("q", .devpass, "Cycle only", [cycle])
        let glance = GlancePresentation(snapshots: [withCycle, onlyCycle], now: now)
        #expect(glance.ranking.map(\.pool.name) == ["DevPass"])
        #expect(glance.ranking.first?.binding.bar.label == "WK")
        #expect(glance.backSoon.isEmpty)
    }

    @Test("a spent bonus allowance does not stop a usable plan")
    func spentBonusIsNotAGate() {
        let kiro = F.snapshot("kiro", .kiro, "Kiro", [
            F.bar("MO", 0.4, resetsInHours: 200, windowHours: 720),
            F.bar("BN", 1.0, resetsInHours: 900, windowHours: nil, role: .bonus)])
        let glance = GlancePresentation(snapshots: [kiro], now: now)
        #expect(glance.backSoon.isEmpty)
        #expect(glance.ranking.first?.pool.name == "Kiro")
    }

    @Test("a spent plan with bonus left stays in Services, on bonus, and is only a caveat pick")
    func onBonus() {
        let kiro = F.snapshot("kiro", .kiro, "Kiro", [
            F.bar("MO", 1.0, resetsInHours: 200, windowHours: 720),
            F.bar("BN", 0.3, resetsInHours: 900, windowHours: nil, role: .bonus)])
        let fresh = F.snapshot("q", .opencode, "Fresh", [F.bar("WK", 0.1, resetsInHours: 100, windowHours: 168)])
        let both = GlancePresentation(snapshots: [kiro, fresh], now: now)
        #expect(both.ranking.map(\.pool.name) == ["Fresh"])
        #expect(both.services.flatMap(\.pools).first { $0.name == "Kiro" }?.state == .onBonus)
        let alone = GlancePresentation(snapshots: [kiro], now: now)
        #expect(alone.ranking.first?.isCaveat == true)
        #expect(alone.ranking.first?.reason.hasPrefix("on bonus") == true)
    }

    @Test("paid overage is never a pick, even when it is the only allowance open")
    func paidOverageIsNotAPick() {
        let kiro = F.snapshot("kiro", .kiro, "Kiro", [
            F.bar("MO", 1.0, resetsInHours: 200, windowHours: 720),
            F.bar("OV", 0.1, resetsInHours: nil, windowHours: nil, role: .paidOverage)])
        let glance = GlancePresentation(snapshots: [kiro], now: now)
        #expect(glance.ranking.isEmpty)
        #expect(glance.backSoon.first?.pool.hasPaidOverage == true)
    }

    @Test("an account-level block with no blocked bar is spent, with its return unpublished")
    func accountBlock() {
        let command = F.snapshot("cc", .commandcode, "Command Code", [
            F.bar("5H", 0.1, resetsInHours: 2, windowHours: 5),
            F.bar("WK", 0.2, resetsInHours: 50, windowHours: 168)], badge: "Blocked", urgency: .critical)
        let glance = GlancePresentation(snapshots: [command], now: now)
        #expect(glance.ranking.isEmpty)
        #expect(glance.backSoon.first?.returnText == "Return not published")
        #expect(glance.backSoon.first?.isBlocked == true)
    }

    @Test("a spent window with no published reset says so and sorts last")
    func unpublishedReturn() {
        let a = F.snapshot("a", .opencode, "No date", [F.bar("WK", 1.0, resetsInHours: nil, windowHours: 168)])
        let b = F.snapshot("b", .opencode, "Dated", [F.bar("WK", 1.0, resetsInHours: 30, windowHours: 168)])
        let glance = GlancePresentation(snapshots: [a, b], now: now)
        #expect(glance.backSoon.map(\.pool.name) == ["Dated", "No date"])
        #expect(glance.backSoon.last?.returnText == "Return not published")
    }

    @Test("a stale spent pool whose reset has passed is unconfirmed, never 'back'")
    func stalePassedReset() {
        var stale = F.snapshot("a", .claude, "Old", [F.bar("WK", 1.0, resetsInHours: -1, windowHours: 168)])
        stale.staleReading = StaleReading(reason: .rateLimited(retryAfter: nil), at: now)
        let glance = GlancePresentation(snapshots: [stale], now: now)
        #expect(glance.backSoon.first?.returnText.hasPrefix("Reset passed") == true)
        #expect(glance.backSoon.first?.returnText.hasSuffix("awaiting reading") == true)
    }

    @Test("a stale pool is never the pick or the menu bar title")
    func staleIsNeverPicked() {
        var stale = F.snapshot("a", .claude, "Stale", [F.bar("WK", 0.0, resetsInHours: 20, windowHours: 168)])
        stale.staleReading = StaleReading(reason: .rateLimited(retryAfter: nil), at: now)
        let glance = GlancePresentation(snapshots: [stale], now: now)
        #expect(glance.ranking.isEmpty)
        #expect(glance.services.first?.pools.first?.isStale == true)
        #expect(glance.menuTitle.text.hasPrefix("None confirmed usable"))
        #expect(glance.menuTitle.tone == .unknown)
    }

    @Test("unreadable quota pools without bars prevent the all-spent claim")
    func unreadablePoolDoesNotDisappear() {
        let exhausted = F.snapshot("codex", .openai, "Codex", [
            F.bar("WK", 1, resetsInHours: 12, windowHours: 168)
        ])
        let offline = F.snapshot("gemini", .gemini, "Gemini", [], status: .unavailable(.offline))
        let debt = F.balance("deepseek", .deepseek, "DeepSeek", 0)
        let glance = GlancePresentation(snapshots: [exhausted, offline, debt], now: now)
        #expect(glance.pools.map(\.snapshot.vendorId) == [.openai, .gemini])
        #expect(glance.menuTitle.text.hasPrefix("None confirmed usable"))

        let blocked = F.snapshot("commandcode", .commandcode, "Command Code", [], badge: "Blocked")
        #expect(GlancePresentation(snapshots: [blocked], now: now).backSoon.first?.isBlocked == true)
    }

    @Test("a model-scoped window never ranks or gates a pool")
    func scopedWindowIgnored() {
        var claude = F.snapshot("c", .claude, "Claude", [F.bar("WK", 0.3, resetsInHours: 100, windowHours: 168)])
        claude.scopedBars = [F.bar("Fable", 1.0, resetsInHours: 10, windowHours: 168)]
        let glance = GlancePresentation(snapshots: [claude], now: now)
        #expect(glance.backSoon.isEmpty)
        #expect(glance.ranking.first?.binding.bar.label == "WK")
    }

    @Test("an undated WK window qualifies after dated ones, and says its reset is not published")
    func undatedTier() {
        let undated = F.snapshot("u", .commandcode, "Undated", [F.bar("WK", 0.0, resetsInHours: nil, windowHours: 168)])
        let dated = F.snapshot("d", .opencode, "Dated", [F.bar("WK", 0.7, resetsInHours: 100, windowHours: 168)])
        let glance = GlancePresentation(snapshots: [undated, dated], now: now)
        #expect(glance.ranking.map(\.pool.name) == ["Dated", "Undated"])
        #expect(glance.ranking.last?.reason == "100% WK left · reset not published")
    }

    @Test("a pool with only short windows ranks after every long-window pool")
    func shortOnlyTier() {
        let short = F.snapshot("s", .muse, "Short", [F.bar("5H", 0.0, resetsInHours: 3, windowHours: 5)])
        let long = F.snapshot("l", .opencode, "Long", [F.bar("WK", 0.75, resetsInHours: 100, windowHours: 168)])
        let glance = GlancePresentation(snapshots: [short, long], now: now)
        #expect(glance.ranking.map(\.pool.name) == ["Long", "Short"])
    }

    @Test("with nothing qualifying, the best remaining pool is a caveat pick, in amber")
    func caveatPick() {
        let a = F.snapshot("a", .opencode, "Low", [F.bar("WK", 0.88, resetsInHours: 100, windowHours: 168)])
        let b = F.snapshot("b", .opencode, "Lower", [F.bar("WK", 0.95, resetsInHours: 100, windowHours: 168)])
        let glance = GlancePresentation(snapshots: [a, b], now: now)
        #expect(glance.ranking.count == 1)
        #expect(glance.ranking.first?.pool.name == "Low")
        #expect(glance.ranking.first?.isCaveat == true)
        #expect(glance.ranking.first?.reason == "only 12% WK left")
        #expect(glance.menuTitle.tone == .caveat)
    }

    @Test("all spent: the title gives the next return, and says when others are unknown")
    func allSpentTitles() {
        let a = F.snapshot("a", .claude, "A", [F.bar("WK", 1.0, resetsInHours: 38, windowHours: 168)])
        let b = F.snapshot("b", .opencode, "B", [F.bar("WK", 1.0, resetsInHours: nil, windowHours: 168)])
        #expect(GlancePresentation(snapshots: [a], now: now).menuTitle.text == "All spent · next 38h")
        #expect(GlancePresentation(snapshots: [a, b], now: now).menuTitle.text
            == "All spent · next 38h · others unknown")
        #expect(GlancePresentation(snapshots: [b], now: now).menuTitle.text == "All spent · return not published")
        #expect(GlancePresentation(snapshots: [a], now: now).menuTitle.tone == .critical)
    }

    @Test("spent plus unreadable never says 'All spent'")
    func spentPlusUnreadable() {
        let spent = F.snapshot("a", .claude, "A", [F.bar("WK", 1.0, resetsInHours: 38, windowHours: 168)])
        let unread = F.snapshot("b", .opencode, "B", [F.bar("WK", nil, resetsInHours: nil, windowHours: 168)],
                                status: .unavailable(.offline))
        let title = GlancePresentation(snapshots: [spent, unread], now: now).menuTitle
        #expect(title.text == "None confirmed usable · next 38h")
        var unreadNoReturn = spent
        unreadNoReturn.row1 = F.bar("WK", 1.0, resetsInHours: nil, windowHours: 168)
        #expect(GlancePresentation(snapshots: [unreadNoReturn, unread], now: now).menuTitle.text
            == "None confirmed usable · returns unknown")
    }

    @Test("nothing readable at all")
    func noReadings() {
        let unread = F.snapshot("b", .opencode, "B", [F.bar("WK", nil, resetsInHours: nil, windowHours: 168)],
                                status: .unavailable(.offline))
        #expect(GlancePresentation(snapshots: [unread], now: now).menuTitle.text == "No readings")
    }

    @Test("Claude accounts remain visible when a poll returns no quota windows")
    func unreadableClaudeAccounts() {
        var primary = F.snapshot("claude-account:primary", .claude, "Primary", [],
                                 status: .unavailable(.rateLimited(retryAfter: nil)))
        primary.claudeAccount = F.primary
        // The manager's timeout snapshot has the instance's name and ID,
        // but does not carry the account descriptor from a successful fetch.
        let secondary = F.snapshot("claude-account:secondary", .claude, "Secondary", [],
                                   status: .unavailable(.timedOut))
        let unconfigured = F.snapshot("claude", .claude, "Claude", [], status: .unavailable(.notConfigured))
        let spent = F.snapshot("codex", .openai, "Codex",
                               [F.bar("WK", 1, resetsInHours: 38, windowHours: 168)])
        let glance = GlancePresentation(snapshots: [primary, secondary, unconfigured, spent], now: now)
        let pools = glance.services.first { $0.name == "Claude Code" }?.pools ?? []

        #expect(pools.map(\.name) == ["Primary", "Secondary"])
        #expect(pools.map(\.snapshot.status.unavailableReason) == [.rateLimited(retryAfter: nil), .timedOut])
        #expect(pools.allSatisfy { $0.state == .unreadable && $0.windows.isEmpty })
        #expect(glance.ranking.isEmpty)
        #expect(glance.backSoon.map(\.pool.id) == [spent.id])
        #expect(glance.menuTitle.text == "None confirmed usable · next 38h")
    }

    @Test("two identical picks from one vendor are told apart by account")
    func accountTagDisambiguates() {
        let a = F.claude(F.primary, [F.bar("WK", 0.1, resetsInHours: 100, windowHours: 168)])
        let b = F.claude(F.secondary, [F.bar("WK", 0.1, resetsInHours: 100, windowHours: 168)])
        let glance = GlancePresentation(snapshots: [a, b], now: now)
        #expect(Set(glance.ranking.map { $0.pool.accountTag ?? "" }) == ["Primary", "Secondary"])
        #expect(glance.menuTitle.text.hasPrefix("Primary") || glance.menuTitle.text.hasPrefix("Secondary"))
        let single = GlancePresentation(snapshots: [a], now: now)
        #expect(single.ranking.first?.pool.accountTag == nil)
    }

    @Test("developer limits never take part in the glance")
    func developerLimitsExcluded() {
        let github = F.snapshot("github_rest", .githubRest, "GitHub",
                                [F.bar("REST", 0.1, resetsInHours: 0.5, windowHours: 1)], category: .developerLimits)
        let glance = GlancePresentation(snapshots: [github], now: now)
        #expect(glance.ranking.isEmpty && glance.backSoon.isEmpty && glance.services.isEmpty)
    }

    @Test("a balance-only vendor goes to the Wallet, not Services")
    func balanceOnlyToWallet() {
        let openrouter = QuotaSnapshot(id: "openrouter", vendorId: .openrouter, displayName: "OpenRouter",
            category: .apiSpendAndCredits, metric: .currency(balance: 0, limit: nil, spent: nil, currencyCode: "USD"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil, row1: nil, row2: nil)
        let glance = GlancePresentation(snapshots: [openrouter], now: now)
        #expect(glance.services.isEmpty)
        #expect(glance.walletSnapshots.map(\.id) == ["openrouter"])
    }

    @Test("bars fill with what was used: an unused window is empty, not full")
    func barsFillWithUse() {
        // OpenCode Go's Gamma workspace on 24 Nov 2026: 0% of its 5H window
        // used, which a full "% left" bar made look exhausted.
        let unused = GlancePresentation.window(for: GlanceFixtures.bar("5H", 0.0, resetsInHours: 3, windowHours: 5),
                                               now: now)
        #expect(unused.used == 0)
        let partly = GlancePresentation.window(for: GlanceFixtures.bar("WK", 0.61, resetsInHours: 132, windowHours: 168),
                                               now: now)
        #expect(abs((partly.used ?? -1) - 0.61) < 1e-9)
        let unread = GlancePresentation.window(for: GlanceFixtures.bar("WK", nil, resetsInHours: 132, windowHours: 168),
                                               now: now)
        #expect(unread.used == nil)
    }
}
