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

        /// `GlancePresentation.Pool.freshness`, so this row and the pick agree.
        let freshness: GlancePresentation.Freshness

        var id: String { snapshot.id }
        var isStale: Bool { snapshot.staleReading != nil }
        /// A window reset with no reading since; its figure is the old window's.
        var isAwaitingReset: Bool { freshness == .awaitingReset }
        /// Its figures describe now (`GlancePresentation.Freshness.current`).
        var isCurrent: Bool { freshness == .current }
        var isUsable: Bool { freshness == .current && (state == .usable || state == .onBonus) }
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

        /// What the row draws: a 5H column a spent week hides from its row.
        /// The group's columns do not read this — a window the row hides is
        /// still counted there, at zero (`headroom(for:)`).
        var displayWindows: [WindowColumn: Window] {
            guard let week = windows[.weekly], WindowGridPresentation.isExhausted(week.bar),
                  windows[.fiveHour]?.isSpent != true else { return windows }
            return windows.filter { $0.key != .fiveHour }
        }

        /// The share of `column` this pool brings to the group's average: its
        /// own published figure, or 0 when a longer window is spent or blocked
        /// — a pool that cannot take a job has no shorter headroom either, so
        /// a spent month empties the week and the 5H window, and a spent week
        /// empties the 5H window (owner, 26 Nov 2026). Exhaustion runs downward
        /// only: a spent 5H window resets within the hour and leaves the week
        /// and the month alone.
        ///
        /// Nil when the pool published nothing for the column, is not current,
        /// or the vendor blocked that window itself: a blocked figure is the
        /// vendor's, not headroom.
        func headroom(for column: WindowColumn) -> Double? {
            guard isCurrent, let window = windows[column], !window.bar.isBlocked else { return nil }
            let empties = window.isSpent
                || windows.contains { $0.key.rawValue > column.rawValue && $0.value.isSpent }
            return empties ? 0 : window.remaining
        }

        /// Whether this pool brings headroom of its own to `column` — the
        /// green dot under the group's bar. Red is "nothing here": no reading,
        /// a stale or blocked one, or spent on a window at least this long.
        func offersHeadroom(for column: WindowColumn) -> Bool {
            (headroom(for: column) ?? 0) > 0
        }

        init(snapshot: QuotaSnapshot, group: VendorIdentifier, now: Date) {
            self.snapshot = snapshot
            let pool = GlancePresentation.pool(for: snapshot, now: now, ambiguous: false)
            state = pool?.state ?? .unreadable
            returnsAt = pool?.returnsAt
            blocksPool = pool?.isBlocked ?? snapshot.isAccountBlocked
            freshness = pool?.freshness ?? (snapshot.staleReading != nil ? .stale : .current)

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

            // An account the vendor blocked on its badge blocks every window it
            // reads, whatever percentage each shows: the cells, the group's
            // spent roll-up, its averages and the spoken labels then all read
            // the block from the bar, the one place they already look. Drawn
            // as plain percentages these read as healthy green bars beside a
            // red-ringed avatar.
            // Under an account block, a window's reset is not when the block
            // lifts, and "⊘ MO 2d" beside "1 blocked" read as the unblock date.
            // The cells then show the block and no countdown; the inspector's
            // window lines still give each window's own reset, labelled as such.
            // A block the vendor dated (`accountBlockDatedByBarLabel`, or a window it
            // blocked itself) is the exception: that reset *is* the block's
            // end, so the cell keeps it.
            let poolWindows = (pool?.windows ?? []).map { window -> Window in
                guard snapshot.isAccountBlocked else { return window }
                var bar = snapshot.applyingAccountBlock(to: window.bar)
                // A dated block keeps its pool's reset: that date is the
                // block's published end, and the cell draws it.
                if !snapshot.accountBlockResetIsTheBlocksEnd(window.bar) { bar.resetsAt = nil }
                return GlancePresentation.window(for: bar, now: now)
            }
            var columns: [WindowColumn: Window] = [:]
            for window in poolWindows {
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

        /// The group's status in words — "2 usable · 3 blocked · 2 spent" — for
        /// the row's accessibility label and the tooltip only. It is not drawn
        /// (owner, 26 Nov 2026): the coverage dots under each bar already show
        /// which pools answered, and a status line under every name made the
        /// card taller for a summary of the rows below.
        var subtitle: String? { statusParts?.joined(separator: " · ") }

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
            // A pool running on its bonus is named so, not counted "usable"
            // beside its own spent plan bar: the job would spend a bonus that
            // expires.
            let onBonus = pools.filter { $0.isUsable && $0.state == .onBonus }.count
            let usable = pools.filter(\.isUsable).count - onBonus
            let stale = pools.filter(\.isStale).count
            let awaiting = pools.filter { $0.isAwaitingReset && !$0.isSpent }.count
            let unreadable = pools.count - usable - onBonus - blocked - exhausted - stale - awaiting
            return ["\(usable) usable",
                    onBonus > 0 ? "\(onBonus) on bonus" : nil,
                    blocked > 0 ? "\(blocked) blocked" : nil,
                    exhausted > 0 ? "\(exhausted) spent" : nil,
                    stale > 0 ? "\(stale) stale" : nil,
                    awaiting > 0 ? "\(awaiting) awaiting reading" : nil,
                    unreadable > 0 ? "\(unreadable) unreadable" : nil]
                .compactMap { $0 }
        }

        /// One dot per pool, in the order the group lists them — the same order
        /// the expanded rows use. Green where the pool brings headroom of its
        /// own to the window, red where it gives you nothing here.
        func coverage(for column: WindowColumn) -> [Bool] {
            pools.map { $0.offersHeadroom(for: column) }
        }

        /// Pools counted in the column's average at 0 — spent, or emptied by a
        /// spent longer window. They are the red dots that still count toward
        /// the average, and the spoken label says how many there are.
        func spentCount(for column: WindowColumn) -> Int {
            pools.filter { $0.headroom(for: column) == 0 }.count
        }

        func summary(for column: WindowColumn) -> Summary? {
            if pools.count == 1 { return pools[0].windows[column].map(Summary.window) }
            // What every column counts (`headroom(for:)`), not what a row
            // draws: a pool whose month is spent fills its row's lane alone,
            // but its week and 5H windows still count here as exhausted.
            let current = pools.filter { $0.freshness == .current }
            let published = current.compactMap { $0.windows[column] }
            guard !published.isEmpty else { return nil }
            if published.count == pools.count, published.allSatisfy(\.isSpent) {
                return .spent(
                    reset: published.compactMap(\.bar.resetsAt).min(),
                    allMeasuredExhausted: published.allSatisfy { WindowGridPresentation.isExhausted($0.bar) },
                    includesBlocked: published.contains { $0.bar.isBlocked }
                )
            }
            let headroom = current.compactMap { $0.headroom(for: column) }
            guard !headroom.isEmpty else { return nil }
            return .average(remaining: headroom.reduce(0, +) / Double(headroom.count),
                            reported: headroom.count, count: pools.count)
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
