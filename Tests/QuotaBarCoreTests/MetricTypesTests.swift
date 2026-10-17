import Testing
import Foundation
@testable import QuotaBarCore

@Suite("consumptionFraction")
struct ConsumptionFractionTests {

    private func snapshot(_ metric: MetricType, status: ProviderStatus = .healthy) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "t", vendorId: .githubRest, displayName: "t",
            category: .developerLimits, metric: metric, status: status,
            resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil
        )
    }

    @Test("percentage passes through and clamps to 0...1")
    func percentage() {
        #expect(snapshot(.percentage(usedFraction: 0.25, displayDetails: nil)).consumptionFraction == 0.25)
        #expect(snapshot(.percentage(usedFraction: -1, displayDetails: nil)).consumptionFraction == 0.0)
        #expect(snapshot(.percentage(usedFraction: 5, displayDetails: nil)).consumptionFraction == 1.0)
    }

    @Test("count inverts remaining/limit into a consumed fraction")
    func count() {
        #expect(snapshot(.count(remaining: 25, limit: 100, unitName: "u")).consumptionFraction == 0.75)
        #expect(snapshot(.count(remaining: 100, limit: 100, unitName: "u")).consumptionFraction == 0.0)
    }

    @Test("count with a zero limit has no denominator, so no fraction — not a fake 0%")
    func countZeroLimit() {
        #expect(snapshot(.count(remaining: 0, limit: 0, unitName: "u")).consumptionFraction == nil)
    }

    @Test("currency inverts balance against limit (allow floating point)")
    func currency() throws {
        let m = MetricType.currency(balance: 5, limit: 20, spent: 15, currencyCode: "USD")
        let frac = try #require(snapshot(m).consumptionFraction)
        #expect(abs(frac - 0.75) < 0.001)
    }

    @Test("currency without a limit reports no consumption fraction, not zero")
    func currencyNoLimit() {
        let m = MetricType.currency(balance: 5, limit: nil, spent: nil, currencyCode: "USD")
        #expect(snapshot(m).consumptionFraction == nil)
    }

    @Test("currency with a zero limit reports no consumption fraction, not a divide-by-zero")
    func currencyZeroLimit() {
        let m = MetricType.currency(balance: 5, limit: 0, spent: 5, currencyCode: "USD")
        #expect(snapshot(m).consumptionFraction == nil)
    }

    @Test("subscription has no consumption dimension (nil)")
    func subscription() {
        #expect(snapshot(.subscription(tierName: "Pro", renewalDate: nil)).consumptionFraction == nil)
    }

    @Test("an unmeasured status yields nil regardless of the underlying metric")
    func unmeasuredStatusYieldsNil() {
        let m = MetricType.percentage(usedFraction: 0.9, displayDetails: nil)
        #expect(snapshot(m, status: .unavailable(.notConfigured)).consumptionFraction == nil)
        // A 429 is an absent reading, not a 90%-consumed quota. Rendering the
        // placeholder metric here is exactly the fabrication this model exists
        // to prevent.
        #expect(snapshot(m, status: .rateLimited(retryAfter: nil)).consumptionFraction == nil)
    }
}

@Suite("ProviderStatus")
struct ProviderStatusTests {

    @Test("urgency ordering")
    func urgencyOrdering() {
        #expect(Urgency.none < .warning)
        #expect(Urgency.warning < .critical)
    }

    @Test("measured urgency passes through")
    func measuredUrgency() {
        #expect(ProviderStatus.measured(.warning).urgency == .warning)
        #expect(ProviderStatus.healthy.urgency == .none)
        #expect(ProviderStatus.warning.urgency == .warning)
        #expect(ProviderStatus.critical.urgency == .critical)
    }

    @Test("unavailable never carries urgency, however severe the underlying reason")
    func unavailableHasNoUrgency() {
        #expect(ProviderStatus.unavailable(.credentialRejected).urgency == .none)
        #expect(ProviderStatus.unauthenticated.urgency == .none)
        #expect(ProviderStatus.unsupported("x").urgency == .none)
    }

    @Test("rateLimited carries no urgency — a 429 is an absent reading, not an emergency")
    func rateLimitedIsNotUrgent() {
        // A 429 on a metadata endpoint says nothing about the user's quota.
        // Treating it as critical turned the whole menu bar red on zero data.
        #expect(ProviderStatus.rateLimited(retryAfter: nil).urgency == .none)
        #expect(ProviderStatus.rateLimited(retryAfter: nil).confidence == .unavailable)
    }

