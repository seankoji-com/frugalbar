import SwiftUI
import QuotaBarCore

/// The linked Console organisation's monthly credit, drawn as the monthly
/// meter the row now uses.
///
/// The fill is **billing-cycle progress**, not API spend: the linked payload
/// publishes the monthly amount and the next grant date, but no used figure.
/// Filling it with a spend number would invent one, so the bar measures the
/// calendar month ending at `nextGrantAt` and shows the compact percentage.
/// The tooltip and VoiceOver label explain that it is elapsed time. It is
/// deliberately outside quota maths — no urgency, sorting, advice, history or
/// menu-bar icon reads it — and uses the informational `Theme.primary` rather
/// than the quota state colours.
public struct MonthlyCreditBarPresentation: Equatable, Sendable {
    public let title: String
    /// The entitlement's own monthly amount in USD, e.g. "$200.00".
    public let amountText: String
    /// Elapsed share of the billing month, 0…1. Nil when the next grant date
    /// is not published, or when that date is outside the current cycle; then
    /// no bar, percentage or countdown is drawn.
    public let fraction: Double?
    public let percentText: String?
    /// The compact countdown, e.g. "4d".
    public let countdown: String?
    /// The cycle the elapsed share was measured in, for a caller that draws a
    /// position mark on its own track (`WalletSection`): the end is the reset
    /// and the span its length. Nil when no current cycle was measured.
    public let periodEnd: Date?
    public let periodLength: TimeInterval?
    public let isStale: Bool
    public let spoken: String

    public init(credit: ClaudeMonthlyCredit, now: Date, calendar: Calendar = .current) {
        self.title = "API credit"
        let amount = MoneyText.format(credit.amountUSD, code: "USD")
        self.amountText = amount
        self.isStale = credit.refreshFailed

        var elapsed: Double?
        var countdown: String?
        var periodEnd: Date?
        var periodLength: TimeInterval?
        if let end = credit.nextGrantAt,
           let length = DualBarMetrics.monthWindowLength(endingAt: end, calendar: calendar) {
            let start = end.addingTimeInterval(-length)
            // Only a current cycle has a meaningful progress figure. A stale
            // next-grant date from a failed read, or a date beyond the next
            // cycle, must not be pinned to 100% or 0%: that would report a
            // position in a cycle this reading never measured.
            if now >= start, now < end {
                let value = now.timeIntervalSince(start) / length
                if value.isFinite {
                    elapsed = min(max(value, 0), 1)
                }
                countdown = ResetCountdownBadge.compact(end, now: now)
                periodEnd = end
                periodLength = length
            }
        }
        self.periodEnd = periodEnd
        self.periodLength = periodLength
        self.fraction = elapsed
        self.percentText = elapsed.map { "\(Int(($0 * 100).rounded()))%" }
        self.countdown = countdown

        var parts = ["\(amount) monthly credit"]
        if let percentText = self.percentText {
            parts.append("\(percentText) of the billing month elapsed")
        }
        if let end = credit.nextGrantAt {
            parts.append("next credit \(Self.dateText(end, calendar: calendar))")
        }
        if credit.refreshFailed {
            parts.append("stale monthly credit reading")
        }
        self.spoken = parts.joined(separator: ", ")
    }

    /// A value-style formatter, so rebuilding the row on hover does not
    /// allocate a DateFormatter per visible provider row. The calendar and
    /// time zone are the same ones that produced the cycle window, and the
    /// field order stays "15 November 2026" rather than following a locale's
    /// month-first order.
    private static func dateText(_ date: Date, calendar: Calendar) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(day: .defaultDigits) \(month: .wide) \(year: .defaultDigits)",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: calendar.timeZone,
            calendar: calendar)
        return date.formatted(style)
    }
}
