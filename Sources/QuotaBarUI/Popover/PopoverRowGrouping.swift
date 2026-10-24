import Foundation
import QuotaBarCore

/// Service headings describe where an allowance is metered, not its model family.
struct PopoverRowGrouping {
    struct Group: Identifiable {
        let id: String
        let header: String?
        let suppressPlan: Bool
        let snapshots: [QuotaSnapshot]
        var headerPlan: String? = nil

        var isGrouped: Bool { header != nil }
    }

    private static func service(for vendor: VendorIdentifier) -> String? {
        switch vendor {
        case .gemini, .antigravityClaude, .antigravityArgon: "Antigravity"
        case .claude: "Claude"
        case .openai: "ChatGPT"
        default: nil
        }
    }

    static func rowTitle(for snapshot: QuotaSnapshot) -> String {
        return switch snapshot.vendorId {
        case .gemini: "Gemini"
        case .antigravityArgon: "Argon"
        case .antigravityClaude: "Claude"
        case .claude: "Claude Code"
        case .openai: "Codex"
        default: snapshot.rowTitle
        }
    }

    static func accessibilityPrefix(for snapshot: QuotaSnapshot) -> String? {
        if snapshot.vendorId == .antigravityClaude {
            return "Antigravity shared Claude/GPT pool"
        }
        return service(for: snapshot.vendorId)
    }

    /// - Parameter ordering: informational here, and deliberately not
    ///   re-applied. The saved order is already in the array: `QuotaManager`
    ///   `.arrange` places service blocks from `ProviderDisplayPreferences`
    ///   before a section slices them, and this function preserves the order
    ///   it is handed rather than sorting again - re-sorting would undo that
    ///   placement. The flag stays on the signature so the caller's contract
    ///   is visible at the call site, and is referenced below so it cannot
    ///   read as a dead parameter.
    static func groups(
        for snapshots: [QuotaSnapshot], ordering: ProviderOrdering = .automatic
    ) -> [Group] {
        _ = ordering
        let counts = Dictionary(grouping: snapshots, by: \.vendorId).mapValues { $0.count }
        var groups: [Group] = []
        // QuotaManager places service blocks from preferences. Also collect
        // scattered inputs here so a caller cannot emit duplicate headings.
        var seen = Set<String>()
        let remaining = snapshots.flatMap { snapshot -> [QuotaSnapshot] in
            guard let service = service(for: snapshot.vendorId) else { return [snapshot] }
            guard seen.insert(service).inserted else { return [] }
            return snapshots.filter { self.service(for: $0.vendorId) == service }
        }
        var start = 0
        while start < remaining.count {
            let vendor = remaining[start].vendorId
            let service = service(for: vendor)
            var end = start + 1
            while end < remaining.count,
                  service.map({ self.service(for: remaining[end].vendorId) == $0 })
                    ?? (remaining[end].vendorId == vendor) { end += 1 }
            let run = Array(remaining[start..<end])
            // Split vendors stay ungrouped so a card never repeats their header.
            let grouped = run.count > 1 && run.count == counts[vendor]
            let plan = run[0].planName
            let sharedPlan = plan.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                == true && run.allSatisfy { $0.planName == plan }
            if let service {
                let headerPlan = (service == "Antigravity" || service == "Claude") && sharedPlan ? plan : nil
                groups.append(Group(id: run[0].id, header: service, suppressPlan: headerPlan != nil,
                                    snapshots: run, headerPlan: headerPlan))
            } else if grouped {
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
