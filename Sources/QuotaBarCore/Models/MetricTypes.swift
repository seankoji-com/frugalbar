import Foundation

// MARK: - Vendor identifiers

public enum VendorIdentifier: String, Sendable, CaseIterable, Codable {
    case claude
    case openai
    case gemini
    case antigravityClaude = "antigravity_claude"
    case antigravityArgon = "antigravity_argon"
    case opencode
    case copilot
    case openrouter
    case deepseek
    case grok
    case kiro
    case devpass
    case commandcode
    case clinepass
    case muse
    case githubRest   = "github_rest"
    case githubGraphql = "github_graphql"

    public var displayName: String {
        switch self {
        case .claude:        "Claude"
        case .openai:        "OpenAI"
        case .gemini:        "Gemini"
        case .antigravityClaude: "AGY Claude/GPT"
        case .antigravityArgon: "AGY Argon"
        case .opencode:      "OpenCode"
        case .copilot:       "GitHub Copilot"
        case .openrouter:    "OpenRouter"
        case .deepseek:      "DeepSeek"
        case .grok:          "Grok"
        case .kiro:          "Kiro"
        case .devpass:       "DevPass"
        case .commandcode:   "Command Code"
        case .clinepass:     "ClinePass"
        case .muse:          "Muse"
        case .githubRest:    "GitHub REST"
        case .githubGraphql: "GitHub GraphQL"
        }
    }

    public var accentColorHex: String {
        switch self {
        case .claude:        "#d97757"
        case .openai:        "#10a37f"
        case .gemini:        "#3b82f6"
        case .antigravityClaude: "#d97757"
        case .antigravityArgon: "#3b82f6"
        case .opencode:      "#d47b00"
        case .copilot:       "#6e7681"
        case .openrouter:    "#d47b00"
        // DeepSeek's brand blue; the badge background is the same colour.
        case .deepseek:      "#4d6bfe"
        case .grok:          "#1a9fff"
        case .kiro:          "#9046ff"
        case .devpass:       "#00b8a9"
        // Command Code's brand "Burple" foreground; its badge background is
        // #2E1B9C, used for the avatar rather than this accent.
        case .commandcode:   "#546bf3"
        // Indigo chosen to read as Cline's brand blue; not taken from a
        // published brand sheet.
        case .clinepass:     "#5b5bd6"
        // Meta's own blue, the family Muse Code belongs to; not taken from a
        // published Muse brand sheet.
        case .muse:          "#0866ff"
        case .githubRest:    "#ffb4ab"
        case .githubGraphql: "#ffb4ab"
        }
    }

    public var iconSymbol: String {
        switch self {
        case .claude:        "sparkles"
        case .openai:        "circle.hexagongrid.fill"
        case .gemini:        "sparkle"
        case .antigravityClaude: "sparkles"
        case .antigravityArgon: "sparkle"
        case .opencode:      "chevron.left.forwardslash.chevron.right"
        case .copilot:       "curlybraces"
        case .openrouter:    "arrow.triangle.branch"
        case .deepseek:      "brain.head.profile"
        case .grok:          "xmark"
        case .kiro:          "bolt"
        case .devpass:       "ticket"
        case .commandcode:   "command"
        case .clinepass:     "ticket.fill"
        case .muse:          "wand.and.stars"
        case .githubRest:    "network"
        case .githubGraphql: "point.3.connected.trianglepath.dotted"
        }
    }
}


// MARK: - Metric types

public enum MetricType: Sendable, Equatable {
    /// 0.0 … 1.0 used fraction, optional detail string
    case percentage(usedFraction: Double, displayDetails: String?)
    case count(remaining: Int, limit: Int, unitName: String)
    case currency(balance: Decimal, limit: Decimal?, spent: Decimal?, currencyCode: String)
    /// A count the vendor published in a unit of its own that is **not
    /// money** — OpenAI's API credits, which its own console reads as
    /// "62,500 credits remaining". Every figure is rendered in that unit,
    /// verbatim: never reformatted as currency, never scaled.
    ///
    /// `remaining` is nil only for a pool the vendor declares unlimited, which
    /// is a statement in its own right — the same reason `consumptionFraction`
    /// is optional. It is never a 0 standing in for "not reported".
    case credits(remaining: Decimal?, unitName: String)
    case subscription(tierName: String?, renewalDate: Date?)
}

// MARK: - Provider health

