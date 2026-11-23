import Foundation
import QuotaBarCore

/// The detail view's one run-out line (owner decision, 23 Nov 2026).
///
/// The inspector used to print two projections for the same window: the
/// window line's average-so-far ("runs out in 18h 6m") and the chart's recent
/// pace ("out in 32h 31m"), neither saying which it was. Now there is one,
/// and it always names its basis: recent pace from recorded history when
/// `BurnRateForecast` found one, else the window's average pace so far.
/// Never for a blocked or spent window, and never without a published reset
/// and window length behind it.
enum InspectorRunOut {

    static func text(for bar: DualBarMetrics, snapshotID: String,
                     readings: [QuotaHistoryStore.ReadingRecord]?, now: Date) -> String? {
        guard !bar.isBlocked, !bar.measuresElapsedTimeOnly,
              let used = bar.primaryFraction, used < QuotaSnapshot.exhaustionThreshold
        else { return nil }

        if let readings,
           let burndown = BurndownPresentation.burndown(readings: readings, instanceID: snapshotID,
                                                       barLabel: bar.label, now: now),
           burndown.projection != nil {
            if let out = burndown.projectedExhaustion, out > now {
                return "At your recent rate, runs out in \(GlancePresentation.countdown(out, now: now))"
                    + ", before the reset"
            }
            return "At your recent rate, lasts until the reset"
        }

        // No usable history: the window's own average, from its published
        // reset and length (the pace tick's figures), labelled as that.
        guard bar.paceMarker != nil else { return nil }
        if let out = bar.projectedExhaustionDate, out > now {
            return "At this window's average rate, runs out in \(GlancePresentation.countdown(out, now: now))"
                + ", before the reset"
        }
        return "At this window's average rate, lasts until the reset"
    }
}
