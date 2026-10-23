import Foundation
import Testing
import QuotaBarCore
@testable import QuotaBarUI

@Suite("Popover row grouping")
struct PopoverRowGroupingTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        _ id: String, vendor: VendorIdentifier = .opencode,
        plan: String? = "OpenCode Go", exhausted: Bool = false,
        resetText: String? = "Resets in 2 weeks"
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id, vendorId: vendor, displayName: id,
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: exhausted ? 1 : 0.2, displayDetails: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: exhausted ? 1 : 0.2, label: "MO",
                                 resetText: exhausted ? resetText : nil),
            row2: nil, planName: plan
        )
    }

    @Test func twoAndThreeInstancesGroup() {
        for count in [2, 3] {
            let rows = (0..<count).map { snapshot("workspace-\($0)") }
            let groups = PopoverRowGrouping.groups(for: rows)
            #expect(groups.count == 1)
            #expect(groups[0].isGrouped)
            #expect(groups[0].snapshots.map(\.id) == rows.map(\.id))
        }
    }

    @Test func sharedPlanHeaderSuppressesRepeatedPlan() {
        let rows = [snapshot("Alpha"), snapshot("Beta")]
        let group = PopoverRowGrouping.groups(for: rows)[0]
        #expect(group.header == "OpenCode Go")
        #expect(group.suppressPlan)
        #expect(PopoverRowGrouping.subtitle(for: rows[1], suppressPlan: group.suppressPlan,
            presentation: MetricRowPresentation(snapshot: rows[1], now: now)) == "")
    }

    @Test func singleInstanceCardIsUnchanged() {
        let row = snapshot("Alpha")
        let group = PopoverRowGrouping.groups(for: [row])[0]
        #expect(group.header == nil)
        #expect(!group.isGrouped)
        #expect(!group.suppressPlan)
        #expect(group.snapshots.map(\.id) == [row.id])
        #expect(PopoverRowGrouping.subtitle(for: row, suppressPlan: group.suppressPlan,
            presentation: MetricRowPresentation(snapshot: row, now: now)) == row.shortPlanName)
    }

    @Test func noncontiguousInstancesKeepSeparateRuns() {
        let rows = [snapshot("Alpha"), snapshot("Other", vendor: .claude), snapshot("Beta")]
        let groups = PopoverRowGrouping.groups(for: rows)
        #expect(groups.map { $0.snapshots.map(\.id) } == [["Alpha"], ["Other"], ["Beta"]])
        // Split vendors must not repeat headers or lose their standalone row styling.
        #expect(groups.filter { $0.snapshots[0].vendorId == .opencode }
            .allSatisfy { $0.header == nil && !$0.isGrouped && !$0.suppressPlan })
        for group in groups {
            for row in group.snapshots {
                #expect(PopoverRowGrouping.subtitle(for: row, suppressPlan: group.suppressPlan,
                    presentation: MetricRowPresentation(snapshot: row, now: now)) == row.shortPlanName)
            }
        }

        // Even a multi-row run stays ungrouped if another run contains the same vendor.
        let splitRows = [snapshot("Alpha"), snapshot("Beta"),
                         snapshot("Other", vendor: .claude), snapshot("Gamma")]
        let splitGroups = PopoverRowGrouping.groups(for: splitRows)
        #expect(splitGroups.count == splitRows.count)
        #expect(splitGroups.flatMap { $0.snapshots.map(\.id) } == splitRows.map(\.id))
        #expect(splitGroups.filter { $0.snapshots[0].vendorId == .opencode }
            .allSatisfy { !$0.isGrouped && !$0.suppressPlan })
    }

    @Test func disagreeingOrMissingPlansKeepRowPlans() {
        let plans: [String?] = ["Another plan", nil, "", "   "]
        for plan in plans {
            let rows = [snapshot("Alpha"), snapshot("Beta", plan: plan)]
            let group = PopoverRowGrouping.groups(for: rows)[0]
            #expect(group.header == VendorIdentifier.opencode.displayName)
            #expect(!group.suppressPlan)
            for row in rows {
                #expect(PopoverRowGrouping.subtitle(for: row, suppressPlan: group.suppressPlan,
                    presentation: MetricRowPresentation(snapshot: row, now: now)) == row.shortPlanName)
            }
        }
        let group = PopoverRowGrouping.groups(for: [snapshot("Alpha", plan: nil), snapshot("Beta", plan: nil)])[0]
        #expect(group.header == VendorIdentifier.opencode.displayName)
        #expect(!group.suppressPlan)
    }

    @Test func exhaustedGroupMemberKeepsResetText() {
        let rows = [snapshot("Alpha", exhausted: true), snapshot("Beta")]
        let group = PopoverRowGrouping.groups(for: rows)[0]
        #expect(PopoverRowGrouping.subtitle(for: rows[0], suppressPlan: group.suppressPlan,
            presentation: MetricRowPresentation(snapshot: rows[0], now: now)) == "Resets in 2 weeks")
    }

    @Test func firstMemberWithoutPlanKeepsEachRowPlan() {
        let rows = [snapshot("Alpha", plan: nil), snapshot("Beta")]
        let group = PopoverRowGrouping.groups(for: rows)[0]
        #expect(group.header == VendorIdentifier.opencode.displayName)
        #expect(!group.suppressPlan)
        for row in rows {
            #expect(PopoverRowGrouping.subtitle(for: row, suppressPlan: group.suppressPlan,
                presentation: MetricRowPresentation(snapshot: row, now: now)) == row.shortPlanName)
        }
    }

    @Test func suppressedExhaustedWorkspaceWithoutResetDrawsNoSubtitle() {
        let rows = [snapshot("Alpha", exhausted: true, resetText: nil), snapshot("Beta")]
        let group = PopoverRowGrouping.groups(for: rows)[0]
        let presentation = MetricRowPresentation(snapshot: rows[0], now: now)
        #expect(group.suppressPlan)
        #expect(presentation.isExhausted)
        #expect(presentation.exhaustedResetText == nil)
        #expect(PopoverRowGrouping.subtitle(for: rows[0], suppressPlan: group.suppressPlan,
            presentation: presentation) == "")
    }

    @Test func emptyCardHasNoGroups() {
        #expect(PopoverRowGrouping.groups(for: []).isEmpty)
    }

    @Test func scatteredAntigravityPoolsShareAServiceWithoutMergingReadings() throws {
        let rows = [snapshot("argon", vendor: .antigravityArgon, plan: "Google AI Pro"),
                    snapshot("direct", vendor: .claude, plan: "Max"),
                    snapshot("shared", vendor: .antigravityClaude, plan: "Google AI Pro"),
                    snapshot("codex", vendor: .openai, plan: "Pro"),
                    snapshot("gemini", vendor: .gemini, plan: "Google AI Pro")]
        let groups = PopoverRowGrouping.groups(for: rows)
        #expect(groups.map(\.header) == ["Antigravity", "Claude", "ChatGPT"])
        let pools = try #require(groups.first).snapshots
        #expect(pools.map(\.id) == ["argon", "shared", "gemini"])
        #expect(groups.flatMap(\.snapshots).count == rows.count)
        for pool in pools {
            let original = try #require(rows.first { $0.id == pool.id })
            #expect(pool.vendorId == original.vendorId)
            #expect(pool.row1 == original.row1)
            #expect(pool.row2 == original.row2)
            #expect(pool.planName == original.planName)
        }
        #expect(groups.allSatisfy { !$0.suppressPlan })
    }

    @Test func customOrderingKeepsEveryProviderPositionIncludingSplitServices() {
        let rows = [snapshot("gemini", vendor: .gemini), snapshot("claude", vendor: .claude),
                    snapshot("shared", vendor: .antigravityClaude), snapshot("codex", vendor: .openai),
                    snapshot("argon", vendor: .antigravityArgon, exhausted: true)]
        let groups = PopoverRowGrouping.groups(for: rows, ordering: .custom)
        #expect(groups.flatMap(\.snapshots).map(\.id) == rows.map(\.id))
        #expect(groups.map(\.header) == ["Antigravity", "Claude", "Antigravity", "ChatGPT", "Antigravity"])
    }

    @Test func groupingNeverRaisesAnExhaustedPoolAboveAUsableProvider() {
        let rows = [snapshot("shared", vendor: .antigravityClaude),
                    snapshot("claude", vendor: .claude),
                    snapshot("gemini", vendor: .gemini, exhausted: true),
                    snapshot("codex", vendor: .openai, exhausted: true),
                    snapshot("argon", vendor: .antigravityArgon, exhausted: true)]
        let groups = PopoverRowGrouping.groups(for: rows)
        #expect(groups.flatMap(\.snapshots).map(\.id) == ["shared", "claude", "gemini", "argon", "codex"])
        #expect(groups.flatMap(\.snapshots).map(\.isQuotaExhausted) == [false, false, true, true, true])
    }

    @Test func aHiddenOrAbsentPoolIsNotRecreatedByGrouping() {
        let rows = [snapshot("claude", vendor: .claude), snapshot("argon", vendor: .antigravityArgon)]
        let groups = PopoverRowGrouping.groups(for: rows)
        #expect(groups.flatMap(\.snapshots).map(\.id) == rows.map(\.id))
        #expect(groups.last?.header == "Antigravity")
    }

    @Test func serviceSubrowsNameTheirOwnAllowance() {
        #expect(PopoverRowGrouping.rowTitle(for: snapshot("gemini", vendor: .gemini)) == "Gemini")
        #expect(PopoverRowGrouping.rowTitle(for: snapshot("argon", vendor: .antigravityArgon)) == "Argon")
        let shared = QuotaSnapshot(id: "antigravity_claude", vendorId: .antigravityClaude,
            displayName: "AGY Claude/GPT", category: .aiSubscriptions,
            metric: .subscription(tierName: nil, renewalDate: nil), status: .measured(.none),
            resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        #expect(PopoverRowGrouping.rowTitle(for: shared) == "Claude/GPT (shared)")
        #expect(PopoverRowGrouping.accessibilityPrefix(for: shared) == "Antigravity shared Claude/GPT pool")
        let unknown = QuotaSnapshot(id: shared.id, vendorId: shared.vendorId,
            displayName: shared.displayName, category: shared.category, metric: shared.metric,
            status: .unavailable(.badResponse), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        #expect(PopoverRowGrouping.rowTitle(for: unknown) == "Claude/GPT")
        #expect(PopoverRowGrouping.accessibilityPrefix(for: unknown) == "Antigravity")
        #expect(PopoverRowGrouping.accessibilityPrefix(for: snapshot("gemini", vendor: .gemini)) == "Antigravity")
        #expect(PopoverRowGrouping.rowTitle(for: snapshot("claude", vendor: .claude)) == "Claude Code")
        #expect(PopoverRowGrouping.rowTitle(for: snapshot("codex", vendor: .openai)) == "Codex")
    }
}
