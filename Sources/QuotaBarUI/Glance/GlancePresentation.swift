import Foundation
import QuotaBarCore

/// What the popover and the menu bar answer at a glance: which pool to use
/// now, and when the spent ones come back.
///
/// One presentation ranks the pools (Use now), orders the spent ones by return
/// (Back soon), chooses the Wallet's snapshots and builds the menu-bar title,
/// which the widget's Story reads too, so the title can never name a pool the
/// ranking does not lead with. Everything here is built from figures the vendor
/// published: a fraction, a reset, a window length. Nothing is projected, and a
/// pool with nothing measured is never ranked.
public struct GlancePresentation: Equatable, Sendable {

    // MARK: Rules (named once; the tests read these)

    /// A pick must have at least this share left in every long window. A 5H
    /// window applies no floor: it only intervenes when spent or blocked.
    public static let qualifyingFloor = 0.20
    /// A window this long or longer is a long window: one whose unused headroom
    /// is lost at its reset, so it drives use-it-or-lose-it ranking.
    public static let longWindowMinimum: TimeInterval = 7 * 86_400
    /// "Ahead of pace" is flagged in the first half of a window when usage is
    /// at least this far past an even pace.
    public static let aheadOfPaceLead = 0.20

    // MARK: Types

    public enum PoolState: Equatable, Sendable {
        /// Nothing spent or blocked; work can start here.
        case usable
        /// The plan is spent but a free bonus allowance is still usable.
        case onBonus
        /// A plan window is spent or blocked, or the vendor blocked the account.
        case spent
        /// No usable reading at all.
        case unreadable
    }

    /// One plan window of a pool, with the figures the glance derives from it.
    public struct Window: Equatable, Sendable {
        public let bar: DualBarMetrics
        /// 1 − used, or nil when no fraction was published.
        public let remaining: Double?
        public let isLong: Bool
        /// remaining ÷ share of the window still to run. Nil unless the
        /// fraction, reset and window length were all published and the reset
        /// is still ahead.
        public let headroomAtRisk: Double?
        public let isAheadOfPace: Bool
        public let isSpent: Bool
        /// The share used, as the bars draw it: 1 − `remaining`, nil when no
        /// fraction was published.
        public var used: Double? { remaining.map { 1 - $0 } }
    }

    public struct Pool: Identifiable, Equatable, Sendable {
        public var id: String { snapshot.id }
        public let snapshot: QuotaSnapshot
        /// The service block it belongs to ("Claude Code", "Antigravity", ...).
        public let service: String
        /// The pool's own name within that service ("Primary", "Argon · Account 2").
        public let name: String
        /// A short account identifier for the menu bar when the vendor has more
        /// than one visible instance, else nil.
        public let accountTag: String?
        public let state: PoolState
        public let isStale: Bool
        /// Plan windows, longest first.
        public let windows: [Window]
        public let isAheadOfPace: Bool
        /// When it comes back (Back soon only): the latest published reset
        /// among the spent windows. Nil when any spent window has none.
        public let returnsAt: Date?
        /// A paid overage or on-demand allowance is still open beside a spent plan.
        public let hasPaidOverage: Bool
    }

    public struct Pick: Equatable, Sendable {
        public let pool: Pool
        /// The window the pick is ranked on.
        public let binding: Window
        /// One line naming the binding window: "99% WK left · resets 6d".
        public let reason: String
        /// Not a qualifying pick: the best of what is left (decision 11).
        public let isCaveat: Bool
        public let score: Double?
    }

    public struct ReturnEntry: Equatable, Sendable {
        public let pool: Pool
        /// "1d 14h", "Return not published", or "Reset passed 18:20 · awaiting reading".
        public let returnText: String
        /// The spent window's token ("WK", "MO"), or nil for an account block.
        public let windowLabel: String?
        public let isBlocked: Bool
    }

    public enum MenuTone: Equatable, Sendable { case normal, caveat, critical, unknown }

    public struct MenuTitle: Equatable, Sendable {
        /// The pick's vendor, for its logo. Nil when there is no pick.
        public let vendor: VendorIdentifier?
        public let text: String
        public let tone: MenuTone
        public let spoken: String
    }

    // MARK: Output

