import Foundation

/// Tracks the last-seen snapshot per vendor across polls and surfaces
/// critical→recovered transitions as they happen.
///
/// Pure state-keeping over `[QuotaSnapshot]` — no `UserNotifications` or
/// AppKit import. The actual `osascript` delivery call lives in
/// `QuotaBarApp/AppMain.swift`, which owns the toggle check and the `Process`
/// invocation; this type only ever answers "what changed since last time".
public actor QuotaNotificationObserver {

    private var previous: [VendorIdentifier: QuotaSnapshot] = [:]

    public init() {}

    /// Keys `current` by `vendorId`, diffs it against the stored previous
    /// state, updates the stored state, and returns any recovery events.
    ///
    /// Called on every poll regardless of whether notifications are enabled,
    /// so the stored "previous" state stays current even while the feature is
    /// off — only delivery is gated by the caller's toggle check.
    public func observe(current: [QuotaSnapshot]) -> [QuotaRecoveryEvent] {
        var currentByVendor: [VendorIdentifier: QuotaSnapshot] = [:]
        for snapshot in current {
            currentByVendor[snapshot.vendorId] = snapshot
        }
        let events = QuotaTransitionDetector.detect(previous: previous, current: currentByVendor)
        previous = currentByVendor
        return events
    }
}
