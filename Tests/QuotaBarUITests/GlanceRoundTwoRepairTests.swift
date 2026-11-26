import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// The continuation's second judged repair: return hints promise only what a
/// current reading published, and the inspector never outlives its pool.
@Suite("Return hints and inspector selection")
struct GlanceRoundTwoRepairTests {
    private typealias Fixtures = GlanceFixtures
    private let now = GlanceFixtures.now

    private var codex: QuotaSnapshot {
        Fixtures.snapshot("codex", .openai, "Codex", [Fixtures.bar("WK", 0.34, resetsInHours: 120, windowHours: 168)])
    }

    @Test("a stale spent pool's old reset is never the next return")
    func staleReturnIsNotPromised() {
        var stale = Fixtures.snapshot("claude-secondary", .claude, "Secondary",
                                      [Fixtures.bar("WK", 1.0, resetsInHours: 10, windowHours: 168)], urgency: .critical)
        stale.staleReading = StaleReading(reason: .offline, at: now)
        let glance = GlancePresentation(snapshots: [codex, stale], now: now)
        #expect(GlancePresentation.soonestReturn(glance.backSoon, now: now) == nil)
        #expect(UseNowPresentation(glance: glance).backSoon == nil)
    }

    @Test("an account block the vendor did not date promises no return")
    func accountBlockWithoutAPublishedReturn() throws {
        // The badge stopped the account, but no window was blocked by the
        // vendor and no pool the provider named carries a reset: the block's
        // end is unpublished, so its windows' resets are not offered as it.
        let limited = Fixtures.snapshot("opencode-go:alpha", .opencode, "Alpha", [
            Fixtures.bar("WK", 0.4, resetsInHours: 30, windowHours: 168),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        let glance = GlancePresentation(snapshots: [codex, limited], now: now)
        let pool = try #require(glance.pools.first { $0.id == "opencode-go:alpha" })
        #expect(pool.returnsAt == nil)
        #expect(UseNowPresentation(glance: glance).backSoon == nil)
    }

    @Test("a window the vendor blocked itself dates the account block")
    func vendorBlockedWindowDatesTheBlock() throws {
        // OpenCode Go's `rate-limited` month: the vendor blocked that window
        // and still published when it frees, so that reset is the return.
        let limited = Fixtures.snapshot("opencode-go:alpha", .opencode, "Alpha", [
            Fixtures.bar("5H", 0.0, resetsInHours: 5, windowHours: 5),
            Fixtures.bar("WK", 0.0, resetsInHours: 100, windowHours: 168),
            Fixtures.bar("MO", 1.0, resetsInHours: 336, windowHours: 720, blocked: true),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        let glance = GlancePresentation(snapshots: [codex, limited], now: now)
        let pool = try #require(glance.pools.first { $0.id == "opencode-go:alpha" })
        #expect(pool.returnsAt == now.addingTimeInterval(336 * 3600))
        let back = try #require(UseNowPresentation(glance: glance).backSoon)
        #expect(back.contains(GlancePresentation.spokenName(pool)))
        let when = try #require(ResetCountdownBadge.compact(now.addingTimeInterval(336 * 3600), now: now))
        #expect(back.hasSuffix(when))
    }

    @Test("the Use-now return uses Subscriptions' countdown unit")
    func useNowCountdownMatchesGrid() throws {
        let spent = Fixtures.snapshot("claude-secondary", .claude, "Secondary",
                                      [Fixtures.bar("WK", 1.0, resetsInHours: 28, windowHours: 168)], urgency: .critical)
        let glance = GlancePresentation(snapshots: [codex, spent], now: now)
        let line = try #require(UseNowPresentation(glance: glance).backSoon)
        let compact = try #require(ResetCountdownBadge.compact(now.addingTimeInterval(28 * 3600), now: now))
        #expect(line.hasSuffix("· \(compact)"))
    }

    @Test("an inspector whose pool the store dropped has no current copy")
    func removedSelection() {
        #expect(PopoverRootView.currentSnapshot(for: codex, in: [], hasLoaded: true) == nil)
        #expect(PopoverRootView.currentSnapshot(for: codex, in: [], hasLoaded: false) == codex)
        #expect(PopoverRootView.currentSnapshot(for: codex, in: [codex], hasLoaded: true) == codex)
    }

    @Test("a balance series the reload dropped falls back to one that exists")
    func balanceSelection() {
        #expect(MetricDetailModalView.balanceSelection(keeping: "a", in: ["b"]) == "b")
        #expect(MetricDetailModalView.balanceSelection(keeping: "a", in: ["a", "b"]) == "a")
        #expect(MetricDetailModalView.balanceSelection(keeping: nil, in: []) == nil)
    }

    @Test("a failed events read is not announced as zero events")
    func eventsReadFailure() {
        #expect(FooterActionsView.eventsLabel(count: 0, readFailed: true).contains("could not be read"))
        #expect(FooterActionsView.eventsLabel(count: 0, readFailed: false) == "0 recent events. Open the events list")
    }

    @Test("a check with nothing set up is not described as a failure")
    func nothingConfiguredSpeech() {
        let unset = Fixtures.snapshot("kiro", .kiro, "Kiro", [], status: .unavailable(.notConfigured))
        let summary = SystemHealthSummary.compute(from: [unset])
        #expect(SystemHealthPresentation.checkSpoken(for: summary) == "Nothing set up to check")
    }
}
