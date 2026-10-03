import Foundation

/// One quota window rolling over into a fresh allowance.
///
/// Pure data, like `QuotaRecoveryEvent`: `QuotaNotificationObserver` produces
/// these and `AppMain` decides whether the user opted in to hearing about it.
public struct QuotaResetEvent: Sendable, Equatable {
    public let vendorId: VendorIdentifier
    public let displayName: String
    /// The window that reset, e.g. "5H" or "WK".
    public let barLabel: String
    /// The new window's reset time, as the current poll reported it. Part of
    /// the event's identity: the same window rolling over is one event however
    /// often it is re-derived. Optional with a nil default only so callers
    /// that predate it still compile; `QuotaResetDetector` always sets it.
    public let resetsAt: Date?

    public init(vendorId: VendorIdentifier, displayName: String, barLabel: String, resetsAt: Date? = nil) {
        self.vendorId = vendorId
        self.displayName = displayName
        self.barLabel = barLabel
        self.resetsAt = resetsAt
    }
}

/// Detects quota windows that reset between two polls.
///
/// The only evidence used is the vendor's own reset time. A window counts as
/// reset when the previous poll reported a reset time that has now passed and
/// the current poll reports a later one. A drop in the consumed fraction is
/// deliberately *not* treated as a reset: vendors revise figures, and a
/// notification claiming a fresh allowance nobody published is the same
/// fabrication as an invented quota.
public enum QuotaResetDetector {

    /// How far the reset time must move forward to count as a new window.
    /// Rolling windows re-derive their reset time on every request, so a few
    /// seconds of drift between polls is noise, not a rollover.
    public static let minimumAdvance: TimeInterval = 60

    public static func detect(
        previous: [VendorIdentifier: QuotaSnapshot],
        current: [VendorIdentifier: QuotaSnapshot],
        now: Date
    ) -> [QuotaResetEvent] {
        var events: [QuotaResetEvent] = []
        for (vendorId, currentSnapshot) in current {
            guard let previousSnapshot = previous[vendorId],
                  previousSnapshot.status.confidence == .measured,
                  currentSnapshot.status.confidence == .measured
            else { continue }

            var seenLabels: Set<String> = []
            for bar in currentSnapshot.bars where !bar.measuresElapsedTimeOnly {
                // A label reported twice is ambiguous; judge only the first.
                guard seenLabels.insert(bar.label).inserted else { continue }
                guard let newReset = bar.resetsAt,
                      let oldBar = previousSnapshot.bars.first(where: {
                          $0.label == bar.label && !$0.measuresElapsedTimeOnly
                      }),
                      let oldReset = oldBar.resetsAt,
                      // "Passed" with `minimumAdvance` of tolerance: a Mac
                      // clock a few seconds slow, or a vendor rolling a few
                      // seconds before its published time, must not turn a
                      // scheduled rollover into `UsageRestoreDetector`'s
                      // event (which requires the old reset to be *more* than
                      // this far ahead).
                      oldReset.timeIntervalSince(now) <= minimumAdvance,
                      newReset.timeIntervalSince(oldReset) > minimumAdvance
                else { continue }
                events.append(QuotaResetEvent(
                    vendorId: vendorId,
                    displayName: currentSnapshot.displayName,
                    barLabel: bar.label,
                    resetsAt: newReset
                ))
            }
        }
        return events.sorted {
            ($0.vendorId.rawValue, $0.barLabel) < ($1.vendorId.rawValue, $1.barLabel)
        }
    }
}
