import SwiftUI
import QuotaBarCore

enum CreditExpiryText {
    static func countdown(_ expiry: Date?, now: Date) -> String {
        guard let expiry else { return "Expiry not published" }
        let seconds = expiry.timeIntervalSince(now)
        guard seconds.isFinite else { return "Expiry not published" }
        guard seconds > 0 else { return "Expired" }
        let days = (seconds / 86_400).rounded(.up)
        guard days < Double(Int.max) else { return "Expiry not published" }
        let count = Int(days)
        return "Expires in \(count) day\(count == 1 ? "" : "s")"
    }

    /// The compact ticket-line wording: "20d remaining" rather than "Expires
    /// in 20 days". A missing figure is stated plainly and a passed date is
    /// "Expired"; the absolute date stays in the ticket's tooltip.
    static func remaining(_ expiry: Date?, now: Date) -> String {
        guard let expiry else { return "Expiry not published" }
        let seconds = expiry.timeIntervalSince(now)
        guard seconds.isFinite else { return "Expiry not published" }
        guard seconds > 0 else { return "Expired" }
        let days = (seconds / 86_400).rounded(.up)
        guard days < Double(Int.max) else { return "Expiry not published" }
        let count = Int(days)
        return "\(count)d remaining"
    }

    /// The same fact for VoiceOver, where "20d" reads as a letter rather than
    /// a duration. The visible ticket line stays compact; the spoken label
    /// keeps the full word.
    static func remainingSpoken(_ expiry: Date?, now: Date) -> String {
        guard let expiry else { return "Expiry not published" }
        let seconds = expiry.timeIntervalSince(now)
        guard seconds.isFinite else { return "Expiry not published" }
        guard seconds > 0 else { return "Expired" }
        let days = (seconds / 86_400).rounded(.up)
        guard days < Double(Int.max) else { return "Expiry not published" }
        let count = Int(days)
        return "\(count) day\(count == 1 ? "" : "s") remaining"
    }
}

/// A one-time grant uses the account holder's original allowance and the
/// vendor's exact remaining count. It has no quota urgency. It has an even-use
/// tick only when the account holder confirmed both the grant date and the
/// expiry (`OpenAICreditGrant.periodLength`): OpenAI publishes neither.
public struct OpenAIUsageCreditPresentation: Equatable, Sendable {
    let fraction: Double
    let percentText: String
    let totalText: String
    let expiryText: String
    let spoken: String
    /// The grant as a window for the Wallet's bar: used share, expiry, and a
    /// pace only over a confirmed period. Nil without an expiry.
    let barMetrics: DualBarMetrics?

    init?(entry: APICreditEntry, now: Date, isStale: Bool) {
        guard entry.vendorId == .openai, entry.id == "openai.api-credits",
              case .credits(let remaining?, let unit) = entry.metric,
              unit == "credits", !remaining.isNaN, remaining >= 0,
              let grant = entry.creditGrant,
              // A new top-up can make the saved original allowance obsolete.
              // Omit the bar rather than reporting a false 0% used.
              remaining <= grant.total else { return nil }
        let used = NSDecimalNumber(decimal: (grant.total - remaining) / grant.total).doubleValue
        guard used.isFinite else { return nil }
        fraction = used
        percentText = "\(Int((used * 100).rounded()))% used"
        totalText = "of \(CreditText.format(grant.total))"
        expiryText = CreditExpiryText.countdown(grant.expiresAt, now: now)
        let length = grant.periodLength
        barMetrics = grant.expiresAt.map { end in
            DualBarMetrics(
                primaryFraction: used,
                expectedPaceFraction: length.flatMap { DualBarMetrics.proRataPace(resetsAt: end, windowLength: $0, now: now) },
                label: "EXP", resetsAt: end, windowLength: length)
        }
        var parts = ["Usage credits", percentText, "\(totalText) credits", expiryText]
        if let pace = barMetrics?.paceMarker {
            parts.append("even use by now is \(Int((pace * 100).rounded()))% used")
        }
        parts.append(length == nil ? "Original allowance and expiry entered by you"
                                   : "Original allowance, grant date and expiry entered by you")
        if isStale { parts.append("stale, the last poll failed") }
        spoken = parts.joined(separator: ", ")
    }
}
