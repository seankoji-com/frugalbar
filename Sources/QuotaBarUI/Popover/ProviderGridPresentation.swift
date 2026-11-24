import Foundation
import QuotaBarCore

/// Groups the routes the owner uses for the same model family. Each route
/// retains its own snapshot and inspector identity.
struct ProviderGridPresentation {
    typealias Window = GlancePresentation.Window
    typealias PoolState = GlancePresentation.PoolState

    struct Pool: Identifiable {
        let snapshot: QuotaSnapshot
        let name: String
        let source: String?
        let windows: [WindowColumn: Window]
        let extraBars: [DualBarMetrics]
        let state: PoolState
        let returnsAt: Date?

        var id: String { snapshot.id }
        var isStale: Bool { snapshot.staleReading != nil }
        var isUsable: Bool { !isStale && (state == .usable || state == .onBonus) }
        var isSpent: Bool { !isStale && state == .spent }
        /// True when the pool is unusable because the vendor blocked it — the
        /// account badge or a plan window — rather than the user exhausting
        /// measured quota. `GlancePresentation.Pool.isBlocked` is the one
        /// definition; this pool only adds that it is spent and current.
        let blocksPool: Bool
        var isBlocked: Bool { isSpent && blocksPool }

        var nonstandardPlanBar: DualBarMetrics? {
            extraBars.first {
                $0.allowanceRole == .plan && !$0.measuresElapsedTimeOnly
                    && ($0.primaryFraction != nil || $0.isBlocked)
                    && WindowColumn.column(forLabel: $0.label) == nil
            }
        }

        /// A measured exhausted month takes the lane. An exhausted week can
        /// take it if the short window isn't also exhausted and there is no
        /// monthly reading to show.
        var spanningColumn: WindowColumn? {
            if let month = windows[.monthly], WindowGridPresentation.isExhausted(month.bar) { return .monthly }
            if let week = windows[.weekly], WindowGridPresentation.isExhausted(week.bar),
               windows[.monthly] == nil, windows[.fiveHour]?.isSpent != true { return .weekly }
            return nil
        }

        var displayWindows: [WindowColumn: Window] {
            guard let week = windows[.weekly], WindowGridPresentation.isExhausted(week.bar),
                  windows[.fiveHour]?.isSpent != true else { return windows }
            return windows.filter { $0.key != .fiveHour }
        }

        init(snapshot: QuotaSnapshot, group: VendorIdentifier, now: Date) {
            self.snapshot = snapshot
            let pool = GlancePresentation.pool(for: snapshot, now: now, ambiguous: false)
            state = pool?.state ?? .unreadable
            returnsAt = pool?.returnsAt
            blocksPool = pool?.isBlocked ?? snapshot.isAccountBlocked

            if snapshot.vendorId == .antigravityClaude {
                name = snapshot.antigravityAccount?.name ?? snapshot.displayName
                source = ["Claude/GPT pool", ProviderGridPresentation.route(for: snapshot)].compactMap { $0 }.joined(separator: " · ")
            } else if snapshot.vendorId == .claude {
                name = pool?.name ?? snapshot.displayName
                source = name == "Claude Code" ? nil : "Claude Code"
            } else if snapshot.vendorId == .openai {
                name = snapshot.planName ?? "ChatGPT"
                source = snapshot.planName == nil ? nil : "ChatGPT"
            } else if snapshot.vendorId == .gemini || snapshot.vendorId == .antigravityArgon {
                // Gemini and Argon share one group, so the line names the
                // model, then the route that read it: AGY (this Mac's Google
                // sign-in) or the CLI Proxy. Owner, 24 Nov 2026.
                name = snapshot.antigravityAccount?.name ?? snapshot.rowTitle
                let model = snapshot.vendorId == .antigravityArgon ? "Argon" : "Gemini"
                source = [model, ProviderGridPresentation.route(for: snapshot)].compactMap { $0 }.joined(separator: " · ")
            } else if snapshot.vendorId == .opencode {
                name = snapshot.rowTitle
                source = snapshot.planName ?? "OpenCode Go"
            } else {
                name = snapshot.rowTitle
                source = group == snapshot.vendorId || snapshot.rowTitle == snapshot.vendorId.displayName
                    ? nil : GlancePresentation.serviceName(for: snapshot.vendorId)
            }

            var columns: [WindowColumn: Window] = [:]
            for window in pool?.windows ?? [] {
                guard window.remaining != nil || window.bar.isBlocked,
                      let column = WindowColumn.column(forLabel: window.bar.label),
                      columns[column] == nil else { continue }
                columns[column] = window
            }
            windows = columns
            let supplements = snapshot.displayBars.filter {
                $0.allowanceRole != .plan || $0.measuresElapsedTimeOnly
                    || WindowColumn.column(forLabel: $0.label) == nil
            }
            extraBars = supplements + (state == .usable ? snapshot.scopedBars : [])
        }
    }

    enum Summary: Equatable {
        case window(Window)
        case average(remaining: Double, reported: Int, count: Int)
        case spent(reset: Date?, allMeasuredExhausted: Bool, includesBlocked: Bool)
    }

    struct Group: Identifiable {
        let id: VendorIdentifier
        let pools: [Pool]

        var title: String {
            switch id {
            case .claude: "Claude"
            case .gemini: "Gemini"
            case .antigravityArgon: "Argon"
            default: GlancePresentation.serviceName(for: id)
            }
        }

