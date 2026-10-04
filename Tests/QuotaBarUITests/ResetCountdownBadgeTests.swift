import Testing
import Foundation
@testable import QuotaBarUI

/// All cases pass an explicit `now` so nothing races the wall clock.
/// The previous suite built dates from `Date()` and truncated, which made
/// `description_minutes` fail roughly one run in four.
@Suite("ResetCountdownBadge")
struct ResetCountdownBadgeTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func inSeconds(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }

    @Test("nil renders as an em dash")
    func nilDate() {
        #expect(ResetCountdownBadge.format(nil, now: now) == "—")
        #expect(ResetCountdownBadge.description(nil, now: now) == "—")
    }

    @Test("a past date reads as Now")
    func past() {
        #expect(ResetCountdownBadge.format(inSeconds(-60), now: now) == "Now")
        #expect(ResetCountdownBadge.description(inSeconds(-1), now: now) == "Resets now")
    }

    @Test("seconds")
    func seconds() {
        #expect(ResetCountdownBadge.format(inSeconds(30), now: now) == "30s")
    }

    /// The regression that made the old suite flaky: 179.97s must round to 3m,
    /// not truncate to 2m.
    @Test("just under three minutes rounds to 3m, it does not truncate to 2m")
    func roundsRatherThanTruncates() {
        #expect(ResetCountdownBadge.format(inSeconds(179.97), now: now) == "3m")
        #expect(ResetCountdownBadge.description(inSeconds(179.97), now: now) == "Resets in 3 minutes")
    }

    @Test("exact minutes")
    func minutes() {
        #expect(ResetCountdownBadge.format(inSeconds(180), now: now) == "3m")
        #expect(ResetCountdownBadge.format(inSeconds(600), now: now) == "10m")
    }

    @Test("one minute is singular")
    func singularMinute() {
        #expect(ResetCountdownBadge.description(inSeconds(60), now: now) == "Resets in 1 minute")
    }

    /// Rounding must never produce "60m" — that belongs in the hours branch.
    /// The old suite accepted "60m" as a valid answer to paper over a flake.
    @Test("59m30s does not round up into a bogus 60m")
    func neverReportsSixtyMinutes() {
        let out = ResetCountdownBadge.format(inSeconds(3570), now: now)
        #expect(out == "59m")
        #expect(out != "60m")
    }

    @Test("hours and minutes")
    func hoursMinutes() {
        #expect(ResetCountdownBadge.format(inSeconds(3600), now: now) == "1h 0m")
        #expect(ResetCountdownBadge.format(inSeconds(3660), now: now) == "1h 1m")
        #expect(ResetCountdownBadge.format(inSeconds(3 * 3600 + 300), now: now) == "3h 5m")
    }

    @Test("beyond a day falls back to an absolute date")
    func absolute() {
        let out = ResetCountdownBadge.format(inSeconds(3 * 86400), now: now)
        #expect(out != "—")
        #expect(!out.hasSuffix("m"))
        #expect(!out.hasSuffix("s"))
    }

    @Test("sub-second positive duration reports 1s, never 0s")
    func subSecondPositive() {
        #expect(ResetCountdownBadge.format(inSeconds(0.2), now: now) == "1s")
        #expect(ResetCountdownBadge.description(inSeconds(0.2), now: now) == "Resets in 1 second")
    }

    @Test("59.6s rolls into minutes branch rather than producing 60s")
    func fiftyNinePointSixSeconds() {
        #expect(ResetCountdownBadge.format(inSeconds(59.6), now: now) == "1m")
        #expect(ResetCountdownBadge.description(inSeconds(59.6), now: now) == "Resets in 1 minute")
    }

    @Test("boundary just before a day rolls into absolute date")
    func justUnderOneDay() {
        let out = ResetCountdownBadge.format(inSeconds(86399.6), now: now)
        #expect(!out.contains("24h"))
    }
}

@Suite("ResetCountdownBadge.compact")
struct ResetCountdownBadgeCompactTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func c(_ seconds: TimeInterval) -> String? {
        ResetCountdownBadge.compact(now.addingTimeInterval(seconds), now: now)
    }

    @Test("minutes, hours and days, one unit, rounded")
    func units() {
        #expect(c(45 * 60) == "45m")
        #expect(c(3 * 3600 + 10 * 60) == "3h")
        #expect(c(5.6 * 3600) == "6h")
        #expect(c(6.2 * 86_400) == "6d")
        #expect(c(1.0 * 86_400) == "1d")
    }

    @Test("under a minute reads 1m, never 0m; a passed reset reads now; none reads nothing")
    func edges() {
        #expect(c(10) == "1m")
        #expect(c(-5) == "now")
        #expect(ResetCountdownBadge.compact(nil, now: now) == nil)
    }

    /// 59.6 minutes rounds to 60: that belongs in the hours branch, not "60m".
    @Test("the minute and hour boundaries never print 60m or 24h")
    func boundaries() {
        #expect(c(59.6 * 60) == "1h")
        #expect(c(23.6 * 3600) == "1d")
    }
}
