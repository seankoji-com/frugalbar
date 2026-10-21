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
        #expect(groups.allSatisfy { $0.header == nil && !$0.isGrouped && !$0.suppressPlan })
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
        #expect(splitGroups.allSatisfy { !$0.isGrouped && !$0.suppressPlan })
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
}