/// How much pressure the user's quota is under. This is the axis that drives
/// the menu bar icon: it answers "how urgent is this for my work right now?"
public enum Urgency: Int, Sendable, Comparable, CaseIterable {
    case none     = 0
    case warning  = 1   // usage > 70%  or credit < 25%
    case critical = 2   // usage > 90%  or credit < 10%

    public static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How much we trust the reading. Orthogonal to `Urgency` — a provider we
/// cannot read is not an emergency, and must never outrank one.
public enum Confidence: Int, Sendable, Comparable, CaseIterable {
    case measured    = 0   // we parsed a real response
    case unavailable = 1   // no reading: unauthenticated, offline, unsupported

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why a provider could not be read. Kept as a closed set so the UI can offer
/// a specific remedy — and so raw error text (which can embed credentials)
/// never reaches a user-facing or persisted field.
public enum UnavailableReason: Sendable, Equatable {
    case notConfigured            // no credential present
    case credentialRejected       // vendor said 401/403
    case unsupported(String)      // this account/response publishes no usable quota
    case offline                  // transport failure
    case timedOut
    case badResponse              // non-2xx, or a body we could not parse
    /// Vendor throttled us. A 429 on a metadata endpoint says nothing about
    /// the user's quota, so this is an absence of a reading — not an emergency.
    case rateLimited(retryAfter: Date?)

    public var headline: String {
        switch self {
        case .notConfigured:      "Not configured"
        case .credentialRejected: "Credential rejected"
        case .unsupported:        "No quota reading"
        case .offline:            "Offline"
        case .timedOut:           "Timed out"
        case .badResponse:        "Unexpected response"
        case .rateLimited:        "Rate limited"
        }
    }

    /// Short, actionable next step shown beneath the row.
    ///
    /// `rateLimited` is the one case that can say something more useful than
    /// "later": the vendor's own `Retry-After` was published with the 429, so
    /// when we have it the remedy names the window instead of leaving the user
    /// to guess whether the row is waiting or stuck.
    public var remedy: String {
        switch self {
        case .notConfigured:      return "Add a key in Settings"
        case .credentialRejected: return "Check the key in Settings"
        case .unsupported(let d): return d
        case .offline:            return "Check your connection"
        case .timedOut:           return "Vendor slow — will retry"
        case .badResponse:        return "Vendor returned unexpected data"
        case .rateLimited(let retryAfter):
            // A retry instant already in the past says nothing about the next
            // poll, so it falls back to the unquantified wording rather than
            // promising a retry that is not scheduled.
            guard let retryAfter, retryAfter.timeIntervalSinceNow > 0 else {
                return "Vendor throttling — will retry"
            }
            let minutes = max(1, Int((retryAfter.timeIntervalSinceNow / 60).rounded(.up)))
            return "Vendor throttling — retry in \(minutes) min"
        }
    }
}

public enum ProviderStatus: Sendable, Equatable {
    /// We have a real reading. `urgency` describes the quota pressure.
    case measured(Urgency)
    /// We have no reading. This is informational, never an emergency.
    case unavailable(UnavailableReason)

    // Convenience constructors that keep call sites readable.
    public static var healthy: ProviderStatus { .measured(.none) }
    public static var warning: ProviderStatus { .measured(.warning) }
    public static var critical: ProviderStatus { .measured(.critical) }
    public static var unauthenticated: ProviderStatus { .unavailable(.notConfigured) }
    public static func unsupported(_ reason: String) -> ProviderStatus {
        .unavailable(.unsupported(reason))
    }
    public static func rateLimited(retryAfter: Date?) -> ProviderStatus {
        .unavailable(.rateLimited(retryAfter: retryAfter))
    }

    /// Quota pressure only. An unreadable provider contributes `.none` — it is
    /// surfaced through `confidence`, not by masking a real emergency.
    public var urgency: Urgency {
        switch self {
        case .measured(let u):  u
        case .unavailable:      .none
        }
    }

    public var confidence: Confidence {
        switch self {
        case .measured:    .measured
        case .unavailable: .unavailable
        }
    }

