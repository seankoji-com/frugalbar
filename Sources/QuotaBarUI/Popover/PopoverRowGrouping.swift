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
        var showAntigravityAccountBadge: Bool = false

        var isGrouped: Bool { header != nil }
        var accessibilityLabel: String? {
            header.map { ([$0] + [headerPlan].compactMap { $0 }).joined(separator: ", ") }
        }

        /// Headings have become rails. Keep their published service and plan
        /// context on the first row, and keep differing plans on their own rows.
        func rowSubtitle(for snapshot: QuotaSnapshot) -> String? {
            guard let header else { return nil }
            if snapshot.vendorId == .claude, snapshot.claudeAccount != nil {
                return PopoverRowGrouping.claudeAccountSubtitle(for: snapshot)
            }
            if header == "Antigravity", snapshot.antigravityAccount != nil,
               PopoverRowGrouping.hasMultipleAntigravityAccounts(in: snapshots) {
                return PopoverRowGrouping.antigravityAccountSubtitle(for: snapshot)
            }
            let plan = snapshot.shortPlanName.trimmingCharacters(in: .whitespacesAndNewlines)
            if snapshot.vendorId == .gemini {
                if plan == header { return "" }
                return plan.hasPrefix("Google AI ") ? String(plan.dropFirst("Google ".count)) : plan
            }
            guard snapshot.id == snapshots.first?.id else { return suppressPlan ? "" : plan }
            guard !plan.isEmpty, plan != header, PopoverRowGrouping.planBadge(for: snapshot) == nil else {
                return header
            }
            return header == "Antigravity" ? "\(header)\n\(plan)" : "\(header) · \(plan)"
        }
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
        if snapshot.vendorId == .claude, snapshot.claudeAccount != nil {
            return snapshot.displayName
        }
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
        if planBadge(for: snapshot) != nil { return "OpenCode Go Plus" }
        if snapshot.vendorId == .antigravityClaude {
            return "Antigravity shared Claude/GPT pool"
        }
        return service(for: snapshot.vendorId)
    }

    static func planBadge(for snapshot: QuotaSnapshot) -> String? {
        snapshot.vendorId == .opencode && snapshot.planName == "OpenCode Go Plus" ? "Plus" : nil
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
                // Named accounts carry their own plan, even when both happen
                // to publish the same tier. The heading names only the service.
                let hasClaudeAccounts = run.contains { $0.claudeAccount != nil }
                let hasMultipleAGY = service == "Antigravity" && Self.hasMultipleAntigravityAccounts(in: run)
                let headerPlan = sharedPlan && !hasClaudeAccounts && !hasMultipleAGY ? plan : nil
                groups.append(Group(id: run[0].id, header: service, suppressPlan: headerPlan != nil,
                                    snapshots: run, headerPlan: headerPlan,
                                    showAntigravityAccountBadge: hasMultipleAGY))
            } else if grouped {
                let isGoGroup = vendor == .opencode && run.allSatisfy {
                    $0.planName == "OpenCode Go" || $0.planName == "OpenCode Go Plus"
                }
                groups.append(Group(
                    id: run[0].id,
                    header: isGoGroup ? "OpenCode Go" : sharedPlan ? plan : vendor.displayName,
                    suppressPlan: isGoGroup || sharedPlan,
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
        if snapshot.vendorId == .claude, snapshot.claudeAccount != nil {
            return claudeAccountSubtitle(for: snapshot)
        }
        if presentation.isExhausted, let reset = presentation.exhaustedResetText, !reset.isEmpty {
            return reset
        }
        return suppressPlan ? "" : snapshot.shortPlanName
    }

    private static func claudeAccountSubtitle(for snapshot: QuotaSnapshot) -> String {
        let plan = snapshot.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return plan.flatMap { $0.isEmpty ? nil : "Claude Code · \($0)" } ?? "Claude Code"
    }

    static func hasMultipleAntigravityAccounts(in snapshots: [QuotaSnapshot]) -> Bool {
        Set(snapshots.compactMap { $0.antigravityAccount?.id }).count > 1
    }

    static func antigravityAccountSubtitle(for snapshot: QuotaSnapshot) -> String {
        guard let account = snapshot.antigravityAccount else { return "" }
        let rawPlan = snapshot.shortPlanName.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = rawPlan.hasPrefix("Google AI ") ? String(rawPlan.dropFirst("Google ".count)) : rawPlan
        if !plan.isEmpty, plan != "Antigravity" {
            return "\(account.name) · \(plan)"
        }
        return account.name
    }
}
