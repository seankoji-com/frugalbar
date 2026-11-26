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
        /// The vendor's published reset for this window has passed: its figure
        /// describes the window that ended, not the one running now.
        public var isExpired: Bool = false
        /// The share used, as the bars draw it: 1 − `remaining`, nil when no
        /// fraction was published.
        public var used: Double? { remaining.map { 1 - $0 } }
    }

    /// Whether a pool's figures describe now. The one answer every surface
    /// reads (the pick, return hints, the grid's note line, the inspector),
    /// so none can recommend or reassure from figures another calls old.
    public enum Freshness: Equatable, Sendable {
        /// The newest poll measured it, and every window is still running.
        case current
        /// The newest poll failed; these figures are from an earlier one.
        case stale
        /// A window's published reset has passed and no reading since has
        /// shown the new window: its figure is the old window's.
        case awaitingReset
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
        /// The window whose published reset dates an account block, so a
        /// return hint names that window rather than a sibling's.
        public let datedBlockWindowLabel: String?

        /// The vendor, not the user's own use, stopped this pool: the account
        /// badge (`QuotaSnapshot.isAccountBlocked`) or a blocked plan window.
        /// The one definition every "blocked" word on the glance reads.
        public var isBlocked: Bool {
            snapshot.isAccountBlocked || windows.contains { $0.isSpent && $0.bar.isBlocked }
        }

        public var freshness: Freshness {
            if isStale { return .stale }
            return windows.contains(where: \.isExpired) ? .awaitingReset : .current
        }

        /// Its figures describe now (`freshness == .current`).
        public var isCurrent: Bool { freshness == .current }
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
        // Only a pool whose figures describe now: a stale one, or one whose
        // window reset with no reading since, is unconfirmed, never a pick.
        let candidates = pools.filter { $0.state == .usable && $0.isCurrent }
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
        // A Wallet line exists only for a configured balance: an unconfigured
        // direct-balance vendor draws none, so the menu bar must not point to it.
        menuTitle = Self.menuTitle(ranking: ranking, pools: pools, backSoon: backSoon, now: now,
                                   hasWallet: walletSnapshots.contains { $0.status.unavailableReason != .notConfigured })
    }

    // MARK: Pools

    static func pool(for snapshot: QuotaSnapshot, now: Date, ambiguous: Bool) -> Pool? {
        let plan = snapshot.quotaBars.filter { $0.allowanceRole == .plan }
        let supplementary = snapshot.quotaBars.filter { $0.allowanceRole != .plan }
        // A failed poll can return a known Claude account without any bars.
        // Keep its row so the user can see why no quota is available.
        let readFailed = snapshot.category == .aiSubscriptions
            && snapshot.status.unavailableReason.map { $0 != .notConfigured } == true
        let accountBlocked = snapshot.isAccountBlocked
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
            let bonusOpen = supplementary.contains { Self.isOpenBonus($0, now: now) }
            state = bonusOpen ? .onBonus : .spent
        } else {
            state = .usable
        }

        let spentResets = windows.filter(\.isSpent).map(\.bar.resetsAt)
        // An account the vendor blocked on its badge has no published return:
        // its windows' resets say when each window turns over, not when the
        // account-wide block lifts, so neither is offered as the pool's return.
        // Unless the vendor dated the block — the pool it ran out of
        // (`accountBlockDatedByBarLabel`) or the window it blocked itself — then the
        // reset we hold is exactly that date, and withholding it left Command
        // Code and OpenCode Go showing a block with no reset at all.
        // A dated block returns at the one reset that dates it, never at a
        // sibling window's: a badge-blocked 5H sibling can reset in an hour
        // while the block runs to the month's end.
        let returnsAt: Date? = accountBlocked
            ? snapshot.accountBlockEnd
            : (spentResets.contains(where: { $0 == nil })
                ? nil : spentResets.compactMap { $0 }.max())
        let datedBlockWindowLabel = accountBlocked ? snapshot.accountBlockDatedWindowLabel : nil
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
            returnsAt: returnsAt, hasPaidOverage: paidOpen,
            datedBlockWindowLabel: datedBlockWindowLabel
        )
    }

    /// A bonus allowance that can take a job now: not blocked, not used up,
    /// and not past the expiry the vendor published (Kiro's `BN` carries it
    /// in `resetsAt`). An expired bonus was still winning "Best available".
    static func isOpenBonus(_ bar: DualBarMetrics, now: Date) -> Bool {
        bar.allowanceRole == .bonus && !bar.isBlocked
            && (bar.primaryFraction.map { $0 < QuotaSnapshot.exhaustionThreshold } ?? false)
            && (bar.resetsAt.map { $0 > now } ?? true)
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
                      isAheadOfPace: ahead, isSpent: spent,
                      isExpired: bar.resetsAt.map { $0 <= now } ?? false)
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
        let eligible = pools.filter { ($0.state == .usable || $0.state == .onBonus) && $0.isCurrent }
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
                  let bar = bonus.snapshot.quotaBars.first(where: { Self.isOpenBonus($0, now: now) }) else { return nil }
            let w = window(for: bar, now: now)
            return Pick(pool: bonus, binding: w,
                        reason: w.remaining.map { "on bonus · \(percent($0))% left" } ?? "on bonus",
                        isCaveat: true, score: nil)
        }
        // The reset is part of the reason, as for a qualifying pick: the title
        // shows it, so the spoken label must say it too.
        let resetClause = binding.bar.resetsAt.map { reset -> String in
            let when = countdown(reset, now: now)
            return when == "due" ? " · reset due" : " · resets in \(when)"
        } ?? ""
        let text = pool.state == .onBonus
            ? "on bonus"
            : "only \(percent(binding.remaining!))% \(binding.bar.label) left\(resetClause)"
        return Pick(pool: pool, binding: binding, reason: text, isCaveat: true, score: binding.headroomAtRisk)
    }

    static func reason(_ window: Window, now: Date) -> String {
        // Never a "0% left" for a window that published no figure.
        let left = window.remaining.map { "\(percent($0))% \(window.bar.label) left" }
            ?? "\(window.bar.label) not measured"
        guard let reset = window.bar.resetsAt else { return "\(left) · reset not published" }
        let when = countdown(reset, now: now)
        return when == "due" ? "\(left) · reset due" : "\(left) · resets in \(when)"
    }

    /// Floored, so a figure never overstates headroom (99.8% left reads 99%).
    static func percent(_ remaining: Double) -> Int {
        Int((min(max(remaining, 0), 1) * 100 + 1e-9).rounded(.down))
    }

    /// A used share as every "% used" figure prints it: the Subscriptions
    /// cell, the Wallet meter and the menu-bar title. One formatter, so a tie
    /// such as 12.5% rounds the same way in all three.
    ///
    /// It never rounds across a state boundary: a window under the spent
    /// threshold never prints "100%" (99.6% used is not spent, and draws no
    /// stripes), and a nonzero share never prints "0%" beside a bar that
    /// shows a sliver. Spoken labels use `usedPercentSpoken`, the same figure.
    static func usedPercentText(_ used: Double) -> String {
        let clamped = min(max(used, 0), 1)
        if clamped > 0, clamped < 0.005 { return "<1%" }
        let shown = clamped >= QuotaSnapshot.exhaustionThreshold ? clamped : min(clamped, 0.99)
        return shown.formatted(.percent.precision(.fractionLength(0)))
    }

    /// `usedPercentText` as VoiceOver should read it.
    static func usedPercentSpoken(_ used: Double) -> String {
        let text = usedPercentText(used)
        return text == "<1%" ? "under 1%" : text
    }

    /// `usedPercentSpoken` in words: "58 percent", "under 1 percent".
    static func usedPercentWords(_ used: Double) -> String {
        usedPercentSpoken(used).replacingOccurrences(of: "%", with: " percent")
    }

    // MARK: Back soon

    static func returnEntry(_ pool: Pool, now: Date) -> ReturnEntry {
        let spent = pool.windows.filter(\.isSpent)
        let label = pool.datedBlockWindowLabel
            ?? spent.max { ($0.bar.resetsAt ?? .distantFuture) < ($1.bar.resetsAt ?? .distantFuture) }?.bar.label
        let blocked = pool.isBlocked
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
    ///
    /// A time that has passed is "due" (the reset is owed, no reading has
    /// shown it yet) and one under half a minute away is "<1m": "now" read
    /// as "resets in now" in sentences and as "back now" beside a 100% bar.
    public static func countdown(_ date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "due" }
        let minutes = Int((interval / 60).rounded())
        guard minutes > 0 else { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = Int((interval / 3600).rounded())
        if hours < 48 { return "\(hours)h" }
        return "\(Int((interval / 86_400).rounded()))d"
    }

    /// `countdown` in words, the same unit and rounding: "44 hours", "5 days".
    public static func countdownSpoken(_ date: Date, now: Date) -> String {
        let text = countdown(date, now: now)
        if text == "due" { return "now, awaiting a reading" }
        if text == "<1m" { return "under a minute" }
        guard let unit = text.last, let value = Int(text.dropLast()) else { return text }
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

    /// The pool's spoken name: "Codex", not "Codex Codex"; "Claude Code
    /// Primary" when the pool has its own name.
    static func spokenName(_ pool: Pool) -> String {
        pool.name == pool.service || pool.name.hasPrefix(pool.service) ? pool.name : "\(pool.service) \(pool.name)"
    }

    /// The return a hint may promise: the soonest published one still ahead,
    /// from a current reading. A stale pool's reset is the schedule of a poll
    /// that has since failed, so it is not offered as the next return (the
    /// menu bar's "next …" and the popover's "Back soonest" both read this).
    static func soonestReturn(_ backSoon: [ReturnEntry], now: Date) -> ReturnEntry? {
        backSoon.first { !$0.pool.isStale && ($0.pool.returnsAt ?? .distantPast) > now }
    }

    /// - Parameter format: how a countdown is printed. The menu bar keeps its
    ///   own unit (`countdown`, days from 48h); the popover's Use-now line
    ///   passes Subscriptions' compact one, so it agrees with the rows below it.
    static func menuTitle(ranking: [Pick], pools: [Pool], backSoon: [ReturnEntry], now: Date,
                          hasWallet: Bool = true,
                          format: (Date, Date) -> String = { countdown($0, now: $1) }) -> MenuTitle {
        if let pick = ranking.first {
            let who = pick.pool.accountTag ?? pick.pool.name
            // % used, as the popover's bars print it (owner, 24 Nov 2026), and
            // rounded as they round, so the title and the pick's cell agree.
            // The spoken label keeps the reason's "% left", which names its
            // direction.
            let used = pick.binding.used.map { "\(usedPercentText($0)) \(pick.binding.bar.label) used" }
            let reset = pick.binding.bar.resetsAt.map { format($0, now) }
            // A bonus pick says so: starting a job there spends a bonus
            // allowance that expires, not a plan that resets.
            let onBonus = pick.binding.bar.allowanceRole == .bonus ? "on bonus" : nil
            let text = ([who] + [onBonus, used, reset].compactMap { $0 }).joined(separator: " · ")
            let spoken = "Use \(spokenName(pick.pool)): \(pick.reason)"
                + (pick.isCaveat ? ". Best available, not a strong pick" : "")
            return MenuTitle(vendor: pick.pool.snapshot.vendorId, text: text,
                             tone: pick.isCaveat ? .caveat : .normal, spoken: spoken)
        }
        let next = soonestReturn(backSoon, now: now).map { format($0.pool.returnsAt!, now) }
        // A published reset that has passed with no reading since: the return
        // is owed, not unpublished.
        let resetPassed = backSoon.contains {
            !$0.pool.isStale && ($0.pool.returnsAt.map { $0 <= now } ?? false)
        }
        // Only balances (OpenRouter, DeepSeek's API credit) and no quota pool:
        // nothing failed, there is simply no subscription to pick from.
        if pools.isEmpty {
            return MenuTitle(vendor: nil, text: "No subscriptions", tone: .unknown,
                             spoken: "No subscription quota to pick from"
                                + (hasWallet ? "; balances are in the Wallet" : ""))
        }
        let readable = pools.filter { $0.state != .unreadable }
        if readable.isEmpty {
            // About subscription pools only: a Wallet balance may well have
            // been read.
            return MenuTitle(vendor: nil, text: "No readings", tone: .unknown,
                             spoken: "No subscription could be read")
        }
        let uncertain = pools.contains { $0.state == .unreadable || !$0.isCurrent }
        if uncertain {
            // A return is claimed unknown only when something is waiting to
            // return; with nothing spent there is no return to speak of.
            let tail = next.map { "next \($0)" }
                ?? (resetPassed ? "reset passed · awaiting reading" : (backSoon.isEmpty ? nil : "returns unknown"))
            let text = ["None confirmed usable", tail].compactMap { $0 }.joined(separator: " · ")
            return MenuTitle(vendor: nil, text: text, tone: .unknown,
                             spoken: ["No pool confirmed usable", tail].compactMap { $0 }.joined(separator: "; "))
        }
        let unknownReturns = backSoon.contains { $0.pool.returnsAt == nil }
        let tail = next.map { "next \($0)" + (unknownReturns ? " · others unknown" : "") }
            ?? (resetPassed ? "reset passed · awaiting reading" : "return not published")
        return MenuTitle(vendor: nil, text: "All spent · \(tail)", tone: .critical,
                         spoken: "Every pool is spent; \(tail)")
    }
}