    public var unavailableReason: UnavailableReason? {
        if case .unavailable(let r) = self { return r }
        return nil
    }
}

// MARK: - Metric categories

public enum MetricCategory: String, Sendable, CaseIterable, Codable {
    case aiSubscriptions     = "AI Subscriptions"
    case apiSpendAndCredits  = "API Spend & Credits"
    case developerLimits     = "Developer Limits"
}


// MARK: - Dual-bar burndown metrics

public struct DualBarMetrics: Sendable, Equatable {
    /// 0.0 to 1.0 (actual quota consumed). `nil` when the vendor declared the
    /// window blocked/critical (see `isBlocked`) but gave no percentage to
    /// measure it with — never coerced to 0 or 1 to fill the gap.
    public var primaryFraction: Double?
    /// `primaryFraction` floored to 0 for callers checking "has this bar
    /// crossed some threshold" (exhaustion, criticality): a bar with no
    /// reading is correctly "not there yet", never coerced to look spent.
    /// Named once here instead of each call site repeating its own `?? 0`.
    public var primaryFractionOrUnmeasured: Double { primaryFraction ?? 0 }
    /// `primaryFraction` sunk below any real reading, for `max(by:)` ranking
    /// among a snapshot's bars: a bar with no reading must never outrank one
    /// that actually has a number just because `nil < 0` reads as true.
    public var primaryFractionForWorstBarRanking: Double { primaryFraction ?? -1 }
    public var expectedPaceFraction: Double?     // Pro-rata expected fraction elapsed in window (0.0 to 1.0)
    public var secondaryFraction: Double?       // delta / surge burndown fraction
    public var label: String                    // e.g. "5H", "WK", "REST", "GraphQL"
    /// The vendor's own colour for a *blocked* window (see `isBlocked`) —
    /// e.g. OpenCodeGo's rate-limited red. Never read unless `isBlocked` is
    /// also true, so it is meaningless — and should be left `nil` — for a
    /// provider that never sets `isBlocked`; `DualBarProgressView` derives
    /// every other window's colour from pace/exhaustion/urgency instead.
    public var blockedColor: String?
    /// The vendor told us outright that this window cannot be used at all
    /// right now (e.g. rate-limited), independent of whatever percentage — or
    /// lack of one — it also reported.
    public var isBlocked: Bool
    /// This bar measures elapsed time, not consumption.
    ///
    /// A billing cycle is drawn as a bar because a bar is the right picture of
    /// "how far through the period are we" — but 90% elapsed is not 10% of
    /// quota left, and every place that ranks headroom, picks a vendor to
    /// recommend, or decides a row is exhausted must skip it. Reading a cycle
    /// as consumption made the popover advise "DevPass has 97% remaining" from
    /// a plan whose credits were entirely untouched.
    public var measuresElapsedTimeOnly: Bool = false
    public var usedText: String?
    public var resetText: String?
    /// When this window resets, and how long it runs — the same two figures
    /// `proRataPace` was given to compute `expectedPaceFraction`. Carried here
    /// too so the burn-rate projection below can convert a fraction of the
    /// window back into a real date, instead of everyone reaching for a
    /// hardcoded window length. `nil` whenever the vendor gave no real reset
    /// or window length, in which case the projection is nil rather than
    /// invented.
    public var resetsAt: Date?
    public var windowLength: TimeInterval?
    /// The figures behind `usedText`, as structured values in `quantityUnit`,
    /// so the sync export never has to parse display text. Each is filled
    /// only from a number the provider already computed for that text, and
    /// left nil when it published none — never a 0 standing in for "not
    /// reported". Nothing on the Mac reads them.
    public var quantityUsed: Decimal?
    public var quantityRemaining: Decimal?
    public var quantityLimit: Decimal?
    public var quantityUnit: String?

    public init(
        primaryFraction: Double?,
        expectedPaceFraction: Double? = nil,
        secondaryFraction: Double? = nil,
        label: String,
        blockedColor: String? = nil,
        isBlocked: Bool = false,
        measuresElapsedTimeOnly: Bool = false,
        usedText: String? = nil,
        resetText: String? = nil,
        resetsAt: Date? = nil,
        windowLength: TimeInterval? = nil,
        quantityUsed: Decimal? = nil,
        quantityRemaining: Decimal? = nil,
        quantityLimit: Decimal? = nil,
        quantityUnit: String? = nil
    ) {
        self.primaryFraction = primaryFraction
        self.expectedPaceFraction = expectedPaceFraction
        self.secondaryFraction = secondaryFraction
        self.label = label
        self.blockedColor = blockedColor
        self.isBlocked = isBlocked
        self.measuresElapsedTimeOnly = measuresElapsedTimeOnly
        self.usedText = usedText
        self.resetText = resetText
        self.resetsAt = resetsAt
        self.windowLength = windowLength
        self.quantityUsed = quantityUsed
        self.quantityRemaining = quantityRemaining
        self.quantityLimit = quantityLimit
        self.quantityUnit = quantityUnit
    }

