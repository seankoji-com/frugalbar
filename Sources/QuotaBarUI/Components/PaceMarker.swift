import Foundation
import QuotaBarCore

/// What a window's pace may and may not claim.
///
/// One definition, read by the tick on the bar, the "even pace" legend, the
/// state colour, the tooltip and the spoken label, so none of them can assert
/// a pace the others would not draw.
extension DualBarMetrics {

    /// Where an even pace would be by now, as a fraction of the track — but
    /// only when the vendor published BOTH the reset time and the window
    /// length it is measured against. `expectedPaceFraction` is a public
    /// field that can be set without either, and a position with nothing
    /// behind it is a fabricated one (AGENTS.md).
    var evenPace: Double? {
        guard let pace = expectedPaceFraction,
              resetsAt != nil,
              let windowLength, windowLength > 0
        else { return nil }
        return min(max(pace, 0), 1)
    }

    /// Used exceeds an even pace by more than `aheadOfPaceMargin`.
    ///
    /// Read from `paceMarker`, not `evenPace`: a pace claim is only made when
    /// the tick that shows it is drawn. A pace of exactly zero (a window that
    /// has just reset) or one (a stale reset) draws no tick, so nothing may
    /// call the window ahead of it either. Never for a blocked window, which
    /// wears the vendor's blocked colour rather than amber and says "blocked"
    /// instead; a spent one has no marker and is red.
    var isMeaningfullyAheadOfPace: Bool {
        guard !isBlocked, let used = primaryFraction, let pace = paceMarker else { return false }
        return used - pace > Self.aheadOfPaceMargin
    }

    /// Where the pace tick is drawn, or nil when none is: no published pace,
    /// a pace at either end of the track (where the edge already says it), a
    /// spent window (full whatever the pace), or a blocked window with no
    /// reading (a dashed placeholder, where a tick would assert a position
    /// against usage nobody measured).
    var paceMarker: Double? {
        guard let pace = evenPace, pace > 0, pace < 1 else { return nil }
        if isBlocked && primaryFraction == nil { return nil }
        if let used = primaryFraction, used >= QuotaSnapshot.exhaustionThreshold { return nil }
        return pace
    }
}
