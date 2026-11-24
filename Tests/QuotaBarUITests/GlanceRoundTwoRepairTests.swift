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

    @Test("an account block promises no return, whatever its windows' resets")
    func accountBlockHasNoReturn() throws {
        let limited = Fixtures.snapshot("commandcode", .commandcode, "Command Code", [
            Fixtures.bar("WK", 1.0, resetsInHours: 30, windowHours: 168, blocked: true),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        let glance = GlancePresentation(snapshots: [codex, limited], now: now)
        let pool = try #require(glance.pools.first { $0.id == "commandcode" })
        #expect(pool.returnsAt == nil)
        #expect(UseNowPresentation(glance: glance).backSoon == nil)
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