    public let now: Date
    /// Pools with plan windows and named Claude accounts awaiting a reading.
    public let pools: [Pool]
    /// Every qualifying pool in rank order, or the single caveat pick.
    public let ranking: [Pick]
    public let backSoon: [ReturnEntry]
    /// Snapshots whose Wallet lines are drawn, in display order.
    public let walletSnapshots: [QuotaSnapshot]
    public let menuTitle: MenuTitle

    // MARK: Build

    public init(
        snapshots: [QuotaSnapshot], now: Date = Date(), serviceOrder: [VendorIdentifier] = []
    ) {
        self.now = now
        let quota = snapshots.filter { $0.category != .developerLimits }
        let instanceCounts = Dictionary(grouping: quota, by: Self.identityGroup).mapValues(\.count)
        let pools = quota.compactMap { snapshot -> Pool? in
            Self.pool(for: snapshot, now: now, ambiguous: (instanceCounts[Self.identityGroup(snapshot)] ?? 0) > 1)
        }
        self.pools = pools

        // Use now.
        let candidates = pools.filter { $0.state == .usable && !$0.isStale }
        let qualifying = candidates.compactMap { Self.qualifyingPick($0, now: now) }
            .sorted(by: Self.ranksAbove)
        if qualifying.isEmpty, let caveat = Self.caveatPick(from: pools, now: now) {
            ranking = [caveat]
        } else {
            ranking = qualifying.map(\.pick)
        }

        // Back soon.
        backSoon = pools.filter { $0.state == .spent }
            .map { Self.returnEntry($0, now: now) }
            .sorted(by: Self.returnsBefore)

        // Keep the saved service order even if the store delivered the
        // snapshots in deadline order. Preserve the account order within each.
        let wallet = snapshots.filter(Self.hasWalletLine)
        if serviceOrder.isEmpty {
            walletSnapshots = wallet
        } else {
            var seen: Set<String> = []
            var order = serviceOrder.map(Self.serviceName(for:)).filter { seen.insert($0).inserted }
            for pool in pools where seen.insert(pool.service).inserted { order.append(pool.service) }
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
            walletSnapshots = wallet.sorted {
                (rank[Self.serviceName(for: $0.vendorId)] ?? .max) < (rank[Self.serviceName(for: $1.vendorId)] ?? .max)
            }
        }
        menuTitle = Self.menuTitle(ranking: ranking, pools: pools, backSoon: backSoon, now: now)
    }

    // MARK: Pools

    static func pool(for snapshot: QuotaSnapshot, now: Date, ambiguous: Bool) -> Pool? {
        let plan = snapshot.quotaBars.filter { $0.allowanceRole == .plan }
        let supplementary = snapshot.quotaBars.filter { $0.allowanceRole != .plan }
        // A failed poll can return a known Claude account without any bars.
        // Keep its row so the user can see why no quota is available.
        let readFailed = snapshot.category == .aiSubscriptions
            && snapshot.status.unavailableReason.map { $0 != .notConfigured } == true
        let accountBlocked = snapshot.badgeText == "Blocked"
        guard !plan.isEmpty || isNamedClaudeAccount(snapshot) || readFailed || accountBlocked else { return nil }
        let windows = plan.map { window(for: $0, now: now) }
        // The vendor's account-level block (Command Code's `limited`) is
        // carried on the badge, not on a bar; it stops the pool all the same.
        let anySpent = accountBlocked || windows.contains(where: \.isSpent)
        let measured = windows.contains { $0.remaining != nil || $0.bar.isBlocked }

        let state: PoolState
        if !measured && !accountBlocked {
            state = .unreadable
        } else if anySpent {
            let bonusOpen = supplementary.contains {
                $0.allowanceRole == .bonus && !$0.isBlocked
                    && ($0.primaryFraction.map { $0 < QuotaSnapshot.exhaustionThreshold } ?? false)
            }
            state = bonusOpen ? .onBonus : .spent
        } else {
            state = .usable
        }

        let spentResets = windows.filter(\.isSpent).map(\.bar.resetsAt)
        let returnsAt: Date? = (accountBlocked && spentResets.isEmpty) || spentResets.contains(where: { $0 == nil })
            ? nil : spentResets.compactMap { $0 }.max()
        let paidOpen = supplementary.contains {
            $0.allowanceRole == .paidOverage && !$0.isBlocked
                && ($0.primaryFraction.map { $0 < QuotaSnapshot.exhaustionThreshold } ?? false)
        }
        let (service, name) = names(for: snapshot)
        return Pool(
            snapshot: snapshot, service: service, name: name,
            accountTag: ambiguous ? accountTag(for: snapshot, fallback: name) : nil,
            state: state, isStale: snapshot.staleReading != nil, windows: windows,
            isAheadOfPace: state == .usable && windows.contains(where: \.isAheadOfPace),
            returnsAt: returnsAt, hasPaidOverage: paidOpen
        )
    }

