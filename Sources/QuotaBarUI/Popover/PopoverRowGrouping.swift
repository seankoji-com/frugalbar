import Foundation
import QuotaBarCore

/// Service headings describe where an allowance is metered, not its model family.
struct PopoverRowGrouping {
    struct Group: Identifiable {
        let id: String
        let header: String?
        let suppressPlan: Bool
        let snapshots: [QuotaSnapshot]

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
        let claudeTitle = snapshot.displayName.contains("GPT") ? "Claude/GPT" : "Claude"
        return switch snapshot.vendorId {
        case .gemini: "Gemini"
        case .antigravityArgon: "Argon"
        case .antigravityClaude: hasSharedClaudeReading(snapshot) ? "Claude/GPT (shared)" : claudeTitle
        case .claude: "Claude Code"
        case .openai: "Codex"
        default: snapshot.rowTitle
        }
    }

    static func accessibilityPrefix(for snapshot: QuotaSnapshot) -> String? {
        if hasSharedClaudeReading(snapshot) {
            return "Antigravity shared Claude/GPT pool"
        }
        return service(for: snapshot.vendorId)
    }

    private static func hasSharedClaudeReading(_ snapshot: QuotaSnapshot) -> Bool {
        snapshot.vendorId == .antigravityClaude && snapshot.status.confidence == .measured
            && snapshot.displayName.contains("GPT")
    }

    static func groups(
        for snapshots: [QuotaSnapshot], ordering: ProviderOrdering = .automatic
    ) -> [Group] {
        let counts = Dictionary(grouping: snapshots, by: \.vendorId).mapValues { $0.count }
        var groups: [Group] = []
        var remaining = snapshots
        // Automatic priority can scatter the independent Antigravity pools.
        // Anchor each usable/exhausted block at its first row, retaining
        // priority within it. Never lift a spent pool above a usable provider.
        // A custom arrangement is exact, so only adjacent service rows join.
        if ordering == .automatic {
            var seen = Set<String>()
            remaining = snapshots.flatMap { snapshot -> [QuotaSnapshot] in
                guard let service = service(for: snapshot.vendorId) else { return [snapshot] }
                let key = "\(service)|\(snapshot.isQuotaExhausted)"
                guard seen.insert(key).inserted else { return [] }
                return snapshots.filter {
                    self.service(for: $0.vendorId) == service
                        && $0.isQuotaExhausted == snapshot.isQuotaExhausted
                }
            }
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
                groups.append(Group(id: run[0].id, header: service, suppressPlan: false, snapshots: run))
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
