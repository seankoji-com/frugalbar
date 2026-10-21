import Foundation
import QuotaBarCore

/// Ordered contiguous vendor runs. A vendor earns a header only when all of
/// its snapshots form one run with at least two members. Never reorders rows.
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
            // Split vendors stay ungrouped so a card never repeats their header.
            let grouped = run.count > 1 && run.count == counts[vendor]
            let plan = run[0].planName
            let sharedPlan = plan.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                == true && run.allSatisfy { $0.planName == plan }
            if grouped {
                groups.append(Group(
                    id: run[0].id,
                    header: sharedPlan ? plan : vendor.displayName,
                    suppressPlan: sharedPlan,
                    snapshots: run
                ))
            } else {
                // Standalone entries keep the section's hairline between every row.
                groups.append(contentsOf: run.map {
                    Group(id: $0.id, header: nil, suppressPlan: false, snapshots: [$0])
                })
            }
            start = end
        }
        return groups
    }

    /// The reset-first rule applies to grouped and standalone rows alike: an
    /// exhausted row states the reset the vendor published; otherwise a grouped
    /// row drops the plan its header already carries.
    ///
    /// A suppressed row with nothing true left to say draws no second line —
    /// including an exhausted workspace whose vendor published no reset. Falling
    /// back to the plan there would print the header's own words underneath it,
    /// which is the repetition this grouping exists to remove; the struck avatar
    /// and the row's spoken label still carry the spent state.
    static func subtitle(
        for snapshot: QuotaSnapshot, suppressPlan: Bool, presentation: MetricRowPresentation
    ) -> String {
        if presentation.isExhausted, let reset = presentation.exhaustedResetText, !reset.isEmpty {
            return reset
        }
        return suppressPlan ? "" : snapshot.shortPlanName
    }
}