    static func window(for bar: DualBarMetrics, now: Date) -> Window {
        let isLong: Bool = if let length = bar.windowLength {
            length >= longWindowMinimum
        } else {
            ["WK", "MO"].contains(bar.label.uppercased())
        }
        let spent = bar.isBlocked
            || (bar.primaryFraction.map { $0 >= QuotaSnapshot.exhaustionThreshold } ?? false)
        let remaining = bar.primaryFraction.map { 1 - min(max($0, 0), 1) }
        var risk: Double? = nil
        if isLong, !spent, let remaining, let reset = bar.resetsAt, let length = bar.windowLength, length > 0 {
            let share = reset.timeIntervalSince(now) / length
            if share > 0 { risk = remaining / min(share, 1) }
        }
        var ahead = false
        if !spent, let used = bar.primaryFraction, let elapsed = bar.paceMarker, elapsed < 0.5 {
            ahead = used - elapsed >= aheadOfPaceLead
        }
        return Window(bar: bar, remaining: remaining, isLong: isLong, headroomAtRisk: risk,
                      isAheadOfPace: ahead, isSpent: spent)
    }

    /// Which instances share an identity for the menu bar's account tag.
    static func identityGroup(_ snapshot: QuotaSnapshot) -> String {
        snapshot.vendorId.rawValue
    }

    private static func isNamedClaudeAccount(_ snapshot: QuotaSnapshot) -> Bool {
        snapshot.vendorId == .claude && snapshot.id.hasPrefix(ClaudeAccount.instancePrefix)
    }

    /// The service block a vendor's pools sit in, as `names(for:)` names it.
    public static func serviceName(for vendor: VendorIdentifier) -> String {
        switch vendor {
        case .claude: "Claude Code"
        case .gemini, .antigravityClaude, .antigravityArgon: "Antigravity"
        case .openai: "Codex"
        case .opencode: "OpenCode Go"
        case .githubRest, .githubGraphql: "GitHub"
        default: vendor.displayName
        }
    }

    static func names(for snapshot: QuotaSnapshot) -> (service: String, name: String) {
        let service = serviceName(for: snapshot.vendorId)
        switch snapshot.vendorId {
        case .claude:
            let name = snapshot.claudeAccount?.name ?? (isNamedClaudeAccount(snapshot) ? snapshot.displayName : service)
            return (service, name)
        case .gemini, .antigravityClaude, .antigravityArgon:
            let model = switch snapshot.vendorId {
            case .gemini: "Gemini"
            case .antigravityArgon: "Argon"
            default: "Claude"
            }
            return (service, snapshot.antigravityAccount.map { "\(model) · \($0.name)" } ?? model)
        case .openai:
            return (service, service)
        case .opencode:
            return (service, snapshot.displayName)
        default:
            return (service, snapshot.rowTitle)
        }
    }

    static func accountTag(for snapshot: QuotaSnapshot, fallback: String) -> String {
        let raw = snapshot.claudeAccount?.name ?? snapshot.antigravityAccount?.name ?? fallback
        return raw.count > 12 ? String(raw.prefix(11)) + "…" : raw
    }

    // MARK: Ranking

    private struct Ranked {
        let pick: Pick
        let tier: Int
        let key: Double
    }

    private static func qualifyingPick(_ pool: Pool, now: Date) -> Ranked? {
        let long = pool.windows.filter { $0.isLong && $0.remaining != nil }
        let short = pool.windows.filter { !$0.isLong && $0.remaining != nil }
        if !long.isEmpty {
            guard long.allSatisfy({ ($0.remaining ?? 0) >= qualifyingFloor }) else { return nil }
            let scored = long.filter { $0.headroomAtRisk != nil }
            if let binding = scored.min(by: { $0.headroomAtRisk! < $1.headroomAtRisk! }) {
                return Ranked(pick: Pick(pool: pool, binding: binding, reason: reason(binding, now: now),
                                         isCaveat: false, score: binding.headroomAtRisk),
                              tier: 1, key: binding.headroomAtRisk!)
            }
            let binding = long.min { $0.remaining! < $1.remaining! }!
            return Ranked(pick: Pick(pool: pool, binding: binding, reason: reason(binding, now: now),
                                     isCaveat: false, score: nil),
                          tier: 2, key: binding.remaining!)
        }
        guard let binding = short.min(by: { $0.remaining! < $1.remaining! }),
              binding.remaining! >= qualifyingFloor else { return nil }
        return Ranked(pick: Pick(pool: pool, binding: binding, reason: reason(binding, now: now),
                                 isCaveat: false, score: nil),
                      tier: 3, key: binding.remaining!)
    }