    /// Difference between actual consumption and pro-rata expected target, or
    /// nil when there is no target.
    /// Positive = burning faster than pro-rata pace (over budget).
    /// Negative = burning slower than pro-rata pace (healthy buffer).
    ///
    /// This used to fall back to a hardcoded 0.40/0.45/0.50 by label. No
    /// provider ever supplied a real figure, so *every* pace marker was that
    /// constant: a weekly bar six days into its window drew its marker at 45%
    /// of the track, claiming the user was far ahead of pace when they were far
    /// behind it. A fabricated denominator is the same defect as a fabricated
    /// quota — it just looks like geometry instead of a number.
    public var burndownDelta: Double? {
        guard let primaryFraction, let expectedPaceFraction else { return nil }
        return primaryFraction - expectedPaceFraction
    }

    /// How far past an even pace a window must be before it counts as ahead
    /// of it. Named once so the colour, the tooltip and the spoken label
    /// cannot each carry their own copy.
    public static let aheadOfPaceMargin = 0.04

    public var isAboveProrataPace: Bool {
        (burndownDelta ?? 0) > Self.aheadOfPaceMargin
    }

    /// How many times faster the quota is being consumed than the window is
    /// elapsing: 1.0 tracks pace exactly, 2.0 burns twice as fast (and so
    /// would run out halfway through the window). `nil` before there is a
    /// pace to compare against — a window barely open, or a vendor that gave
    /// no reset time at all.
    public var burnRateMultiplier: Double? {
        guard let primaryFraction, let expectedPaceFraction, expectedPaceFraction > 0.001 else { return nil }
        return primaryFraction / expectedPaceFraction
    }

    /// When the quota would hit 100% if consumption kept going at the average
    /// rate seen so far — extrapolated from `primaryFraction` over the
    /// elapsed share of the window, not from anything guessed. `nil` unless
    /// all three of a real reset date, a real window length, and a burn rate
    /// above pace are present: below pace, the window resets before the
    /// quota would ever run dry, so there is nothing to project.
    public var projectedExhaustionDate: Date? {
        guard let resetsAt, let windowLength, windowLength > 0,
              let elapsedFraction = expectedPaceFraction, elapsedFraction > 0.001,
              let primaryFraction, primaryFraction > elapsedFraction
        else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-windowLength)
        let secondsToExhaustion = elapsedFraction * windowLength / primaryFraction
        return windowStart.addingTimeInterval(secondsToExhaustion)
    }

    /// How far through a rolling window we are: the pro-rata share of the
    /// allowance that "should" be spent by now.
    ///
    /// Returns nil when either the reset time or the window length is unknown,
    /// which the UI renders as no marker at all.
    public static func proRataPace(
        resetsAt: Date?,
        windowLength: TimeInterval,
        now: Date = Date()
    ) -> Double? {
        guard let resetsAt, windowLength > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining.isFinite else { return nil }
        return min(max((windowLength - remaining) / windowLength, 0), 1)
    }

    /// Length of the calendar month ending at `reset`. Months are 28–31 days,
    /// so a 30-day constant would drift the marker by up to a day.
    public static func monthWindowLength(endingAt reset: Date) -> TimeInterval? {
        monthWindowLength(endingAt: reset, calendar: .current)
    }

    public static func monthWindowLength(endingAt reset: Date, calendar: Calendar) -> TimeInterval? {
        guard let start = calendar.date(byAdding: .month, value: -1, to: reset) else { return nil }
        let length = reset.timeIntervalSince(start)
        return length > 0 ? length : nil
    }
}

/// Rolling-window lengths the vendors actually use, so a pace marker is never
/// derived from a guess.
public enum QuotaWindow {
    public static let fiveHours: TimeInterval = 5 * 3600
    public static let week: TimeInterval = 7 * 24 * 3600
}


// MARK: - Quota snapshot (the core value type)

/// What the `balance` of a `.currency` metric actually represents.
///
/// Account credit and a key's remaining spend cap are both "a dollar figure
/// with no limit", so the shape alone cannot tell them apart — and the UI
/// labels them very differently. Carrying it explicitly beats inferring it
/// from a prose field that any copy edit would silently break.
public enum CurrencyBasis: String, Sendable, Codable, Equatable {
    /// Money actually sitting in the vendor account.
    case accountCredit
    /// Headroom left under a spend cap attached to this key.
    case keySpendCap
    /// Cumulative spend, with no cap to measure it against.
    case lifetimeSpend
    /// A credit pool the vendor refills on a schedule, as opposed to
    /// `accountCredit`'s standing balance — Anthropic's monthly extra-usage
    /// allowance. Kept apart from `accountCredit` because its spend figure is
    /// this period's, and printing it under "Lifetime used:" would assert a
    /// total nobody measured.
    case prepaidCredit

