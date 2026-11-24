import Foundation
import QuotaBarCore

/// One reading of a projected run-out, shared by every line that words one:
/// the inspector's run-out line, the burndown caption and its spoken label.
///
/// It is total over its inputs. Each of those surfaces used to test
/// `out > now` and let everything else fall through to "lasts until the
/// reset" or to silence, so a projection that had already come due between
/// polls reassured instead of warning, and one under thirty seconds away
/// printed "runs out in now". Every case is named here, and a surface words
/// the case it is given; it never re-derives one.
public enum RunOutVerdict: Equatable, Sendable {
    /// The projection reaches zero now or within the countdown's smallest
    /// unit. `resetPublished` says whether a reset exists to name.
    case imminent(resetPublished: Bool)
    /// Runs out at the date, before the published reset.
    case runsOut(Date)
    /// Runs out at the date; the vendor published no reset to compare with.
    case runsOutNoReset(Date)
    /// The window resets before the projection reaches zero.
    case lastsUntilReset
    /// Nothing honest to say: no rate to project, a window already over, or
    /// no reset for a non-exhausting projection to last until.
    case unknown

    /// Below this, `GlancePresentation.countdown` prints "now", so a
    /// projection this close is worded as imminent, never "runs out in now".
    static let imminentInterval: TimeInterval = 30

    /// - Parameters:
    ///   - projectedOut: when the projection reaches zero, or nil when it
    ///     does not before the window resets (or never).
    ///   - hasRate: whether a positive consumption rate exists to project.
    public static func classify(projectedOut: Date?, resetsAt: Date?, hasRate: Bool, now: Date) -> RunOutVerdict {
        if let resetsAt, resetsAt <= now { return .unknown }
        guard hasRate else { return .unknown }
        guard let out = projectedOut else { return resetsAt == nil ? .unknown : .lastsUntilReset }
        if let resetsAt, out >= resetsAt { return .lastsUntilReset }
        if out.timeIntervalSince(now) < imminentInterval { return .imminent(resetPublished: resetsAt != nil) }
        return resetsAt == nil ? .runsOutNoReset(out) : .runsOut(out)
    }

    /// True for every case that says the window runs out before it resets
    /// (or with no reset to save it): the verdicts a healthy headline must
    /// not sit above unchallenged.
    public var warns: Bool {
        switch self {
        case .imminent, .runsOut, .runsOutNoReset: true
        case .lastsUntilReset, .unknown: false
        }
    }

    /// True only when a published reset is known to come after the run-out.
    public var runsOutBeforeReset: Bool {
        switch self {
        case .imminent(let resetPublished): resetPublished
        case .runsOut: true
        case .runsOutNoReset, .lastsUntilReset, .unknown: false
        }
    }

    /// The verdict after `basis` ("At your recent rate"), or nil for `.unknown`.
    public func sentence(basis: String, now: Date) -> String? {
        switch self {
        case .imminent(true): "\(basis), could run out any moment, before the reset"
        case .imminent(false): "\(basis), could run out any moment (no reset published)"
        case .runsOut(let out): "\(basis), runs out in \(GlancePresentation.countdown(out, now: now)), before the reset"
        case .runsOutNoReset(let out): "\(basis), runs out in \(GlancePresentation.countdown(out, now: now)) (no reset published)"
        case .lastsUntilReset: "\(basis), lasts until the reset"
        case .unknown: nil
        }
    }

    /// Compact caption clause ("at recent rate, out in 3h"), or nil when the
    /// verdict has nothing to add to a caption that already shows the reset.
    public func captionClause(now: Date) -> String? {
        switch self {
        case .imminent: "at recent rate, could run out any moment"
        case .runsOut(let out), .runsOutNoReset(let out):
            "at recent rate, out in \(GlancePresentation.countdown(out, now: now))"
        case .lastsUntilReset, .unknown: nil
        }
    }

