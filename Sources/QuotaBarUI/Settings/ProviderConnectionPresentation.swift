import Foundation
import QuotaBarCore

/// What Preferences says about one provider's connection, in words and an SF
/// Symbol, so its state never rests on colour alone.
///
/// Built from the running app's last poll when there is one. A hidden
/// provider is described as hidden and nothing else: it is not polled, so any
/// reading it once had is stale and must not be shown as current.
public enum ProviderConnectionPresentation {

    public enum Tone: Equatable, Sendable {
        /// Read successfully on the last poll.
        case connected
        /// Needs the user: a rejected key, an unreachable vendor.
        case attention
        /// Nothing to act on yet: hidden, not configured, not read.
        case inactive
    }

    public struct Status: Equatable, Sendable {
        public let symbol: String
        public let title: String
        /// The remedy for an unreadable provider, or when it was last read.
        public let detail: String?
        public let tone: Tone

        public var accessibilityText: String {
            [title, detail].compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// The SF Symbol for an unreadable provider, by reason.
    static func symbol(for reason: UnavailableReason) -> String {
        switch reason {
        case .notConfigured: "circle.dashed"
        case .credentialRejected: "lock.slash"
        case .unsupported: "minus.circle"
        case .offline: "wifi.slash"
        case .timedOut: "hourglass"
        case .badResponse: "exclamationmark.triangle"
        case .rateLimited: "tortoise"
        }
    }

    /// One provider instance's state from its latest snapshot.
    public static func status(for snapshot: QuotaSnapshot, now: Date) -> Status {
        if let reason = snapshot.status.unavailableReason {
            return Status(
                symbol: symbol(for: reason), title: reason.headline, detail: reason.remedy,
                tone: reason == .notConfigured ? .inactive : .attention)
        }
        return Status(
            symbol: "checkmark.circle.fill", title: "Connected",
            detail: "Read \(MetricDetailPresentation.lastFetchedText(snapshot.lastUpdated, now: now))",
            tone: .connected)
    }

    /// A vendor's row: its own state, or for several instances (OpenCode Go
    /// workspaces) how many could be read.
    ///
    /// - Parameters:
    ///   - snapshots: this vendor's snapshots from the last poll.
    ///   - hasPolled: false when there is no running poll to consult (the
    ///     standalone Settings scene) or it has not finished yet.
    ///   - credentialSource: where the credential comes from, when known.
    public static func status(
        vendorSnapshots snapshots: [QuotaSnapshot],
        isHidden: Bool,
        hasPolled: Bool,
        credentialSource: CredentialStore.CredentialSource? = nil,
        now: Date
    ) -> Status {
        if isHidden {
            return Status(symbol: "eye.slash", title: "Hidden", detail: "Not polled", tone: .inactive)
        }
        guard hasPolled, !snapshots.isEmpty else {
            if case .absent? = credentialSource {
                let reason = UnavailableReason.notConfigured
                return Status(symbol: symbol(for: reason), title: reason.headline, detail: reason.remedy, tone: .inactive)
            }
            return Status(symbol: "clock", title: "Not read yet", detail: nil, tone: .inactive)
        }
        if snapshots.count == 1 { return status(for: snapshots[0], now: now) }

        let unreadable = snapshots.filter { $0.status.unavailableReason != nil }
        if unreadable.isEmpty {
            return Status(
                symbol: "checkmark.circle.fill", title: "Connected",
                detail: "All \(snapshots.count) read", tone: .connected)
        }
        let worst = unreadable.first { $0.status.unavailableReason != .notConfigured } ?? unreadable[0]
        let reason = worst.status.unavailableReason ?? .notConfigured
        return Status(
            symbol: symbol(for: reason),
            title: "\(unreadable.count) of \(snapshots.count) unreadable",
            detail: "\(worst.rowTitle): \(reason.headline). \(reason.remedy)",
            tone: unreadable.count == snapshots.count && reason == .notConfigured ? .inactive : .attention)
    }
}