    /// Caption for the "spent" figure in the popover's currency block.
    public var spendLabel: String {
        switch self {
        case .accountCredit: "Lifetime used:"
        case .keySpendCap:   "Key spend:"
        case .lifetimeSpend: "Lifetime spend:"
        case .prepaidCredit: "Credit used:"
        }
    }

    /// Caption for the "balance" figure in the popover's currency block.
    public var balanceLabel: String {
        switch self {
        case .accountCredit: "Account credit:"
        case .keySpendCap:   "Key cap left:"
        case .lifetimeSpend: "Recorded spend:"
        case .prepaidCredit: "Credit left:"
        }
    }
}

/// The newest poll of a snapshot's provider failed, so the figures on the
/// snapshot are carried over from an earlier one.
///
/// A transient failure must not blank a row that already had a real reading —
/// but it must not disappear either. Retention used to replace the whole cached
/// snapshot, `status` and `lastUpdated` included, so a row kept presenting
/// hour-old figures as the provider's state *now*, the footer's "oldest
/// reading" froze for the length of the outage, and the history recorded the
/// carried-over figures as a fresh measurement. That is how a 59-minute Claude
/// failure read as a footer stuck on "57m" with every percentage on screen
/// still drawn as current.
///
/// A fact about the *poll*, never about the quota: it says nothing about usage,
/// only that the figures beside it were measured earlier.
public struct StaleReading: Sendable, Equatable {
    /// Why the poll failed. The same closed set a `.unavailable` status uses,
    /// so the row and the inspector can name the same remedy.
    public let reason: UnavailableReason
    /// When the failed poll happened — always later than the snapshot's
    /// `lastUpdated`, which is when the figures were really measured.
    public let at: Date

    public init(reason: UnavailableReason, at: Date) {
        self.reason = reason
        self.at = at
    }
}
public struct QuotaSnapshot: Sendable, Identifiable, Equatable {
    /// The provider *instance* this reading belongs to.
    ///
    /// Equals `vendorId.rawValue` for every single-instance provider. A vendor
    /// that serves several independent subscriptions under one account —
    /// OpenCode Go workspaces — gives each its own stable key, so two instances
    /// coexist in the cache, in history and in the event log instead of
    /// overwriting one another. It is never derived from a display name, so a
    /// rename does not move a reading.
    public let id: String
    public let vendorId: VendorIdentifier
    public let displayName: String
    public let category: MetricCategory
    public let metric: MetricType
    public let status: ProviderStatus
    public let resetsAt: Date?
    public let lastUpdated: Date
    public let auxiliaryInfo: String?