    /// Spoken clause for a chart's accessibility description.
    public func spokenClause(now: Date) -> String? {
        switch self {
        case .imminent: "at recent pace could run out any moment"
        case .runsOut(let out), .runsOutNoReset(let out):
            "at recent pace runs out in \(GlancePresentation.countdownSpoken(out, now: now))"
        case .lastsUntilReset: "at recent pace resets before running out"
        case .unknown: nil
        }
    }
}

extension BurndownPresentation.Burndown {
    /// This chart's projection, classified once for every line that words it.
    public func runOutVerdict(now: Date) -> RunOutVerdict {
        RunOutVerdict.classify(projectedOut: projectedExhaustion, resetsAt: resetsAt,
                               hasRate: projection != nil, now: now)
    }
}

/// The detail view's one run-out line (owner decision, 23 Nov 2026).
///
/// The inspector used to print two projections for the same window: the
/// window line's average-so-far ("runs out in 18h 6m") and the chart's recent
/// pace ("out in 32h 31m"), neither saying which it was. Now there is one,
/// and it always names its basis: recent pace from recorded history when
/// `BurnRateForecast` found one, else the window's average pace so far.
/// Never for a blocked or spent window. The wording is `RunOutVerdict`'s.
enum InspectorRunOut {

    struct Result: Equatable, Sendable {
        let text: String
        let verdict: RunOutVerdict
        var runsOutBeforeReset: Bool { verdict.runsOutBeforeReset }
        var warns: Bool { verdict.warns }
    }

    /// The entry point every surface uses: no forecast for a carried-over
    /// reading (its figures are not now) or for an account the vendor blocked
    /// (it cannot be used at any rate, whatever its windows read).
    static func compute(for bar: DualBarMetrics, in snapshot: QuotaSnapshot,
                        readings: [QuotaHistoryStore.ReadingRecord]?, now: Date) -> Result? {
        guard snapshot.staleReading == nil, !snapshot.isAccountBlocked else { return nil }
        return compute(for: bar, snapshotID: snapshot.id, readings: readings, now: now)
    }

    static func compute(for bar: DualBarMetrics, snapshotID: String,
                        readings: [QuotaHistoryStore.ReadingRecord]?, now: Date) -> Result? {
        guard !bar.isBlocked, !bar.measuresElapsedTimeOnly,
              let used = bar.primaryFraction, used < QuotaSnapshot.exhaustionThreshold
        else { return nil }

        // Recent pace from recorded history, but only when its recorded reset
        // is the live bar's reset: a vendor that revised the reset since the
        // last poll would otherwise get a verdict that contradicts the summary.
        if let readings,
           let burndown = BurndownPresentation.burndown(readings: readings, instanceID: snapshotID,
                                                       barLabel: bar.label, now: now),
           Self.resetsAgree(bar.resetsAt, burndown.resetsAt) {
            let verdict = burndown.runOutVerdict(now: now)
            if let text = verdict.sentence(basis: "At your recent rate", now: now) {
                return Result(text: text, verdict: verdict)
            }
        }

        // The window's own average, from its published reset and length (the
        // pace tick's figures), labelled as that. Below pace it has no
        // projected run-out, which is a rate that lasts until the reset.
        guard bar.paceMarker != nil else { return nil }
        let verdict = RunOutVerdict.classify(projectedOut: bar.projectedExhaustionDate, resetsAt: bar.resetsAt,
                                             hasRate: true, now: now)
        return verdict.sentence(basis: "At this window's average rate", now: now)
            .map { Result(text: $0, verdict: verdict) }
    }

    /// Both unpublished, or both published within a minute of each other.
    static func resetsAgree(_ live: Date?, _ recorded: Date?) -> Bool {
        switch (live, recorded) {
        case (nil, nil): true
        case let (live?, recorded?): abs(live.timeIntervalSince(recorded)) <= 60
        default: false
        }
    }

    static func text(for bar: DualBarMetrics, snapshotID: String,
                     readings: [QuotaHistoryStore.ReadingRecord]?, now: Date) -> String? {
        compute(for: bar, snapshotID: snapshotID, readings: readings, now: now)?.text
    }
}