    @Test("confidence: only a parsed reading counts as measured")
    func confidence() {
        #expect(ProviderStatus.healthy.confidence == .measured)
        #expect(ProviderStatus.warning.confidence == .measured)
        #expect(ProviderStatus.critical.confidence == .measured)
        #expect(ProviderStatus.rateLimited(retryAfter: nil).confidence == .unavailable)
        #expect(ProviderStatus.unauthenticated.confidence == .unavailable)
        #expect(ProviderStatus.unsupported("x").confidence == .unavailable)
    }

    @Test("unavailableReason surfaces only on .unavailable")
    func unavailableReasonAccessor() {
        #expect(ProviderStatus.unauthenticated.unavailableReason == .notConfigured)
        #expect(ProviderStatus.healthy.unavailableReason == nil)
        let retry = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ProviderStatus.rateLimited(retryAfter: retry).unavailableReason
                == .rateLimited(retryAfter: retry))
    }

    @Test("unsupported equality is by reason string")
    func unsupportedEquality() {
        #expect(ProviderStatus.unsupported("a") == ProviderStatus.unsupported("a"))
        #expect(ProviderStatus.unsupported("a") != ProviderStatus.unsupported("b"))
    }

    /// A 429 that carries `Retry-After` is the one unavailable state that can
    /// say *when*, instead of "will retry" with nothing behind it. A window
    /// already in the past is no promise about the next poll, so it falls back
    /// to the unquantified wording.
    @Test("a rateLimited remedy names the vendor's window only when there is one")
    func rateLimitedRemedyNamesTheWindow() {
        #expect(UnavailableReason.rateLimited(retryAfter: nil).remedy
                == "Vendor throttling — will retry")
        #expect(UnavailableReason.rateLimited(retryAfter: Date().addingTimeInterval(600)).remedy
                == "Vendor throttling — retry in 10 min")
        #expect(UnavailableReason.rateLimited(retryAfter: Date().addingTimeInterval(-60)).remedy
                == "Vendor throttling — will retry")
        // A window that is real but tiny still reads as a whole minute rather
        // than "retry in 0 min".
        #expect(UnavailableReason.rateLimited(retryAfter: Date().addingTimeInterval(5)).remedy
                == "Vendor throttling — retry in 1 min")
    }

    @Test("retryAfterDate honours delta-seconds and ignores everything else")
    func retryAfterDateParsing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: "2377", now: now)
                == now.addingTimeInterval(2377))
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: " 30 ", now: now)
                == now.addingTimeInterval(30))
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: nil, now: now) == nil)
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: "", now: now) == nil)
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: "0", now: now) == nil)
        // An HTTP-date is deliberately not parsed: a clock skew turns it into
        // an instant in the past or the far future, and this value only ever
        // gates a retry.
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: "Wed, 21 Oct 2026 07:28:00 GMT", now: now) == nil)
    }

    /// `TimeInterval(_:)` reads all of these as numbers. "inf" became an
    /// instant that never arrives, so the automatic poll stopped for good, and
    /// the row's remedy trapped converting an infinite wait to whole minutes.
    @Test("Retry-After accepts only delay-seconds digits, never inf, exponents or signs")
    func retryAfterDateRejectsNonDelaySeconds() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for raw in ["inf", "infinity", "nan", "1e999", "1e3", "0x1p70", "-5", "+30", "2.5", "30s", "٣٠"] {
            #expect(QuotaHTTP.retryAfterDate(secondsHeader: raw, now: now) == nil, "\(raw)")
        }
    }

    /// A 21-digit delay is finite but past `Int.max` minutes, which trapped the
    /// remedy just as "inf" did, and it parked the automatic poll for longer
    /// than the Mac will run. A long wait is still a wait: it is honoured up to
    /// the cap rather than dropped.
    @Test("a Retry-After longer than a day holds the automatic poll for a day, not forever")
    func retryAfterDateClampsToADay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cap = now.addingTimeInterval(QuotaHTTP.maximumRetryAfter)
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: "86400", now: now) == cap)
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: "86401", now: now) == cap)
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: "999999999999999999999", now: now) == cap)
        #expect(QuotaHTTP.retryAfterDate(secondsHeader: String(repeating: "9", count: 400), now: now) == cap)
    }

    /// End to end through the generic 429 mapping: the remedy the row prints
    /// for the headers that used to crash it.
    @Test("a 429 with an absurd Retry-After still renders a remedy")
    func absurdRetryAfterRendersARemedy() {
        // The remedy measures from the wall clock, so `now` must be the real one.
        let now = Date()
        for raw in ["inf", "1e999"] {
            #expect(QuotaHTTP.failureReason(for: 429, retryAfter: raw, now: now)?.remedy
                    == "Vendor throttling — will retry")
        }
        #expect(QuotaHTTP.failureReason(for: 429, retryAfter: "999999999999999999999", now: now)?.remedy
                == "Vendor throttling — retry in 1440 min")
    }
}

