import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Claude account presentation")
@MainActor
struct ClaudeAccountPresentationTests {
    private let now = ClaudeAccountFixtures.now

    @Test func unreadAccountHasNoReadingAndDoesNotEraseItsSibling() {
        let unread = ClaudeAccountFixtures.unavailable
        #expect(WindowGridPresentation(snapshot: unread, now: now).bars.isEmpty)
        #expect(MetricRowPresentation(snapshot: unread, now: now).fraction == nil)
        #expect(unread.scopedBars.isEmpty)
        #expect(unread.resetCreditsAvailable == nil)
        #expect(ClaudeAccountFixtures.both[0].row2?.primaryFraction == 0.61)
        let stale = ClaudeAccountFixtures.stale
        let p = MetricRowPresentation(snapshot: stale, now: now)
        #expect(p.staleNote != nil)
        #expect(stale.row2?.primaryFraction == 0.27)
        #expect(p.combinedAccessibilityLabel(windows: nil, forecast: nil, creditsStale: true).contains("stale"))
    }

    @Test func historyUsesExactAccountKeysAndDoesNotAssignLocalTokens() throws {
        let accounts = [ClaudeAccountFixtures.work, ClaudeAccountFixtures.personal]
        let subjects = HistoryOverviewPresentation.subjects(order: [.claude], hidden: [],
            workspaces: [], claudeAccounts: accounts)
        #expect(subjects.map(\.id) == accounts.map(\.id) + ["claude"])
        #expect(subjects.map(\.name) == ["Work", "Personal", "Claude (unattributed)"])
        #expect(subjects.map(\.keys) == accounts.map { [$0.id] } + [["claude"]])
        #expect(subjects.prefix(2).allSatisfy { HistoryOverviewPresentation.localActivitySources(for: $0).isEmpty })
        #expect(HistoryOverviewPresentation.activityExplanation(for: subjects[0]).contains("not attributed"))
        let legacy = HistoryOverviewPresentation.Subject(id: "claude", vendor: .claude, name: "Claude")
        #expect(HistoryOverviewPresentation.localActivitySources(for: legacy) == ["claude_code"])
        var records = accounts.enumerated().map { index, account in
            QuotaHistoryStore.ReadingRecord(vendor: account.id, barLabel: "WK", measuredAt: now,
                fraction: index == 0 ? 0.27 : 0.61, isBlocked: false, confidence: .measured,
                urgency: .none, resetsAt: nil, windowLength: QuotaWindow.week, elapsedOnly: false)
        }
        records.append(QuotaHistoryStore.ReadingRecord(vendor: "claude", barLabel: "WK", measuredAt: now,
            fraction: 0.95, isBlocked: false, confidence: .measured, urgency: .none,
            resetsAt: nil, windowLength: QuotaWindow.week, elapsedOnly: false))
        let cards = HistoryOverviewPresentation.overview(subjects: subjects, readings: records).cards
        #expect(cards.map(\.subject.id) == accounts.map(\.id) + ["claude"])
        #expect(cards.map(\.latestPercent) == [27, 61, 95])
        #expect(HistoryOverviewPresentation.subjects(order: [.claude], hidden: [.claude],
            workspaces: [], claudeAccounts: accounts).isEmpty)
    }

    @Test func provenAliasesKeepOneHistorySubject() {
        var account = ClaudeAccountFixtures.personal
        let alias = "claude-account:previous-unknown-source"
        account.historyAliases = [alias]
        let subjects = HistoryOverviewPresentation.subjects(order: [.claude], hidden: [],
            workspaces: [], claudeAccounts: [account])
        #expect(subjects[0].keys == [account.id, alias])
        #expect(!subjects[0].keys.contains("claude"))
        let records = [
            QuotaHistoryStore.ReadingRecord(vendor: alias, barLabel: "WK", measuredAt: now.addingTimeInterval(-120),
                fraction: 0.2, isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: nil, windowLength: QuotaWindow.week, elapsedOnly: false),
            QuotaHistoryStore.ReadingRecord(vendor: account.id, barLabel: "WK", measuredAt: now,
                fraction: 0.3, isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: nil, windowLength: QuotaWindow.week, elapsedOnly: false)
        ]
        let overview = HistoryOverviewPresentation.overview(subjects: subjects, readings: records)
        #expect(overview.cards.count == 1 && overview.cards[0].sampleCount == 2)
        #expect(overview.cards[0].segments.count == 1)
        #expect(overview.cards[0].segments.first?.points.count == 2)
    }
}