    public var row1: DualBarMetrics?
    public var row2: DualBarMetrics?
    public var row3: DualBarMetrics?
    public var badgeText: String?
    public var planName: String?
    public var latencyMs: Int?
    public var keyMasked: String?
    public var cliSource: String?
    public var currencyBasis: CurrencyBasis?
    /// Prepaid API credit balances the vendor published in the same payload as
    /// the quota this snapshot reports — OpenAI's `credits.balance`, Anthropic's
    /// `extra_usage` / promo credit.
    ///
    /// Carried here rather than fetched by an entry of their own, because the
    /// figure arrives in a response this snapshot already made: a second
    /// provider would duplicate the request and a second cache key would split
    /// one reading into two.
    ///
    /// These are *not* this snapshot's quota. They are drawn as their own
    /// labelled entries in the popover (`APICreditEntry` says why they are a
    /// separate type), and they take no part in `consumptionFraction`, the
    /// urgency bands, exhaustion sorting, the advice engine, the menu-bar icon
    /// or the history recorder — all of which read snapshots.
    public var apiCredits: [APICreditEntry] = []
    /// Independently observed linked Console entitlement, with its own reading time.
    public var monthlyAPICredit: ClaudeMonthlyCredit? = nil
    /// Banked usage-reset credits the vendor says the user can redeem right
    /// now (OpenAI's `rate_limit_reset_credits.available_count`). `nil` when
    /// the vendor published no such figure — never 0 as a stand-in, since
    /// "none available" and "the vendor has no such thing" are different
    /// facts. Defaulted here so no initializer or call site has to change.
    public var resetCreditsAvailable: Int? = nil
    /// How many of those banked credits the vendor says can be redeemed
    /// against the current window state (OpenAI's
    /// `rate_limit_reset_credits.applicable_available_count`). It flips with
    /// window state, so nothing fires on it changing; display only. `nil`
    /// when not published.
    public var resetCreditsApplicable: Int? = nil
    /// Set when this poll could not read the provider and the figures above
    /// were carried over from an earlier one. `nil` when they came from the
    /// newest poll — including a provider never read at all, whose absence is
    /// its `.unavailable` status rather than staleness.
    ///
    /// `status` deliberately stays whatever the carried-over snapshot said, so
    /// the last known quota pressure still drives the menu bar icon instead of
    /// being replaced by "cannot read" — an unreadable provider must never
    /// outrank a critical quota. This field is what tells every other surface
    /// that the reading behind those figures is old: the popover row marks it,
    /// the inspector names the reason, and the history records a failed poll
    /// instead of a new measurement. Defaulted here (not as an init parameter)
    /// so neither existing initializer, nor any other provider's call site, has
    /// to change.
    public var staleReading: StaleReading? = nil

