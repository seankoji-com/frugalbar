import Foundation

/// One provider's quota regaining headroom after being critical.
///
/// Pure data — no delivery mechanism attached. `QuotaNotificationObserver`
/// produces these from consecutive snapshot sets; `AppMain` decides whether
/// and how to surface them.
public struct QuotaRecoveryEvent: Sendable, Equatable {
    public let vendorId: VendorIdentifier
    public let displayName: String

    public init(vendorId: VendorIdentifier, displayName: String) {
        self.vendorId = vendorId
        self.displayName = displayName
    }
}

/// Detects critical→recovered transitions between two snapshot sets.
///
/// Pure logic over `[VendorIdentifier: QuotaSnapshot]` — no `UserNotifications`
/// or AppKit import, matching `SystemHealthSummary`/`QuotaAdvice`. Hermetically
/// testable with plain snapshot values.
public enum QuotaTransitionDetector {

    /// A recovery event fires for a vendor iff its *previous* reading was a
    /// measured `.critical` and its *current* reading is measured and no
    /// longer `.critical`.
    ///
    /// - `Confidence` and `Urgency` are kept as separate axes exactly as
    ///   AGENTS.md specifies: a transition into `.unavailable` (a lost
    ///   reading) is never treated as "recovered", and both the prior and
    ///   current reading must be `.measured` for an event to fire at all.
    /// - No entry for a vendor in `previous` produces no event — this is what
    ///   makes the first poll after launch fire nothing, since there is no
    ///   prior reading to compare against.
    public static func detect(
        previous: [VendorIdentifier: QuotaSnapshot],
        current: [VendorIdentifier: QuotaSnapshot]
    ) -> [QuotaRecoveryEvent] {
        var events: [QuotaRecoveryEvent] = []
        for (vendorId, currentSnapshot) in current {
            guard let previousSnapshot = previous[vendorId] else { continue }
            guard previousSnapshot.status.confidence == .measured,
                  previousSnapshot.status.urgency == .critical else { continue }
            guard currentSnapshot.status.confidence == .measured,
                  currentSnapshot.status.urgency != .critical else { continue }
            events.append(QuotaRecoveryEvent(
                vendorId: vendorId,
                displayName: currentSnapshot.displayName
            ))
        }
        return events.sorted { $0.vendorId.rawValue < $1.vendorId.rawValue }
    }
}
