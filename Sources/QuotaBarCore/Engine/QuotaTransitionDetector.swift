import Foundation

/// One provider's quota regaining headroom after being critical.
///
/// Pure data — no delivery mechanism attached. `QuotaNotificationObserver`
/// produces these from consecutive snapshot sets; `AppMain` decides whether
/// and how to surface them.
public struct QuotaRecoveryEvent: Sendable, Equatable {
    public let vendorId: VendorIdentifier
    public let displayName: String
    /// The instance that recovered, when the vendor serves more than one
    /// (`QuotaSnapshot.instanceIdOrNil`) — two OpenCode Go workspaces may share
    /// a display name, and the notification has to name which one came back.
    public let instanceId: String?

    public init(vendorId: VendorIdentifier, displayName: String, instanceId: String? = nil) {
        self.vendorId = vendorId
        self.displayName = displayName
        self.instanceId = instanceId
    }
}

/// Detects critical→recovered transitions between two snapshot sets.
///
/// Pure logic over `[String: QuotaSnapshot]` (keyed by each provider instance's
/// stable id) — no `UserNotifications` or AppKit import, matching
/// `SystemHealthSummary`/`QuotaAdvice`. Hermetically testable with plain
/// snapshot values. Keying by instance rather than vendor is what stops two
/// OpenCode Go workspaces from overwriting each other's previous reading, which
/// would otherwise fabricate a reset.
public enum QuotaTransitionDetector {

    /// A recovery event fires for a provider instance iff its *previous*
    /// reading was a measured `.critical` and its *current* reading is measured
    /// and no longer `.critical`.
    ///
    /// - `Confidence` and `Urgency` are kept as separate axes exactly as
    ///   AGENTS.md specifies: a transition into `.unavailable` (a lost
    ///   reading) is never treated as "recovered", and both the prior and
    ///   current reading must be `.measured` for an event to fire at all.
    /// - No entry for a provider instance in `previous` produces no event —
    ///   this is what makes the first poll after launch fire nothing, since
    ///   there is no prior reading to compare against.
    public static func detect(
        previous: [String: QuotaSnapshot],
        current: [String: QuotaSnapshot]
    ) -> [QuotaRecoveryEvent] {
        var events: [QuotaRecoveryEvent] = []
        for (instanceID, currentSnapshot) in current {
            guard let previousSnapshot = previous[instanceID] else { continue }
            guard previousSnapshot.status.confidence == .measured,
                  previousSnapshot.status.urgency == .critical else { continue }
            guard currentSnapshot.status.confidence == .measured,
                  currentSnapshot.status.urgency != .critical else { continue }
            events.append(QuotaRecoveryEvent(
                vendorId: currentSnapshot.vendorId,
                displayName: currentSnapshot.displayName,
                instanceId: currentSnapshot.instanceIdOrNil
            ))
        }
        return events.sorted {
            ($0.vendorId.rawValue, $0.instanceId ?? "", $0.displayName)
                < ($1.vendorId.rawValue, $1.instanceId ?? "", $1.displayName)
        }
    }
}