    private static func ranksAbove(_ a: Ranked, _ b: Ranked) -> Bool {
        if a.tier != b.tier { return a.tier < b.tier }
        if a.key != b.key { return a.key > b.key }
        return false
    }

    /// Decision 11: when nothing qualifies, name the usable pool with the most
    /// left in its least-remaining plan window, marked as weak. A pool on its
    /// bonus allowance is eligible only here. Stale and spent pools never are.
    private static func caveatPick(from pools: [Pool], now: Date) -> Pick? {
        let eligible = pools.filter { ($0.state == .usable || $0.state == .onBonus) && !$0.isStale }
        let best = eligible.compactMap { pool -> (Pool, Window)? in
            let measured = pool.windows.filter { $0.remaining != nil && !$0.isSpent }
            let preferred = measured.filter(\.isLong).isEmpty ? measured : measured.filter(\.isLong)
            guard let binding = preferred.min(by: { $0.remaining! < $1.remaining! }) else { return nil }
            return (pool, binding)
        }.max { $0.1.remaining! < $1.1.remaining! }
        guard let (pool, binding) = best else {
            // A pool on bonus whose plan windows are all spent has no plan
            // window left to name; its reason is the bonus itself.
            guard let bonus = eligible.first(where: { $0.state == .onBonus }),
                  let bar = bonus.snapshot.quotaBars.first(where: { $0.allowanceRole == .bonus }) else { return nil }
            let w = window(for: bar, now: now)
            return Pick(pool: bonus, binding: w, reason: "on bonus · \(percent(w.remaining ?? 0))% left",
                        isCaveat: true, score: nil)
        }
        let text = pool.state == .onBonus
            ? "on bonus"
            : "only \(percent(binding.remaining!))% \(binding.bar.label) left"
        return Pick(pool: pool, binding: binding, reason: text, isCaveat: true, score: binding.headroomAtRisk)
    }

    static func reason(_ window: Window, now: Date) -> String {
        let left = "\(percent(window.remaining ?? 0))% \(window.bar.label) left"
        guard let reset = window.bar.resetsAt else { return "\(left) · reset not published" }
        return "\(left) · resets in \(countdown(reset, now: now))"
    }

    /// Floored, so a figure never overstates headroom (99.8% left reads 99%).
    static func percent(_ remaining: Double) -> Int {
        Int((min(max(remaining, 0), 1) * 100 + 1e-9).rounded(.down))
    }

    /// A used share as every "% used" figure prints it: the Subscriptions
    /// cell, the Wallet meter and the menu-bar title. One formatter, so a tie
    /// such as 12.5% rounds the same way in all three.
    static func usedPercentText(_ used: Double) -> String {
        min(max(used, 0), 1).formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Back soon

    static func returnEntry(_ pool: Pool, now: Date) -> ReturnEntry {
        let spent = pool.windows.filter(\.isSpent)
        let label = spent.max { ($0.bar.resetsAt ?? .distantFuture) < ($1.bar.resetsAt ?? .distantFuture) }?.bar.label
        let blocked = pool.snapshot.badgeText == "Blocked" || spent.contains { $0.bar.isBlocked }
        let text: String
        if let at = pool.returnsAt {
            text = at > now
                ? countdown(at, now: now)
                : "Reset passed \(MetricDetailPresentation.clockText(at, now: now)) · awaiting reading"
        } else {
            text = "Return not published"
        }
        return ReturnEntry(pool: pool, returnText: text, windowLabel: label, isBlocked: blocked)
    }

    private static func returnsBefore(_ a: ReturnEntry, _ b: ReturnEntry) -> Bool {
        switch (a.pool.returnsAt, b.pool.returnsAt) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        default: return false
        }
    }

