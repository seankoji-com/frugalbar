import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// The continuation's first judged repair: each surface reads the shared
/// answer rather than holding its own copy of it.
@Suite("Glance surfaces share one answer")
struct GlanceRoundOneRepairTests {
    private typealias Fixtures = GlanceFixtures
    private let now = GlanceFixtures.now

    private var codex: QuotaSnapshot {
        Fixtures.snapshot("codex", .openai, "Codex", [Fixtures.bar("WK", 0.34, resetsInHours: 120, windowHours: 168)])
    }
    private var spent: QuotaSnapshot {
        Fixtures.snapshot("claude-secondary", .claude, "Secondary",
                          [Fixtures.bar("WK", 1.0, resetsInHours: 48, windowHours: 168)], urgency: .critical)
    }

    @Test("the popover's Use-now line names the menu bar's pick and the soonest return")
    func useNowMatchesMenuBar() throws {
        let glance = GlancePresentation(snapshots: [codex, spent], now: now)
        let pick = try #require(glance.ranking.first)
        let useNow = UseNowPresentation(glance: glance)
        #expect(useNow.snapshotID == pick.pool.id)
        #expect(useNow.headline == "Use \(GlancePresentation.spokenName(pick.pool))")
        #expect(useNow.detail?.contains("34% WK used") == true)
        #expect(useNow.backSoon?.hasPrefix("Back soonest:") == true)
        #expect(useNow.backSoon?.contains("2d") == true)
        #expect(glance.menuTitle.text.contains("34% WK used"))
    }

    @Test("nothing usable: the line says what the menu bar says and opens nothing")
    func useNowWithoutPick() {
        let glance = GlancePresentation(snapshots: [spent], now: now)
        let useNow = UseNowPresentation(glance: glance)
        #expect(useNow.snapshotID == nil)
        #expect(useNow.headline == glance.menuTitle.text)
        #expect(useNow.tone == .none)
    }

    @Test("a pool named after its service is spoken once")
    func spokenNameDeduplicates() throws {
        let glance = GlancePresentation(snapshots: [codex], now: now)
        let pool = try #require(glance.pools.first)
        #expect(!GlancePresentation.spokenName(pool).contains("Codex Codex"))
        #expect(!glance.menuTitle.spoken.contains("Codex Codex"))
    }

    @Test("before the first poll the menu bar says it is reading, never 'No subscriptions'")
    func menuBarLoading() {
        let loading = MenuBarGlance.presentation(snapshots: [], now: now, hasLoaded: false)
        #expect(loading.text == "Loading…")
        let loaded = MenuBarGlance.presentation(snapshots: [], now: now, hasLoaded: true)
        #expect(loaded.text != "Loading…")
        #expect(!loaded.accessibilityLabel.contains("Wallet"))
    }

    @Test("the footer reports the check: a failed provider is partial, an unconfigured one is not")
    func footerCheckState() {
        let offline = Fixtures.snapshot("deepseek", .deepseek, "DeepSeek", [], status: .unavailable(.offline),
                                        category: .apiSpendAndCredits)
        let unset = Fixtures.snapshot("kiro", .kiro, "Kiro", [], status: .unavailable(.notConfigured))
        let lowBalance = Fixtures.snapshot("openrouter", .openrouter, "OpenRouter", [], urgency: .critical,
                                           category: .apiSpendAndCredits)
        let partial = SystemHealthSummary.compute(from: [codex, offline, lowBalance])
        #expect(SystemHealthPresentation.checkState(for: partial) == .partial)
        #expect(SystemHealthPresentation.checkProblems(for: partial) == "1 not readable")
        // Balance pressure is not the check's to report.
        #expect(!SystemHealthPresentation.checkSpoken(for: partial).contains("critical"))
        let complete = SystemHealthSummary.compute(from: [codex, unset])
        #expect(SystemHealthPresentation.checkState(for: complete) == .complete)
    }

    @Test("an account block reaches the inspector's window lines and the recorded bar")
    func accountBlockInInspectorWindows() {
        let limited = Fixtures.snapshot("commandcode", .commandcode, "Command Code", [
            Fixtures.bar("5H", 0.2, resetsInHours: 3, windowHours: 5),
            Fixtures.bar("WK", 0.4, resetsInHours: 48, windowHours: 168),
        ], badge: QuotaSnapshot.accountBlockedBadge, urgency: .critical)
        let inspector = MetricDetailPresentation(snapshot: limited, now: now)
        #expect(!inspector.windows.isEmpty)
        #expect(inspector.windows.allSatisfy { $0.metrics.isBlocked })
        #expect(inspector.windows.allSatisfy { $0.detail.hasPrefix("Blocked by the vendor") })
        let limitedBars = limited.quotaBars.map { limited.applyingAccountBlock(to: $0) }
        let codexSnapshot = codex
        let codexBars = codexSnapshot.quotaBars.map { codexSnapshot.applyingAccountBlock(to: $0) }
        #expect(limitedBars.allSatisfy { $0.isBlocked })
        #expect(!codexBars.contains { $0.isBlocked })
    }

    @Test("an unreadable snapshot's timestamp is an attempt, not a fetch")
    func provenanceAttempt() {
        let rejected = Fixtures.snapshot("codex", .openai, "Codex", [], status: .unavailable(.credentialRejected))
        let labels = MetricDetailPresentation(snapshot: rejected, now: now).provenance.map(\.label)
        #expect(labels.contains("Last attempted"))
        #expect(!labels.contains("Last fetched"))
    }

    @Test("the open inspector re-reads when the pool's poll changes")
    func inspectorReloadKey() {
        var failedSince = codex
        failedSince.staleReading = StaleReading(reason: .offline, at: now.addingTimeInterval(120))
        #expect(MetricDetailModalView.loadKey(for: codex) != MetricDetailModalView.loadKey(for: failedSince))
        #expect(MetricDetailModalView.loadKey(for: codex) == MetricDetailModalView.loadKey(for: codex))
    }
}
