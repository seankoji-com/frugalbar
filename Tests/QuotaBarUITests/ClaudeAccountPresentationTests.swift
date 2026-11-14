import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Claude account presentation")
@MainActor
struct ClaudeAccountPresentationTests {
    private let now = ClaudeAccountFixtures.now

    @Test func accountRowsKeepTheirNamesAndPlansUnderOneHeading() {
        let rows = ClaudeAccountFixtures.both
        let group = PopoverRowGrouping.groups(for: rows)[0]
        #expect(group.header == "Claude")
        #expect(group.headerPlan == nil)
        #expect(!group.suppressPlan)
        #expect(group.snapshots.map(\.id) == rows.map(\.id))
        #expect(rows.map { PopoverRowGrouping.rowTitle(for: $0) } == ["Personal", "Work"])
        for row in rows {
            #expect(PopoverRowGrouping.subtitle(for: row, suppressPlan: true,
                presentation: MetricRowPresentation(snapshot: row, now: now)) == "Claude Code · Max")
        }
        let unknown = ClaudeAccountFixtures.unavailable
        #expect(PopoverRowGrouping.subtitle(for: unknown, suppressPlan: false,
            presentation: MetricRowPresentation(snapshot: unknown, now: now)) == "Claude Code")
        #expect(PopoverRowGrouping.groups(for: [rows[0]])[0].snapshots.map(\.id) == [rows[0].id])
    }

    @Test func eachFullRowSpeaksItsOwnAccountTicketsAndScopedWindow() {
        let rows = ClaudeAccountFixtures.both
        let labels = rows.map { snapshot in
            MetricRowView(snapshot: snapshot, isGrouped: true, now: now).combinedAccessibilityLabel(
                grid: WindowGridPresentation(snapshot: snapshot, now: now),
                presentation: MetricRowPresentation(snapshot: snapshot, now: now))
        }
        #expect(labels[0].contains("Personal"))
        #expect(labels[0].contains("Account 1"))
        #expect(!labels[0].contains("Work"))
        #expect(labels[1].contains("Work"))
        #expect(labels[1].contains("Account 2"))
        #expect(!labels[1].contains("Personal"))
        #expect(labels[0].contains("35%"))
        #expect(labels[1].contains("12%"))
        #expect(labels[0].contains("20 days"))
        #expect(labels[0].contains("119 days"))
        #expect(!labels[0].contains("35 days"))
        #expect(labels[1].contains("35 days"))
        #expect(labels[1].contains("45 days"))
        #expect(labels[1].contains("90 days"))
        #expect(!labels[1].contains("20 days"))
        for label in labels {
            #expect(label.contains("Claude Code"))
            #expect(label.contains("Fable"))
            #expect(label.contains("reset credit"))
        }
    }

    @Test func unreadAccountHasNoReadingAndDoesNotEraseItsSibling() {
        let unread = ClaudeAccountFixtures.unavailable
        let group = PopoverRowGrouping.groups(for: [ClaudeAccountFixtures.both[0], unread])[0]
        #expect(group.snapshots.count == 2)
        #expect(WindowGridPresentation(snapshot: unread, now: now).bars.isEmpty)
        #expect(MetricRowPresentation(snapshot: unread, now: now).fraction == nil)
        #expect(unread.scopedBars.isEmpty)
        #expect(unread.resetCreditsAvailable == nil)
        #expect(group.snapshots[0].row2?.primaryFraction == 0.61)
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

    @Test func widgetKeepsAccountNamesAndIndependentUnavailableTile() {
        let snapshots = [ClaudeAccountFixtures.both[0], ClaudeAccountFixtures.unavailable]
        let tiles = OverviewPresentation.tiles(snapshots: snapshots, filters: WidgetFilters())
        #expect(tiles.map(\.instanceID) == snapshots.map(\.id))
        #expect(tiles.map(\.name) == ["Personal", "Work"])
        #expect(!tiles[0].windows.isEmpty)
        #expect(tiles[1].windows.isEmpty)
        #expect(tiles[1].unavailableHeadline != nil)
    }

    @Test func storedWidgetSeriesResolveAccountNamesWithoutCurrentSnapshots() {
        let accounts = [ClaudeAccountFixtures.work, ClaudeAccountFixtures.personal]
        let records = accounts.enumerated().map { index, account in
            QuotaHistoryStore.ReadingRecord(vendor: account.id, barLabel: "WK", measuredAt: now,
                fraction: index == 0 ? 0.27 : 0.61, isBlocked: false, confidence: .measured,
                urgency: .none, resetsAt: nil, windowLength: QuotaWindow.week, elapsedOnly: false)
        }
        for vendors: Set<VendorIdentifier> in [[], [.claude]] {
            let series = AggregateBurndownPresentation.series(readings: records, snapshots: [],
                filters: WidgetFilters(vendors: vendors, metric: .used), now: now,
                instanceName: { key in accounts.first { $0.id == key }?.name },
                instancePosition: { key in accounts.firstIndex { $0.id == key } })
            #expect(series.map(\.instanceID) == accounts.map(\.id))
            #expect(series.map(\.displayName) == ["Work", "Personal"])
            #expect(series.map { $0.latest?.value } == [0.27, 0.61])
        }
    }

    @Test func provenAliasesKeepOneHistorySubjectAndOneWidgetSeries() {
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
        let series = AggregateBurndownPresentation.series(readings: records, snapshots: [],
            filters: WidgetFilters(metric: .used), now: now,
            instanceName: { _ in account.name }, instancePosition: { _ in 0 },
            canonicalInstanceKey: { $0 == alias ? account.id : $0 })
        #expect(series.count == 1 && series[0].instanceID == account.id)
        #expect(series[0].latest?.value == 0.3)
    }
}