    /// Two units, so nine returns can be told apart: "1d 14h", "5h 20m", "12m".
    /// One unit, never two (owner, 23 Nov 2026: "don't mix time units"):
    /// minutes under an hour, hours under two days, then days, each rounded.
    /// 43.9h is "44h"; 125h is "5d". Every countdown in the glance and the
    /// menu-bar title reads this, so no two can disagree in format.
    public static func countdown(_ date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        let minutes = Int((interval / 60).rounded())
        guard minutes > 0 else { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = Int((interval / 3600).rounded())
        if hours < 48 { return "\(hours)h" }
        return "\(Int((interval / 86_400).rounded()))d"
    }

    /// `countdown` in words, the same unit and rounding: "44 hours", "5 days".
    public static func countdownSpoken(_ date: Date, now: Date) -> String {
        let text = countdown(date, now: now)
        guard text != "now", let unit = text.last, let value = Int(text.dropLast()) else { return text }
        let word = switch unit { case "m": "minute"; case "h": "hour"; default: "day" }
        return "\(value) \(word)\(value == 1 ? "" : "s")"
    }

    // MARK: Wallet

    static func hasWalletLine(_ snapshot: QuotaSnapshot) -> Bool {
        if !snapshot.apiCredits.isEmpty || snapshot.monthlyAPICredit != nil
            || snapshot.openAIMonthlyCredit != nil || snapshot.geminiAPICredit != nil { return true }
        if (snapshot.resetCreditsAvailable ?? 0) > 0 { return true }
        // A direct balance (OpenRouter, DeepSeek's own credit) lives only in
        // the Wallet, so the Wallet takes it whatever its reading: a failed
        // read carries a placeholder metric, and dropping it here would hide
        // the failure from both sections. The same predicate keeps it out of
        // Subscriptions.
        if ProviderGridPresentation.isDirectBalance(snapshot) { return true }
        // A balance-only vendor: its whole row is a balance.
        if snapshot.quotaBars.allSatisfy({ $0.allowanceRole != .plan }), snapshot.category != .developerLimits {
            switch snapshot.metric {
            case .currency, .credits: return true
            default: return false
            }
        }
        return false
    }

    // MARK: Menu bar

    static func menuTitle(ranking: [Pick], pools: [Pool], backSoon: [ReturnEntry], now: Date) -> MenuTitle {
        if let pick = ranking.first {
            let who = pick.pool.accountTag ?? pick.pool.name
            // % used, as the popover's bars print it (owner, 24 Nov 2026), and
            // rounded as they round, so the title and the pick's cell agree.
            // The spoken label keeps the reason's "% left", which names its
            // direction.
            let used = "\(usedPercentText(pick.binding.used ?? 0)) \(pick.binding.bar.label) used"
            let reset = pick.binding.bar.resetsAt.map { countdown($0, now: now) }
            let text = ([who, used] + [reset].compactMap { $0 }).joined(separator: " · ")
            let spoken = "Use \(pick.pool.service) \(pick.pool.name): \(pick.reason)"
                + (pick.isCaveat ? ". Best available, not a strong pick" : "")
            return MenuTitle(vendor: pick.pool.snapshot.vendorId, text: text,
                             tone: pick.isCaveat ? .caveat : .normal, spoken: spoken)
        }
        let next = backSoon.first { ($0.pool.returnsAt ?? .distantPast) > now }
            .map { countdown($0.pool.returnsAt!, now: now) }
        let readable = pools.filter { $0.state != .unreadable }
        if readable.isEmpty {
            return MenuTitle(vendor: nil, text: "No readings", tone: .unknown,
                             spoken: "No provider could be read")
        }
        let uncertain = pools.contains { $0.state == .unreadable || $0.isStale }
        if uncertain {
            let tail = next.map { "next \($0)" } ?? "returns unknown"
            return MenuTitle(vendor: nil, text: "None confirmed usable · \(tail)", tone: .unknown,
                             spoken: "No pool confirmed usable; \(tail)")
        }
        let unknownReturns = backSoon.contains { $0.pool.returnsAt == nil }
        let tail = next.map { "next \($0)" + (unknownReturns ? " · others unknown" : "") }
            ?? "return not published"
        return MenuTitle(vendor: nil, text: "All spent · \(tail)", tone: .critical,
                         spoken: "Every pool is spent; \(tail)")
    }
}