    /// The vendor's windows, longest period first — month, then week, then
    /// the five-hour bucket.
    ///
    /// Providers assign `row1…row3` in whatever order their payload arrives,
    /// which put Claude's 5H above its WK and OpenCode's 5H above its MO. The
    /// long window is the one that constrains planning, so it leads. Windows
    /// with no length at all (a bonus pool, an overage allowance) have no
    /// period to rank and sort last, keeping their relative order.
    public var bars: [DualBarMetrics] {
        [row1, row2, row3].compactMap { $0 }
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.windowLength, rhs.element.windowLength) {
                case let (l?, r?) where l != r: return l > r
                case (nil, .some):             return false
                case (.some, nil):             return true
                default:                       return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// At or past this fraction a window is spent. Not 1.0: a vendor that
    /// reports 0.9999 has nothing left either, and float residue should not
    /// decide whether a row reads as exhausted.
    public static let exhaustionThreshold = 0.999

    /// At least one consumable window is spent-out or outright blocked.
    ///
    /// Deliberately "any", not "every": this backs `sortBand`'s exhausted
    /// bucket, and a vendor with even one spent window — its five-hour
    /// bucket, say, even with a healthy monthly allowance behind it — is not
    /// somewhere to send work *right now*, whatever headroom sits in a
    /// window that has not come up yet.
    ///
    /// Reads only `quotaBars`, so a billing cycle nearing its renewal date can
    /// never make an untouched allowance look exhausted.
    public var isQuotaExhausted: Bool {
        quotaBars.contains { $0.primaryFractionOrUnmeasured >= Self.exhaustionThreshold || $0.isBlocked }
    }

    /// Every consumable window is blocked with no percentage at all — a fully
    /// rate-limited / cut-off account (e.g. OpenCode's `rate-limited` signal).
    ///
    /// Distinct from "spent": spent is a *number* we measured hitting ~100%,
    /// whereas here nothing can be used right now and no number exists to back
    /// that. The UI reads this as "blocked" (the vendor's own word), never as
    /// "nearly used up" — an avatar ✗, a spoken "blocked", and a modal
    /// headline all key off it.
    public var isFullyBlockedWithoutReading: Bool {
        let bars = quotaBars
        return !bars.isEmpty && bars.allSatisfy { $0.isBlocked && $0.primaryFraction == nil }
    }

    /// When this vendor's *longest* window turns over.
    ///
    /// The longest window is the one that governs planning — a five-hour
    /// bucket refills before you have finished reading the row, while the
    /// monthly one is the deadline that actually constrains the month. Nil
    /// when the vendor published no window with both a length and a reset.
    ///
    /// Reads `quotaBars`, not `bars`: a hand-entered cycle row is usually the
    /// longest window in the snapshot (a monthly or annual renewal), so
    /// reading `bars` would sort a vendor by its billing-cycle date instead
    /// of by when its actual quota refills — the opposite of what this
    /// property exists to answer.
    public var longestWindowReset: Date? {
        let dated = quotaBars.compactMap { bar -> (TimeInterval, Date)? in
            guard let length = bar.windowLength, let reset = bar.resetsAt else { return nil }
            return (length, reset)
        }
        return dated.max { $0.0 < $1.0 }?.1 ?? resetsAt
    }

    /// The bars that actually measure consumption — everything `bars` holds,
    /// minus the ones that only track elapsed time. Use this for headroom,
    /// exhaustion, urgency, and recommendations; `bars` is for drawing.
    public var quotaBars: [DualBarMetrics] {
        bars.filter { !$0.measuresElapsedTimeOnly }
    }

    /// The bars to draw: `bars` with the shorter windows a spent window has
    /// made redundant removed.
    ///
    /// Once a window is used up, nothing can be started until it resets,
    /// whatever headroom the shorter windows nested inside it still report. A
    /// healthy weekly bar drawn under an exhausted monthly one reads as
    /// "plenty left" at exactly the moment there is nothing to start — the
    /// monthly cap governs the account, so the weekly and five-hour figures
    /// are noise. The spent window itself stays (it is the one carrying the
    /// reset); every consumable window strictly shorter than it is dropped.
    ///
    /// Two kinds of bar are deliberately left alone:
    /// - Windows with no length at all. A bonus-credit pool or an overage
    ///   allowance has no period to be a *shorter period* against, and it can
    ///   outlive the plan window beside it — Kiro's bonus credits expire after
    ///   the monthly reset, not with it — so hiding one would hide real
    ///   headroom.
    /// - Elapsed-time-only cycle rows, which measure the billing cycle rather
    ///   than consumption and are shown for their own reason.
    ///
    /// Only a *measured* window triggers the collapse. A window the vendor
    /// declared blocked but never gave a percentage for is not "spent" here:
    /// blocked already has its own hatched treatment, and a spent window is a
    /// number we received, never one inferred from a declaration.
    ///
    /// `bars` stays the full set because it is data — `QuotaHistoryStore`
    /// persists it and the advice engine ranks it. This property is only for
    /// drawing.
    public var displayBars: [DualBarMetrics] {
        // `quotaBars` drops elapsed-time-only rows: a cycle 100% elapsed is
        // not a window 100% spent, so it must never trigger the collapse.
        let longestSpentWindow = quotaBars
            .filter { $0.primaryFractionOrUnmeasured >= Self.exhaustionThreshold }
            .compactMap(\.windowLength)
            .max()
        guard let longestSpentWindow else { return bars }
        return bars.filter { bar in
            guard !bar.measuresElapsedTimeOnly, let length = bar.windowLength else { return true }
            return length >= longestSpentWindow
        }
    }

    public init(
        id: String,
        vendorId: VendorIdentifier,
        displayName: String,
        category: MetricCategory,
        metric: MetricType,
        status: ProviderStatus,
        resetsAt: Date?,
        lastUpdated: Date,
        auxiliaryInfo: String?,
        row1: DualBarMetrics?,
        row2: DualBarMetrics?,
        badgeText: String? = nil,
        planName: String? = nil,
        latencyMs: Int? = nil,
        keyMasked: String? = nil,
        cliSource: String? = nil,
        currencyBasis: CurrencyBasis? = nil
    ) {
        self.id = id
        self.vendorId = vendorId
        self.displayName = displayName
        self.category = category
        self.metric = metric
        self.status = status
        self.resetsAt = resetsAt
        self.lastUpdated = lastUpdated
        self.auxiliaryInfo = auxiliaryInfo
        self.row1 = row1
        self.row2 = row2
        self.row3 = nil
        self.badgeText = badgeText
        self.planName = planName
        self.latencyMs = latencyMs
        self.keyMasked = keyMasked
        self.cliSource = cliSource
        self.currencyBasis = currencyBasis
    }

    public init(
        id: String,
        vendorId: VendorIdentifier,
        displayName: String,
        category: MetricCategory,
        metric: MetricType,
        status: ProviderStatus,
        resetsAt: Date?,
        lastUpdated: Date,
        auxiliaryInfo: String?,
        row1: DualBarMetrics? = nil,
        row2: DualBarMetrics? = nil,
        row3: DualBarMetrics? = nil,
        badgeText: String? = nil,
        planName: String? = nil,
        latencyMs: Int? = nil,
        keyMasked: String? = nil,
        cliSource: String? = nil,
        currencyBasis: CurrencyBasis? = nil
    ) {
        self.id = id
        self.vendorId = vendorId
        self.displayName = displayName
        self.category = category
        self.metric = metric
        self.status = status
        self.resetsAt = resetsAt
        self.lastUpdated = lastUpdated
        self.auxiliaryInfo = auxiliaryInfo
        self.row1 = row1
        self.row2 = row2
        self.row3 = row3
        self.badgeText = badgeText
        self.planName = planName
        self.latencyMs = latencyMs
        self.keyMasked = keyMasked
        self.cliSource = cliSource
        self.currencyBasis = currencyBasis
    }



    /// Short display name for a compact row header.
    public var shortVendorName: String {
        switch vendorId {
        case .claude:        return "Claude"
        case .openai:        return "OpenAI"
        case .gemini:        return "Gemini"
        case .antigravityClaude, .antigravityArgon: return displayName
        case .opencode:      return "OpenCode"
        case .copilot:       return "GitHub Copilot"
        case .openrouter:    return "OpenRouter"
        case .deepseek:      return "DeepSeek"
        case .grok:          return "Grok"
        case .kiro:          return "Kiro"
        case .devpass:       return "DevPass"
        case .commandcode:   return "Command Code"
        case .clinepass:     return "ClinePass"
        case .muse:          return "Muse"
        case .githubRest, .githubGraphql: return "GitHub"
        }
    }

    /// The title a row or tile shows for this reading.
    ///
    /// A named multi-instance provider (an OpenCode Go workspace) shows its own
    /// name, so two rows under one vendor are tellable apart. Every
    /// single-instance provider keeps `shortVendorName` byte-for-byte: for them
    /// `id == vendorId.rawValue`, which is the test below.
    public var rowTitle: String {
        id == vendorId.rawValue ? shortVendorName : displayName
    }

    /// The instance key when this vendor serves more than one instance, else
    /// `nil`. Event ids fold this in (only when non-nil) so a single-instance
    /// vendor's ids stay byte-identical to what shipped, while two workspaces
    /// of one vendor get distinct ids.
    public var instanceIdOrNil: String? {
        id == vendorId.rawValue ? nil : id
    }

    /// The plan subtitle for a compact row, or "" when we do not know it.
    ///
    /// Deliberately has no per-vendor fallback. The old table asserted a tier
    /// nobody had measured — every Claude user was labelled "Max x20", Pro
    /// subscribers included — which is the same fabrication this app promises
    /// not to commit, just in smaller type. An unknown plan renders as nothing.
    public var shortPlanName: String {
        // Money providers carry no plan; the balance takes the subtitle slot.
        if vendorId == .openrouter || vendorId == .deepseek { return "" }
        guard let plan = planName, !plan.isEmpty else { return "" }
        return plan
    }


    /// 0.0 … 1.0 fraction *consumed* (0 = empty, 1 = full).
    ///
    /// `nil` means "there is no denominator" — a subscription, an unreadable
    /// provider, or a spend figure with no cap. Callers must render nil as an
    /// absence (no bar, no percentage), never as 0 or 100.
    public var consumptionFraction: Double? {
        // No reading means no fraction, whatever the placeholder metric says.
        guard status.confidence == .measured else { return nil }
        switch metric {
        case .percentage(let used, _):
            return min(max(used, 0.0), 1.0)
        case .count(let remaining, let limit, _):
            guard limit > 0 else { return nil }
            return 1.0 - min(max(Double(remaining) / Double(limit), 0.0), 1.0)
        case .currency(let balance, let limit, _, _):
            // An uncapped key has no denominator — spend is knowable, headroom is not.
            guard let limit, limit > 0 else { return nil }
            let ld = NSDecimalNumber(decimal: limit).doubleValue
            let bd = NSDecimalNumber(decimal: balance).doubleValue
            return 1.0 - min(max(bd / ld, 0.0), 1.0)
        case .credits:
            // A count of credits has no cap to be a fraction *of*: the vendor
            // publishes what is left, not what it is out of. Nil, never 0.
            return nil
        case .subscription:
            return nil
        }
    }
}
