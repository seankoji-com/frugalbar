import Foundation

/// Everything that changed between two polls and might merit a notification.
public struct QuotaTransitions: Sendable, Equatable {
    public let recoveries: [QuotaRecoveryEvent]
    public let resets: [QuotaResetEvent]
    public let restores: [UsageRestoredEvent]
    public let creditGrants: [ResetCreditGrantedEvent]

    public init(
        recoveries: [QuotaRecoveryEvent],
        resets: [QuotaResetEvent],
        restores: [UsageRestoredEvent] = [],
        creditGrants: [ResetCreditGrantedEvent] = []
    ) {
        self.recoveries = recoveries
        self.resets = resets
        self.restores = restores
        self.creditGrants = creditGrants
    }
}

/// Tracks the last-seen snapshot per vendor across polls and surfaces
/// critical→recovered transitions and window resets as they happen.
///
/// Pure state-keeping over `[QuotaSnapshot]` — no `UserNotifications` or
/// AppKit import. The delivery call lives in
/// `QuotaBarApp/NotificationDelivery.swift`, which owns the toggle check and
/// the `UNUserNotificationCenter`/`osascript` branch; this type only ever
/// answers "what changed since last time".
///
/// Restores and recoveries wait for a second read that agrees. A single bad
/// vendor response is indistinguishable from a real restore on its own:
/// Antigravity once served Gemini, Claude/GPT and Argon WK at 0% with a reset
/// of "request time + 7 days" in one poll, then the old figures on the next,
/// and that one response announced three restores nobody received. So a drop
/// or a recovery is a *candidate* until the next fresh read of the same
/// instance. A read that agrees confirms it, and the event is built from the
/// candidate's own figures, so its id is unchanged. A read that disagrees
/// discards it. A read that is not fresh (the same cached snapshot seen again,
/// or a retained one after a failed poll) neither confirms nor discards. The
/// cost is that these alerts arrive about one poll later, and a candidate
/// still pending when the app quits is lost. Resets are unaffected: they
/// already need the vendor's own reset time to have passed.
public actor QuotaNotificationObserver {

    private var previous: [String: QuotaSnapshot] = [:]
    private var confirmationBaseline: [String: QuotaSnapshot] = [:]

    private struct RestoreKey: Hashable {
        let instanceID: String
        let barLabel: String
    }

    /// A detected event waiting for its confirming read, with the
    /// `lastUpdated` of the snapshot it was detected in.
    private struct Pending<Event: Sendable>: Sendable {
        let event: Event
        let observedAt: Date
    }

    private var pendingRestores: [RestoreKey: Pending<UsageRestoredEvent>] = [:]
    private var pendingRecoveries: [String: Pending<QuotaRecoveryEvent>] = [:]

    public init() {}

    /// Keys `current` by each provider instance's stable id, diffs it against
    /// the stored previous state, updates the stored state, and returns any
    /// recovery events.
    ///
    /// Called on every poll regardless of whether notifications are enabled,
    /// so the stored "previous" state stays current even while the feature is
    /// off — only delivery is gated by the caller's toggle check.
    public func observe(current: [QuotaSnapshot]) -> [QuotaRecoveryEvent] {
        observeTransitions(current: current, now: Date()).recoveries
    }

    /// Same bookkeeping as `observe(current:)`, returning resets, unscheduled
    /// restores and reset-credit grants as well.
    /// `now` decides whether a previously reported reset time has passed.
    ///
    /// Safe to call more often than the vendors are polled (after a user
    /// refresh as well as on the schedule): the same snapshots seen again are
    /// not a fresh read, so they confirm nothing and discard nothing.
    public func observeTransitions(current: [QuotaSnapshot], now: Date) -> QuotaTransitions {
        var currentByInstance: [String: QuotaSnapshot] = [:]
        for snapshot in current {
            currentByInstance[snapshot.id] = snapshot
        }

        // Judge the waiting candidates against this read before this read can
        // raise new ones.
        let restores = confirmRestores(current: currentByInstance)
        let recoveries = confirmRecoveries(current: currentByInstance)

        let fresh = currentByInstance.filter { id, snapshot in
            Self.isFresh(snapshot, after: confirmationBaseline[id]?.lastUpdated ?? .distantPast)
        }
        let measuredBaseline = confirmationBaseline.filter { $0.value.staleReading == nil }
        for event in UsageRestoreDetector.detect(previous: measuredBaseline, current: fresh, now: now) {
            let instanceID = event.instanceId ?? event.vendorId.rawValue
            guard let snapshot = currentByInstance[instanceID] else { continue }
            pendingRestores[RestoreKey(instanceID: instanceID, barLabel: event.barLabel)] =
                Pending(event: event, observedAt: snapshot.lastUpdated)
        }
        for event in QuotaTransitionDetector.detect(previous: measuredBaseline, current: fresh) {
            let instanceID = event.instanceId ?? event.vendorId.rawValue
            guard let snapshot = currentByInstance[instanceID] else { continue }
            pendingRecoveries[instanceID] = Pending(event: event, observedAt: snapshot.lastUpdated)
        }

        let transitions = QuotaTransitions(
            recoveries: recoveries,
            resets: QuotaResetDetector.detect(previous: previous, current: currentByInstance, now: now),
            restores: restores,
            creditGrants: ResetCreditDetector.detect(previous: previous, current: currentByInstance)
        )
        // A stale or older measured snapshot cannot become the next
        // comparison baseline. In particular, a cached high reading between
        // a candidate and its confirmation must not raise the candidate again.
        confirmationBaseline = currentByInstance.mapValues { snapshot in
            if snapshot.status.confidence == .measured, fresh[snapshot.id] == nil,
               let last = confirmationBaseline[snapshot.id] { return last }
            return snapshot
        }
        previous = currentByInstance
        return transitions
    }

    /// A read newer than the candidate's, made by this poll, with figures.
    /// Providers stamp `lastUpdated` when they fetch; a cached or retained
    /// snapshot keeps the stamp of the read it came from.
    private static func isFresh(_ snapshot: QuotaSnapshot, after observedAt: Date) -> Bool {
        snapshot.lastUpdated > observedAt
            && snapshot.staleReading == nil
            && snapshot.status.confidence == .measured
    }

    /// Confirmed when the next fresh read still shows the window at least
    /// `minimumDrop` below the fraction it fell from, against the same reset
    /// time. A rebound, or a reset time that moved again, means the drop was
    /// not the vendor's settled figure.
    private func confirmRestores(current: [String: QuotaSnapshot]) -> [UsageRestoredEvent] {
        var confirmed: [UsageRestoredEvent] = []
        for (key, pending) in pendingRestores {
            // A provider that left the list is hidden and no longer polled.
            guard let snapshot = current[key.instanceID] else {
                pendingRestores[key] = nil
                continue
            }
            guard Self.isFresh(snapshot, after: pending.observedAt) else { continue }
            pendingRestores[key] = nil
            let candidate = pending.event
            guard let bar = snapshot.bars.first(where: {
                      $0.label == key.barLabel && !$0.measuresElapsedTimeOnly
                  }),
                  let fraction = bar.primaryFraction,
                  fraction <= candidate.previousFraction - UsageRestoreDetector.minimumDrop
                      + UsageRestoreDetector.tolerance,
                  let reset = bar.resetsAt,
                  abs(reset.timeIntervalSince(candidate.resetsAt)) <= QuotaResetDetector.minimumAdvance
            else { continue }
            confirmed.append(candidate)
        }
        return confirmed.sorted {
            ($0.vendorId.rawValue, $0.displayName, $0.barLabel)
                < ($1.vendorId.rawValue, $1.displayName, $1.barLabel)
        }
    }

    /// Confirmed when the next fresh read is still not critical.
    private func confirmRecoveries(current: [String: QuotaSnapshot]) -> [QuotaRecoveryEvent] {
        var confirmed: [QuotaRecoveryEvent] = []
        for (instanceID, pending) in pendingRecoveries {
            guard let snapshot = current[instanceID] else {
                pendingRecoveries[instanceID] = nil
                continue
            }
            guard Self.isFresh(snapshot, after: pending.observedAt) else { continue }
            pendingRecoveries[instanceID] = nil
            guard snapshot.status.urgency != .critical else { continue }
            confirmed.append(pending.event)
        }
        return confirmed.sorted {
            ($0.vendorId.rawValue, $0.instanceId ?? "", $0.displayName)
                < ($1.vendorId.rawValue, $1.instanceId ?? "", $1.displayName)
        }
    }
}
