import Foundation
import Testing
import QuotaBarCore
@testable import QuotaBarUI

/// Fixes made after the hillclimb ended, for the defects its last judged
/// round confirmed: one display clock, and an inspector verdict that says
/// which read it covers.
@MainActor
@Suite("Delivery fixes: shared clock, verdict scope")
struct GlanceDeliveryFixTests {
    private let now = GlanceFixtures.now

    @Test("every surface ticks on the same whole-30-second boundaries")
    func clockTicksAreAligned() {
        let a = Date(timeIntervalSinceReferenceDate: 1_000_007)
        let b = Date(timeIntervalSinceReferenceDate: 1_000_029.9)
        #expect(GlanceClock.nextTick(after: a) == Date(timeIntervalSinceReferenceDate: 1_000_020))
        #expect(GlanceClock.nextTick(after: b) == Date(timeIntervalSinceReferenceDate: 1_000_050))
        // Strictly after: a time on a tick waits for the next one.
        let onTick = Date(timeIntervalSinceReferenceDate: 1_000_020)
        #expect(GlanceClock.nextTick(after: onTick) == Date(timeIntervalSinceReferenceDate: 1_000_050))
    }

    @Test("the tick schedule draws at once, then only on shared ticks")
    func scheduleEntries() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_007)
        let entries = Array(GlanceTickSchedule().entries(from: start, mode: .normal).prefix(3))
        #expect(entries == [start,
                            Date(timeIntervalSinceReferenceDate: 1_000_020),
                            Date(timeIntervalSinceReferenceDate: 1_000_050)])
    }

    @Test("an open inspector's verdict follows the clock across a reset, without a poll")
    func inspectorCrossesResetOnTick() {
        let reset = now.addingTimeInterval(20)
        let snapshot = GlanceFixtures.snapshot("claude", .claude, "Claude", [
            DualBarMetrics(primaryFraction: 0.45, label: "WK", resetsAt: reset, windowLength: 168 * 3600),
        ])
        let tick = GlanceClock.nextTick(after: reset)
        let later = MetricDetailModalView.displayTime(current: now, tick: tick)
        #expect(later == tick)
        guard case .awaitingReading = MetricDetailPresentation(snapshot: snapshot, now: later).summary.state else {
            Issue.record("the inspector still read the pre-reset window after the tick")
            return
        }
        // A load that finished after the tick is never wound back.
        let loadedLater = tick.addingTimeInterval(5)
        #expect(MetricDetailModalView.displayTime(current: loadedLater, tick: tick) == loadedLater)
    }

    private func story(_ snapshot: QuotaSnapshot) throws -> ProviderStoryPresentation {
        let glance = GlancePresentation(snapshots: [snapshot], now: now)
        let pool = try #require(glance.pools.first)
        return ProviderStoryPresentation(pool: pool, glance: glance, readings: nil, now: now)
    }

    @Test("the widget's Story says a reset-passed pool awaits a reading, never 'below the floor' or 'resets in due' (#201)")
    func storyForAwaitingResetPool() throws {
        let snapshot = GlanceFixtures.snapshot("claude", .claude, "Claude", [
            GlanceFixtures.bar("5H", 0.2, resetsInHours: -0.5, windowHours: 5),
            GlanceFixtures.bar("WK", 0.65, resetsInHours: 60, windowHours: 168),
        ])
        let s = try story(snapshot)
        #expect(s.standing == "Window reset · awaiting a reading")
        #expect(s.tone == .unknown)
        let text = s.lines.map(\.text).joined(separator: " | ")
        #expect(!text.contains("resets in due"))
        #expect(!text.contains("resets in now"))
        #expect(text.contains("5-hour window had 80% left before its reset") || text.contains("reset was due"))
    }

    @Test("an expired story window tells no pace or run-out from the window that ended")
    func storyWindowExpiredTellsNoProjection() throws {
        let snapshot = GlanceFixtures.snapshot("codex", .openai, "Codex", [
            GlanceFixtures.bar("WK", 0.4, resetsInHours: -1, windowHours: 168),
        ])
        let s = try story(snapshot)
        let symbols = s.lines.map(\.symbol)
        #expect(symbols.contains("clock.arrow.circlepath"))
        #expect(!symbols.contains("hourglass"))
        #expect(!symbols.contains("chart.line.downtrend.xyaxis"))
        #expect(!s.lines.contains { $0.text.contains("resets in") })
        // The ended window's figure is not printed as this window's headroom.
        #expect(s.heroRemaining == nil)
    }

    @Test("a current story window still shows its headroom in the header")
    func storyCurrentWindowShowsHero() throws {
        let s = try story(GlanceFixtures.snapshot("codex", .openai, "Codex", [
            GlanceFixtures.bar("WK", 0.4, resetsInHours: 60, windowHours: 168),
        ]))
        #expect(s.heroRemaining == 0.6)
    }

    @Test("a pool awaiting a reading tells no pace or run-out from its other, current window")
    func storyAwaitingPoolTellsNoProjection() throws {
        let s = try story(GlanceFixtures.snapshot("gemini", .gemini, "Gemini", [
            GlanceFixtures.bar("5H", 0.1, resetsInHours: -0.2, windowHours: 5),
            GlanceFixtures.bar("WK", 0.9, resetsInHours: 100, windowHours: 168),
        ]))
        #expect(s.standing == "Window reset · awaiting a reading")
        #expect(!s.lines.contains { $0.symbol == "hourglass" })
        #expect(!s.lines.contains { $0.text.contains("of the window has gone") })
        #expect(!s.lines.contains { $0.text.contains("even pace") })
    }

    @Test("a badge-only account block names the window its reset belongs to")
    func storyBadgeOnlyAccountBlock() throws {
        let s = try story(GlanceFixtures.snapshot("commandcode", .commandcode, "Command Code", [
            GlanceFixtures.bar("MO", 0.4, resetsInHours: 39, windowHours: 720),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical))
        #expect(!s.lines.contains { $0.text.hasPrefix("It resets in") })
        #expect(s.lines.contains { $0.text.contains("the account block has no published end") })
    }

    @Test("an account-blocked story names the window its reset belongs to")
    func storyAccountBlockedNamesWindowReset() throws {
        // A badge block no window explains: nothing published when it lifts.
        let snapshot = GlanceFixtures.snapshot("opencode-go:alpha", .opencode, "Alpha", [
            GlanceFixtures.bar("MO", 0.4, resetsInHours: 39, windowHours: 720),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        let s = try story(snapshot)
        #expect(!s.lines.contains { $0.text.hasPrefix("It resets in") })
        #expect(s.lines.contains { $0.text.contains("the account block has no published end") })
    }

    @Test("a block the vendor dated by a window tells that reset as the block's end")
    func storyVendorBlockedWindowDatesTheBlock() throws {
        // OpenCode Go's rate-limited month: the vendor blocked the window and
        // published when it frees.
        let snapshot = GlanceFixtures.snapshot("opencode-go:alpha", .opencode, "Alpha", [
            GlanceFixtures.bar("MO", 1.0, resetsInHours: 39, windowHours: 720, blocked: true),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        let s = try story(snapshot)
        #expect(s.lines.contains { $0.text.hasPrefix("It resets in") })
        #expect(!s.lines.contains { $0.text.contains("the account block has no published end") })
    }

    @Test("a block the vendor dated tells its pool's reset as the block's end")
    func storyDatedAccountBlock() throws {
        var snapshot = GlanceFixtures.snapshot("commandcode", .commandcode, "Command Code", [
            GlanceFixtures.bar("MO", 0.9995, resetsInHours: 39, windowHours: 720),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        snapshot.accountBlockDatedByBarLabel = "MO"
        let s = try story(snapshot)
        #expect(s.lines.contains { $0.text.hasPrefix("It resets in") })
        #expect(!s.lines.contains { $0.text.contains("the account block has no published end") })
    }

    private func read(points: [BalancePoint]?) -> MetricDetailModalView.BalanceSeriesRead {
        let snapshot = QuotaSnapshot(
            id: "openrouter", vendorId: .openrouter, displayName: "OpenRouter",
            category: .apiSpendAndCredits,
            metric: .currency(balance: 18.42, limit: nil, spent: nil, currencyCode: "USD"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: nil, row2: nil)
        let series = BalanceSeries.all(of: snapshot)[0]
        return MetricDetailModalView.BalanceSeriesRead(series: series, points: points)
    }

    @Test("a failed history read qualifies the verdict, in text and speech")
    func historyFailureScopesTheVerdict() {
        #expect(MetricDetailModalView.historyScopeNote(isLoading: false, reads: [read(points: [])]) == nil)
        #expect(MetricDetailModalView.historyScopeNote(isLoading: true, reads: [read(points: nil)]) == nil)
        let note = MetricDetailModalView.historyScopeNote(isLoading: false, reads: [read(points: nil)])
        #expect(note?.contains("latest poll") == true)
        #expect(note?.contains("could not be read") == true)

        let snapshot = GlanceFixtures.snapshot("codex", .openai, "Codex",
                                               [GlanceFixtures.bar("WK", 0.2, resetsInHours: 100, windowHours: 168)])
        let spoken = MetricDetailModalView.summaryAccessibilityLabel(
            summary: MetricDetailPresentation(snapshot: snapshot, now: now).summary,
            warnsEarlyRunOut: false, isAheadOfPace: false, runOutText: nil, historyNote: note)
        #expect(spoken.contains("recorded balance history could not be read"))
    }
}
