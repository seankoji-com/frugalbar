import SwiftUI
import QuotaBarCore

/// Pure presentation for the configured Gemini API credit.
///
/// The monthly spend cap is the only configured figure the popover draws. It
/// becomes the account's API credit line, in the same anatomy as Codex's
/// separate monthly credit: name column, one bar, percentage and countdown
/// beneath. The prepaid balance and monthly grant stay in Settings because
/// Google publishes them only in AI Studio; they are not drawn in the popover.
/// The fill is elapsed calendar time, never spend: Google publishes no spend
/// figure for a Gemini API key, and dividing the prepaid balance into the cap
/// would mix a prepaid pool with a spend limit.
public struct GeminiAPICreditPresentation: Equatable, Sendable {

    /// The configured monthly spend cap, presented as the account's API
    /// budget, with a meter for progress through the calendar month.
    ///
    /// `fraction` is time, not money: it is the elapsed share of the calendar
    /// month containing `now`. Google publishes no spend figure for an API key,
    /// so no percentage of the budget is claimed. The meter uses the
    /// informational colour, never a quota state colour, and takes no part in
    /// quota maths.
    public struct Budget: Equatable, Sendable {
        public static let title = "API credit"
        /// The configured cap in the billing account's own money.
        public let amountText: String
        /// Elapsed share of the calendar month, 0…1.
        public let fraction: Double
        /// "65%" — the same elapsed share.
        public let percentText: String
        /// "11d" left in the month, or nil when the calendar cannot state it.
        public let countdown: String?
        /// The whole line in words, for the row's one accessibility element
        /// and its tooltip. It says the fill is time and not spend.
        public let spoken: String
    }

    public let budget: Budget
    /// The whole line in words, for the row's one accessibility element and
    /// its tooltip. It names the saved date, because a configured figure ages
    /// without a poll, and says it is not a vendor reading.
    public let spoken: String

    /// Nil when no spend cap was saved, or when the calendar month cannot be
    /// resolved: there is then no line to draw, and the row must not speak one.
    public init?(credit: GeminiAPICredit, now: Date = Date(), calendar: Calendar = .current) {
        guard let budget = credit.monthlySpendCap.flatMap({
            Self.budget(cap: $0, currencyCode: credit.currencyCode,
                        now: now, calendar: calendar)
        }) else { return nil }
        self.budget = budget
        self.spoken = [
            budget.spoken,
            "configured \(Self.dateText(credit.configuredAt, month: .wide, calendar: calendar))",
            "not a vendor reading",
        ].joined(separator: ", ")
    }

    /// The cap as a calendar-month meter. Returns nil when the month's bounds
    /// cannot be resolved.
    private static func budget(
        cap: Decimal, currencyCode: String, now: Date, calendar: Calendar
    ) -> Budget? {
        guard cap > 0, now.timeIntervalSince1970.isFinite else { return nil }
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .month, value: 1, to: start),
              end > start else { return nil }
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return nil }
        let elapsed = now.timeIntervalSince(start) / length
        guard elapsed.isFinite else { return nil }
        let fraction = min(max(elapsed, 0), 1)
        let percent = Int((fraction * 100).rounded())

        // Calendar days, not 24-hour periods: a fall-back month is 30 days
        // plus an hour, and dividing its seconds by 86,400 rounded up said 31d.
        let dayCount = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: end).day
        let countdown: String?
        let dayPhrase: String?
        if let dayCount, dayCount >= 0 {
            countdown = "\(dayCount)d"
            dayPhrase = "\(dayCount) day\(dayCount == 1 ? "" : "s") left in the month"
        } else {
            countdown = nil
            dayPhrase = nil
        }

        let amount = MoneyText.format(cap, code: currencyCode)
        var parts = ["API credit \(amount)",
                     "\(percent)% of the calendar month elapsed"]
        if let dayPhrase { parts.append(dayPhrase) }
        parts.append("not spend, the fill is elapsed calendar time")
        return Budget(amountText: amount, fraction: fraction,
                      percentText: "\(percent)%", countdown: countdown,
                      spoken: parts.joined(separator: ", "))
    }

    /// A value-style formatter, so rebuilding the row on hover does not allocate
    /// a `DateFormatter`. The locale is fixed so the field order stays
    /// day-month-year rather than following the reader's locale, and the time
    /// zone is the one that rendered the rest of the row.
    private static func dateText(
        _ date: Date, month: Date.FormatStyle.Symbol.Month, calendar: Calendar
    ) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(day: .defaultDigits) \(month: month) \(year: .defaultDigits)",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: calendar.timeZone,
            calendar: calendar)
        return date.formatted(style)
    }
}
