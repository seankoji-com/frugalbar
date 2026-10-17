import Foundation

/// Which readings the phone may no longer trust the age of (D§2.2.C, "Clock
/// discontinuity").
///
/// A clock sample says nothing about timestamps recorded *before* the clock
/// was corrected. On `NSSystemClockDidChangeNotification`, or when two
/// consecutive samples' offsets differ by more than 5 minutes, every reading
/// retained at that moment is exported with `measuredAtTrusted: false` until
/// it is measured again. "Measured again" is a different `lastUpdated`, not a
/// later one: after a clock jump, later is exactly what cannot be compared.
struct SyncClockTrust: Sendable, Equatable {
    static let jumpThresholdMs = 5 * 60 * 1000

    /// The last sample's offset. A missing `Date` header leaves it in place,
    /// so the next real sample is compared with the last real one.
    private(set) var lastOffsetMs: Int?
    /// Instance id → the `lastUpdated` its reading had at the discontinuity.
    private(set) var distrusted: [String: Date] = [:]

    /// Every retained reading becomes untrusted.
    mutating func discontinuity(retaining snapshots: [QuotaSnapshot]) {
        for snapshot in snapshots { distrusted[snapshot.id] = snapshot.lastUpdated }
    }

    /// Records a clock sample; a jump of more than 5 minutes from the last
    /// one is a discontinuity. Returns whether it was.
    @discardableResult
    mutating func sample(offsetMs: Int?, retaining snapshots: [QuotaSnapshot]) -> Bool {
        guard let offsetMs else { return false }
        defer { lastOffsetMs = offsetMs }
        guard let last = lastOffsetMs, abs(offsetMs - last) > Self.jumpThresholdMs else { return false }
        discontinuity(retaining: snapshots)
        return true
    }

    /// The instances still untrusted in `snapshots`. A reading measured again
    /// since the discontinuity is forgotten here and trusted from now on.
    mutating func untrustedIDs(in snapshots: [QuotaSnapshot]) -> Set<String> {
        var untrusted = Set<String>()
        for snapshot in snapshots {
            guard let at = distrusted[snapshot.id] else { continue }
            if at == snapshot.lastUpdated {
                untrusted.insert(snapshot.id)
            } else {
                distrusted.removeValue(forKey: snapshot.id)
            }
        }
        return untrusted
    }
}

/// Hands `NSSystemClockDidChangeNotification` to the publisher, which then
/// distrusts every reading it holds (REQ-MAC-CLOCK b).
public final class SyncClockChangeObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    public init(publisher: SyncPublisher, center: NotificationCenter = .default) {
        self.center = center
        token = center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: nil) { _ in
            Task { await publisher.clockDidChange() }
        }
    }

    deinit { center.removeObserver(token) }
}