@Suite("Dual-bar never-coerced invariant")
struct DualBarNeverCoercedTests {

    /// A measured snapshot whose single quota bar is described by `bar` (or
    /// absent). The candidate division/`category` are irrelevant here —
    /// `isQuotaExhausted` reads only `quotaBars`.
    private func snapshot(_ bar: DualBarMetrics?) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "t", vendorId: .githubRest, displayName: "t",
            category: .developerLimits,
            metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .healthy, resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
            row1: bar
        )
    }

    /// The whole invariant hangs on these two named helpers as the single
    /// choke-point. Any future consumer that reaches for its own `?? 0`
    /// (threshold) or `?? 0` (ranking) instead of these re-opens I27. Pinning
    /// the exact values also pins that the helpers exist and stay wired.
    ///
    /// Note this is the *bar-level* `DualBarMetrics.primaryFraction` sentinel —
    /// a purely internal threshold/ranking convenience, never a rendered
    /// denominator. It is distinct from `QuotaSnapshot.consumptionFraction`,
    /// which nil means "no denominator" and which AGENTS.md forbids coercing to
    /// 0 or 1 for display.
    @Test("a nil fraction reads as 'not reached', not coerced to spent")
    func nilFractionNotCoercedUp() {
        let bar = DualBarMetrics(primaryFraction: nil, label: "5H")
        #expect(bar.primaryFractionOrUnmeasured == 0)
    }

    @Test("a nil fraction sinks below every real reading for worst-bar ranking")
    func nilFractionSinksToBottomForRanking() {
        let nilBar = DualBarMetrics(primaryFraction: nil, label: "5H")
        let emptyBar = DualBarMetrics(primaryFraction: 0.0, label: "5H")
        // -1 sits strictly below a genuine zero: a bar with no reading must
        // never outrank one that actually reports a number.
        #expect(nilBar.primaryFractionForWorstBarRanking == -1)
        #expect(emptyBar.primaryFractionForWorstBarRanking == 0.0)
        #expect(nilBar.primaryFractionForWorstBarRanking < emptyBar.primaryFractionForWorstBarRanking)
    }

    /// I27's core regression: a window the vendor reported with *no percentage*
    /// must not read as "100% spent". Coercing the nil fraction to 1 here would
    /// paint a full red bar and strike through the logo on zero data.
    @Test("a nil-fraction, non-blocked bar does not read as exhausted")
    func nilFractionNotExhausted() {
        let snap = snapshot(DualBarMetrics(primaryFraction: nil, label: "5H", isBlocked: false))
        #expect(snap.isQuotaExhausted == false)
    }

    @Test("a blocked bar with no fraction reads as exhausted — blocked is unusable")
    func blockedCountsAsExhausted() {
        let snap = snapshot(DualBarMetrics(primaryFraction: nil, label: "5H", isBlocked: true))
        #expect(snap.isQuotaExhausted == true)
    }

    @Test("isFullyBlockedWithoutReading is true only when every window is blocked with no reading")
    func fullyBlockedPredicate() {
        func two(_ a: DualBarMetrics?, _ b: DualBarMetrics?) -> QuotaSnapshot {
            QuotaSnapshot(
                id: "t", vendorId: .githubRest, displayName: "t",
                category: .developerLimits,
                metric: .subscription(tierName: "Pro", renewalDate: nil),
                status: .healthy, resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
                row1: a, row2: b
            )
        }

        // All windows blocked, no percentages: a fully rate-limited account.
        let blocked = two(
            DualBarMetrics(primaryFraction: nil, label: "5H", isBlocked: true),
            DualBarMetrics(primaryFraction: nil, label: "MO", isBlocked: true)
        )
        #expect(blocked.isFullyBlockedWithoutReading)

        // One healthy measured window alongside a blocked one is not *fully*
        // blocked (some usage is still possible / known).
        let partial = two(
            DualBarMetrics(primaryFraction: 0.5, label: "MO"),
            DualBarMetrics(primaryFraction: nil, label: "5H", isBlocked: true)
        )
        #expect(partial.isFullyBlockedWithoutReading == false)

        // No windows at all is not "fully blocked" — it is an absence.
        #expect(snapshot(nil).isFullyBlockedWithoutReading == false)
    }
}

