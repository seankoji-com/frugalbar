import Foundation

/// A vendor granted one or more banked usage-reset credits between two polls.
public struct ResetCreditGrantedEvent: Sendable, Equatable {
    public let vendorId: VendorIdentifier
    public let displayName: String
    /// The count on the previous poll. `nil` when that poll was measured but
    /// the vendor's payload carried no credit field at all.
    public let previousCount: Int?
    /// The vendor-published count now available.
    public let currentCount: Int

    public init(vendorId: VendorIdentifier, displayName: String, previousCount: Int?, currentCount: Int) {
        self.vendorId = vendorId
        self.displayName = displayName
        self.previousCount = previousCount
        self.currentCount = currentCount
    }
}

/// Detects a rise in `QuotaSnapshot.resetCreditsAvailable` between two polls.
///
/// Only the banked total counts. `resetCreditsApplicable` (how many can be
/// redeemed right now) flips with window state as the user consumes usage, so
/// firing on it would announce the same credit over and over.
///
/// Edge-triggered like the other poll detectors: a vendor with no previous
/// reading produces nothing, so the first poll after launch never announces
/// credits the user already had. Both polls must be `.measured` and both must
/// carry a count; a lost reading or a missing field is not "zero credits",
/// and treating either as one would announce every existing credit again the
/// moment the figure came back.
public enum ResetCreditDetector {

    public static func detect(
        previous: [VendorIdentifier: QuotaSnapshot],
        current: [VendorIdentifier: QuotaSnapshot]
    ) -> [ResetCreditGrantedEvent] {
        var events: [ResetCreditGrantedEvent] = []
        for (vendorId, currentSnapshot) in current {
            guard let previousSnapshot = previous[vendorId],
                  previousSnapshot.status.confidence == .measured,
                  currentSnapshot.status.confidence == .measured,
                  let currentCount = currentSnapshot.resetCreditsAvailable,
                  // Both polls must carry the figure. An absent count on a
                  // measured poll is "not published this time", not zero:
                  // comparing it as zero re-announced every banked credit
                  // whenever the field dropped out of one poll and came back.
                  let previousCount = previousSnapshot.resetCreditsAvailable,
                  currentCount > previousCount
            else { continue }
            events.append(ResetCreditGrantedEvent(
                vendorId: vendorId,
                displayName: currentSnapshot.displayName,
                previousCount: previousSnapshot.resetCreditsAvailable,
                currentCount: currentCount
            ))
        }
        return events.sorted { $0.vendorId.rawValue < $1.vendorId.rawValue }
    }
}
