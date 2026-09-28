import Foundation

/// Everything that changed between two polls and might merit a notification.
public struct QuotaTransitions: Sendable, Equatable {
    public let recoveries: [QuotaRecoveryEvent]
    public let resets: [QuotaResetEvent]

    public init(recoveries: [QuotaRecoveryEvent], resets: [QuotaResetEvent]) {
        self.recoveries = recoveries
        self.resets = resets
    }
}

/// Tracks the last-seen snapshot per vendor across polls and surfaces
/// critical→recovered transitions and window resets as they happen.
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
        observeTransitions(current: current, now: Date()).recoveries
    }

    /// Same bookkeeping as `observe(current:)`, returning resets as well.
    /// `now` decides whether a previously reported reset time has passed.
    public func observeTransitions(current: [QuotaSnapshot], now: Date) -> QuotaTransitions {
        var currentByVendor: [VendorIdentifier: QuotaSnapshot] = [:]
        for snapshot in current {
            currentByVendor[snapshot.vendorId] = snapshot
        }
        let transitions = QuotaTransitions(
            recoveries: QuotaTransitionDetector.detect(previous: previous, current: currentByVendor),
            resets: QuotaResetDetector.detect(previous: previous, current: currentByVendor, now: now)
        )
        previous = currentByVendor
        return transitions
    }
}
