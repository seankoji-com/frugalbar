import Foundation
import QuotaBarCore

/// Ordered contiguous vendor runs. A vendor must occur twice in this card to
/// earn headers; separated runs keep their positions and get separate headers.
struct PopoverRowGrouping {
    struct Group: Identifiable {
        let id: String
        let header: String?
        let suppressPlan: Bool
        let snapshots: [QuotaSnapshot]

        var isGrouped: Bool { header != nil }
    }

    static func groups(for snapshots: [QuotaSnapshot]) -> [Group] {
        let counts = Dictionary(grouping: snapshots, by: \.vendorId).mapValues { $0.count }
        var groups: [Group] = []
        var start = 0
        while start < snapshots.count {
            let vendor = snapshots[start].vendorId
            var end = start + 1
            while end < snapshots.count, snapshots[end].vendorId == vendor { end += 1 }
            let run = Array(snapshots[start..<end])
            let grouped = (counts[vendor] ?? 0) > 1
            let plan = run[0].planName
            let sharedPlan = plan.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                == true && run.allSatisfy { $0.planName == plan }
            groups.append(Group(
                id: run[0].id,
                header: grouped ? (sharedPlan ? plan : vendor.displayName) : nil,
                suppressPlan: grouped && sharedPlan,
                snapshots: run
            ))
            start = end
        }
        return groups
    }

    /// The same reset-first rule applies to grouped and standalone rows.
    static func subtitle(
        for snapshot: QuotaSnapshot, suppressPlan: Bool, presentation: MetricRowPresentation
    ) -> String {
        if presentation.isExhausted, let reset = presentation.exhaustedResetText, !reset.isEmpty {
            return reset
        }
        return suppressPlan ? "" : snapshot.shortPlanName
    }
}