        var allSpent: Bool { !pools.isEmpty && pools.allSatisfy(\.isSpent) }
        var nextReturn: Date? { allSpent ? pools.compactMap(\.returnsAt).min() : nil }

        /// The status line under the group's name, as spoken and tested.
        var subtitle: String? { statusParts?.joined(separator: " · ") }

        /// `subtitle` as drawn. It wraps in a 136pt column, so each count
        /// keeps its word on the same line ("1 stale", never "1" / "stale"):
        /// the spaces inside a part are non-breaking.
        var displaySubtitle: String? {
            statusParts.map { parts in
                parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
            }
        }

        private var statusParts: [String]? {
            if pools.isEmpty { return nil }
            let blocked = pools.filter(\.isBlocked).count
            let exhausted = pools.filter { $0.isSpent && !$0.isBlocked }.count
            if allSpent {
                if blocked == pools.count {
                    return [pools.count == 1 ? "1 blocked" : "All \(pools.count) blocked"]
                }
                if exhausted == pools.count {
                    return [pools.count == 1 ? "1 spent" : "All \(pools.count) spent"]
                }
                return ["\(blocked) blocked", "\(exhausted) spent"]
            }
            let usable = pools.filter(\.isUsable).count
            let stale = pools.filter(\.isStale).count
            let unreadable = pools.count - usable - blocked - exhausted - stale
            return ["\(usable) usable",
                    blocked > 0 ? "\(blocked) blocked" : nil,
                    exhausted > 0 ? "\(exhausted) spent" : nil,
                    stale > 0 ? "\(stale) stale" : nil,
                    unreadable > 0 ? "\(unreadable) unreadable" : nil]
                .compactMap { $0 }
        }

        func summary(for column: WindowColumn) -> Summary? {
            if pools.count == 1 { return pools[0].windows[column].map(Summary.window) }
            let published = pools.filter { !$0.isStale }.compactMap { $0.windows[column] }
            guard !published.isEmpty else { return nil }
            if published.count == pools.count, published.allSatisfy(\.isSpent) {
                return .spent(
                    reset: published.compactMap(\.bar.resetsAt).min(),
                    allMeasuredExhausted: published.allSatisfy { WindowGridPresentation.isExhausted($0.bar) },
                    includesBlocked: published.contains { $0.bar.isBlocked }
                )
            }
            let remaining = published.compactMap(\.remaining)
            guard !remaining.isEmpty else { return nil }
            return .average(remaining: remaining.reduce(0, +) / Double(remaining.count),
                            reported: remaining.count, count: pools.count)
        }
    }

    let groups: [Group]
    let now: Date

    init(snapshots: [QuotaSnapshot], serviceOrder: [VendorIdentifier], now: Date) {
        self.now = now
        let visible = snapshots.filter(Self.isVisible)
        let grouped = Dictionary(grouping: visible, by: { Self.groupID(for: $0.vendorId) })
        var seen: Set<VendorIdentifier> = []
        let order = (serviceOrder + visible.map(\.vendorId)).map(Self.groupID(for:)).filter { seen.insert($0).inserted }
        // Direct balances (OpenRouter, DeepSeek's own API credit) live in the
        // Wallet only (owner, 24 Nov 2026), so a group needs a quota pool to
        // appear here.
        groups = order.compactMap { id in
            guard let snapshots = grouped[id] else { return nil }
            let pools = snapshots.filter { !Self.isDirectBalance($0) }
                .map { Pool(snapshot: $0, group: id, now: now) }
            guard !pools.isEmpty else { return nil }
            return Group(id: id, pools: pools)
        }
    }

    static func groupID(for vendor: VendorIdentifier) -> VendorIdentifier {
        switch vendor {
        case .antigravityClaude: .claude
        case .antigravityArgon: .gemini
        case .opencode, .commandcode, .opendesign: .deepseek
        default: vendor
        }
    }

    /// The route that read an Antigravity pool: "AGY" (this Mac's Google
    /// sign-in) or "CLI Proxy". The reading's own source first, since it is
    /// the route actually used; the account's known routes when no reading
    /// arrived. Nil when neither names one.
    static func route(for snapshot: QuotaSnapshot) -> String? {
        let label = snapshot.cliSource ?? snapshot.antigravityAccount?.sourceLabel ?? ""
        let routes = [label.contains("Google OAuth") ? "AGY" : nil,
                      label.contains("CLI Proxy") ? "CLI Proxy" : nil].compactMap { $0 }
        return routes.isEmpty ? nil : routes.joined(separator: " + ")
    }

    static func isDirectBalance(_ snapshot: QuotaSnapshot) -> Bool {
        if snapshot.vendorId == .deepseek { return true }
        guard !snapshot.quotaBars.contains(where: { $0.allowanceRole == .plan }) else { return false }
        switch snapshot.metric {
        case .currency, .credits: return true
        default: return snapshot.category == .apiSpendAndCredits
        }
    }

    private static func isVisible(_ snapshot: QuotaSnapshot) -> Bool {
        guard snapshot.category != .developerLimits else { return false }
        guard snapshot.status.unavailableReason == .notConfigured else { return true }
        return snapshot.claudeAccount != nil || snapshot.id.hasPrefix(ClaudeAccount.instancePrefix)
            || snapshot.antigravityAccount != nil
    }

    func countdown(_ date: Date?, stale: Bool = false) -> String? {
        guard let date else { return nil }
        if stale && date <= now { return nil }
        return ResetCountdownBadge.compact(date, now: now)
    }
}
