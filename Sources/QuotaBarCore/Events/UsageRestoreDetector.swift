import Foundation

/// One quota window whose consumed fraction fell well before the vendor's own
/// reset time — an unscheduled allowance restore.
///
/// Carries exactly the figures that were measured: the fraction on each side
/// of the drop and the reset time that had not yet passed. It never claims to
/// know *why* the vendor restored the allowance.
public struct UsageRestoredEvent: Sendable, Equatable {
    public let vendorId: VendorIdentifier
    public let displayName: String
    /// The window that was restored, e.g. "5H" or "WK".
    public let barLabel: String
    public let previousFraction: Double
    public let currentFraction: Double
    /// The vendor's published reset time for the window, as of the current
    /// poll.
    public let resetsAt: Date
    /// True when the vendor also moved the reset time forward into a new
    /// window while the old one still had time left — how a vendor-wide
    /// "we've reset everyone's limits" looks when it restarts the clock as
    /// well as the counter. False when only the counter fell.
    public let windowRestarted: Bool

    public init(
        vendorId: VendorIdentifier,
        displayName: String,
        barLabel: String,
        previousFraction: Double,
        currentFraction: Double,
        resetsAt: Date,
        windowRestarted: Bool = false
    ) {
        self.vendorId = vendorId
        self.displayName = displayName
        self.barLabel = barLabel
        self.previousFraction = previousFraction
        self.currentFraction = currentFraction
        self.resetsAt = resetsAt
        self.windowRestarted = windowRestarted
    }
}

/// Detects usage that fell substantially *before* the vendor's published reset.
///
/// The counterpart of `QuotaResetDetector`, and deliberately disjoint from it.
/// A scheduled rollover also drops the consumed fraction, so a drop alone
/// proves nothing; what tells the two apart is the vendor's own reset time. A
/// restore is a drop while the previous poll's reset time is still in the
/// future. `QuotaResetDetector` fires only once that reset time has *passed*,
/// so the two can never describe the same poll: a drop after the clock ran
/// out is a rollover, a drop before it is a restore. Whether the vendor also
/// moved the reset time forward is recorded (`windowRestarted`) rather than
/// used to stay silent — a vendor-wide "we've reset everyone's limits" can
/// restart the clock too, and that is still an allowance nobody's window had
/// earned yet.
///
/// Both polls must be `.measured` and both fractions present. A reading lost
/// to a 401 or a timeout is not a drop to zero: treating `nil` as 0 would turn
/// every outage into a "usage restored" banner.
public enum UsageRestoreDetector {

    /// How far the consumed fraction must fall to count. The same threshold
    /// `HistoryPresentation.segments` uses to call a negative jump a reset, so
    /// the history chart and the event log agree about what a drop is. Smaller
    /// movements are vendors revising their own figures.
    public static let minimumDrop: Double = 0.15

    /// Absorbs binary-float noise in `previous - current`: some pairs that
    /// differ by exactly 0.15 subtract to a hair under it, so without this a
    /// drop of exactly the threshold would count for some readings and not
    /// for others.
    private static let tolerance: Double = 1e-9

    public static func detect(
        previous: [VendorIdentifier: QuotaSnapshot],
        current: [VendorIdentifier: QuotaSnapshot],
        now: Date
    ) -> [UsageRestoredEvent] {
        var events: [UsageRestoredEvent] = []
        for (vendorId, currentSnapshot) in current {
            guard let previousSnapshot = previous[vendorId],
                  previousSnapshot.status.confidence == .measured,
                  currentSnapshot.status.confidence == .measured
            else { continue }

            var seenLabels: Set<String> = []
            for bar in currentSnapshot.bars where !bar.measuresElapsedTimeOnly {
                // A label reported twice is ambiguous; judge only the first,
                // exactly as `QuotaResetDetector` does.
                guard seenLabels.insert(bar.label).inserted else { continue }
                guard let oldBar = previousSnapshot.bars.first(where: {
                          $0.label == bar.label && !$0.measuresElapsedTimeOnly
                      }),
                      let previousFraction = oldBar.primaryFraction,
                      let currentFraction = bar.primaryFraction,
                      previousFraction - currentFraction >= minimumDrop - tolerance,
                      let previousReset = oldBar.resetsAt,
                      previousReset > now,
                      // Without a current reset time there is no window to
                      // describe the restore against; stay silent.
                      let currentReset = bar.resetsAt
                else { continue }

                events.append(UsageRestoredEvent(
                    vendorId: vendorId,
                    displayName: currentSnapshot.displayName,
                    barLabel: bar.label,
                    previousFraction: previousFraction,
                    currentFraction: currentFraction,
                    resetsAt: currentReset,
                    windowRestarted: currentReset.timeIntervalSince(previousReset) > QuotaResetDetector.minimumAdvance
                ))
            }
        }
        return events.sorted {
            ($0.vendorId.rawValue, $0.barLabel) < ($1.vendorId.rawValue, $1.barLabel)
        }
    }
}