@Suite("VendorIdentifier")
struct VendorIdentifierTests {

    @Test("15 known vendors")
    func allCases() {
        #expect(VendorIdentifier.allCases.count == 15)
    }

    @Test("all display names are non-empty")
    func displayNames() {
        for v in VendorIdentifier.allCases {
            #expect(!v.displayName.isEmpty)
        }
    }
}

@Suite("Pro-rata pace marker")
struct ProRataPaceTests {

    /// The bug this replaced: the marker was a constant chosen by label, so a
    /// weekly bar six days into its window drew its target at 45% of the track
    /// and reported the user as comfortably ahead of pace.
    @Test("pace is the share of the window elapsed, not a constant")
    func paceTracksTheWindow() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Six days into a seven-day window: one day left.
        let reset = now.addingTimeInterval(24 * 3600)
        let pace = try #require(DualBarMetrics.proRataPace(
            resetsAt: reset, windowLength: QuotaWindow.week, now: now))
        #expect(abs(pace - 6.0 / 7.0) < 0.0001)
    }

    @Test("a window just opened is at zero pace, one about to reset at full")
    func paceEndpoints() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DualBarMetrics.proRataPace(
            resetsAt: now.addingTimeInterval(QuotaWindow.fiveHours),
            windowLength: QuotaWindow.fiveHours, now: now) == 0)
        #expect(DualBarMetrics.proRataPace(
            resetsAt: now, windowLength: QuotaWindow.fiveHours, now: now) == 1)
    }

    /// Clamped rather than extrapolated: a reset time we fetched a while ago
    /// must not produce a marker past the end of the track.
    @Test("a stale or overshot reset time clamps instead of running off the bar")
    func paceClamps() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DualBarMetrics.proRataPace(
            resetsAt: now.addingTimeInterval(-3600),
            windowLength: QuotaWindow.fiveHours, now: now) == 1)
        #expect(DualBarMetrics.proRataPace(
            resetsAt: now.addingTimeInterval(QuotaWindow.week),
            windowLength: QuotaWindow.fiveHours, now: now) == 0)
    }

    /// No reset time and no window length means no target. The UI draws no
    /// marker rather than inventing one.
    @Test("an unknown window yields no pace at all")
    func paceIsAbsentWithoutInputs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DualBarMetrics.proRataPace(resetsAt: nil, windowLength: QuotaWindow.week, now: now) == nil)
        #expect(DualBarMetrics.proRataPace(resetsAt: now, windowLength: 0, now: now) == nil)
    }

    @Test("burndown delta is absent when there is no pace to compare against")
    func burndownRequiresAPace() {
        let bare = DualBarMetrics(primaryFraction: 0.9, label: "WK")
        #expect(bare.burndownDelta == nil)
        #expect(bare.isAboveProrataPace == false)

        let paced = DualBarMetrics(primaryFraction: 0.9, expectedPaceFraction: 0.5, label: "WK")
        #expect(paced.burndownDelta == 0.4)
        #expect(paced.isAboveProrataPace)
    }

    /// Months are 28–31 days, so a 30-day constant drifts the marker by up to
    /// a day at the point it matters most — the end of the window.
    @Test("a monthly window takes its length from the calendar, not a constant")
    func monthLengthComesFromTheCalendar() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 1
        let march1 = try #require(Calendar.current.date(from: components))
        let length = try #require(DualBarMetrics.monthWindowLength(endingAt: march1))
        // February 2026 has 28 days.
        #expect(abs(length - 28 * 24 * 3600) < 3600)
    }
}
