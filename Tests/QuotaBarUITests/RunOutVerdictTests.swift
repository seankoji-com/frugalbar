import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

/// The run-out verdict is a total function: every combination of reset,
/// rate and projected run-out is classified once, and every surface words
/// the case it is given. Four review rounds each found one more combination
/// that fell through `out > now` to "lasts until the reset"; this table
/// covers all of them at once instead of the one each round named.
@Suite("Run-out verdict truth table")
struct RunOutVerdictTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    enum ResetCase: CaseIterable { case unpublished, passed, ahead }
    enum OutCase: CaseIterable { case none, past, withinSeconds, beforeReset, atReset, afterReset }

    func reset(_ c: ResetCase) -> Date? {
        switch c {
        case .unpublished: nil
        case .passed: now.addingTimeInterval(-60)
        case .ahead: now.addingTimeInterval(4 * 3600)
        }
    }

    func out(_ c: OutCase) -> Date? {
        switch c {
        case .none: nil
        case .past: now.addingTimeInterval(-15 * 60)
        case .withinSeconds: now.addingTimeInterval(20)
        case .beforeReset: now.addingTimeInterval(90 * 60)
        case .atReset: now.addingTimeInterval(4 * 3600)
        case .afterReset: now.addingTimeInterval(9 * 3600)
        }
    }

    @Test("every reset × rate × run-out combination is classified and worded honestly")
    func truthTable() {
        var checked = 0
        for r in ResetCase.allCases {
            for hasRate in [false, true] {
                for o in OutCase.allCases {
                    let resetsAt = reset(r)
                    let projected = out(o)
                    let verdict = RunOutVerdict.classify(projectedOut: projected, resetsAt: resetsAt,
                                                         hasRate: hasRate, now: now)
                    let label = "\(r) rate=\(hasRate) out=\(o) → \(verdict)"
                    checked += 1

                    // A window that is over, or no rate, says nothing.
                    if r == .passed || !hasRate {
                        #expect(verdict == .unknown, "\(label)")
                        continue
                    }
                    // The projection reaches zero before any reset that could save it.
                    let runsOut: Bool = {
                        guard let projected else { return false }
                        guard let resetsAt else { return true }
                        return projected < resetsAt
                    }()
                    #expect(verdict.warns == runsOut, "\(label)")
                    // Never reassure about a run-out that is due.
                    if runsOut { #expect(verdict != .lastsUntilReset, "\(label)") }
                    // "Before the reset" only with a reset to be before.
                    #expect(verdict.runsOutBeforeReset == (runsOut && resetsAt != nil), "\(label)")
                    // A projection already due, or under a minute away, is imminent.
                    if runsOut, let projected, projected.timeIntervalSince(now) < 30 {
                        #expect(verdict == .imminent(resetPublished: resetsAt != nil), "\(label)")
                    }

                    let sentence = verdict.sentence(basis: "At your recent rate", now: now)
                    if verdict == .unknown {
                        #expect(sentence == nil, "\(label)")
                    } else {
                        let text = sentence ?? ""
                        #expect(!text.contains("in now"), "\(label): \(text)")
                        #expect(text.contains("before the reset") == verdict.runsOutBeforeReset, "\(label): \(text)")
                        #expect(text.contains("no reset published") == (runsOut && resetsAt == nil), "\(label): \(text)")
                        #expect(text.contains("lasts until the reset") == (verdict == .lastsUntilReset), "\(label): \(text)")
                    }
                    // Caption and spoken clauses agree with the verdict's direction.
                    if runsOut {
                        #expect(verdict.captionClause(now: now) != nil, "\(label)")
                        #expect(verdict.spokenClause(now: now)?.contains("resets before running out") == false, "\(label)")
                    }
                }
            }
        }
        #expect(checked == ResetCase.allCases.count * 2 * OutCase.allCases.count)
    }

    // MARK: Through the inspector

    let length: TimeInterval = 5 * 3600
    var windowReset: Date { now.addingTimeInterval(2 * 3600) }

    func bar(_ used: Double) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: used,
                       expectedPaceFraction: DualBarMetrics.proRataPace(resetsAt: windowReset, windowLength: length, now: now),
                       label: "5H", resetsAt: windowReset, windowLength: length)
    }

    /// A steep burn whose last poll was 40 minutes ago: 0.30 → 0.90 over 30
    /// minutes, so the recent rate reached 100% before `now`, between polls.
    var overdue: [QuotaHistoryStore.ReadingRecord] {
        (0..<4).map { i in
            QuotaHistoryStore.ReadingRecord(vendor: "claude", barLabel: "5H",
                measuredAt: now.addingTimeInterval(-Double(70 - i * 10) * 60), fraction: 0.30 + Double(i) * 0.20,
                isBlocked: false, confidence: .measured, urgency: .none, resetsAt: windowReset, windowLength: length,
                elapsedOnly: false)
        }
    }

    @Test("a recent-rate run-out that came due between polls warns, never 'lasts until the reset' (sol E2R1)")
    func overdueProjectionWarns() throws {
        let burndown = try #require(BurndownPresentation.burndown(readings: overdue, instanceID: "claude",
                                                                 barLabel: "5H", now: now))
        let projected = try #require(burndown.projectedExhaustion)
        #expect(projected <= now)

        let result = try #require(InspectorRunOut.compute(for: bar(0.9), snapshotID: "claude",
                                                          readings: overdue, now: now))
        #expect(result.text == "At your recent rate, could run out any moment, before the reset")
        #expect(result.warns && result.runsOutBeforeReset)

        let caption = BurndownPresentation.summaryLine(for: burndown, now: now)
        #expect(caption.contains("could run out any moment"))
        let spoken = BurndownPresentation.accessibilityDescription(for: burndown, now: now)
        #expect(spoken.contains("could run out any moment"))
        #expect(!spoken.contains("resets before running out"))
    }

    @Test("an account the vendor blocked gets no forecast, whatever its windows read")
    func accountBlockedHasNoForecast() {
        var snapshot = GlanceFixtures.snapshot("commandcode", .commandcode, "Command Code", [bar(0.4)],
                                               badge: QuotaSnapshot.accountBlockedBadge)
        #expect(InspectorRunOut.compute(for: bar(0.4), in: snapshot, readings: nil, now: now) == nil)
        snapshot.badgeText = "60% left"
        #expect(InspectorRunOut.compute(for: bar(0.4), in: snapshot, readings: nil, now: now) != nil)
    }
}
