import SwiftUI
import QuotaBarCore

/// Pure presentation for the configured Gemini API credit.
///
/// The monthly spend cap is the only configured figure the popover draws. It
/// becomes the account's API budget line, in the same anatomy as Codex's
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
        public static let title = "API budget"
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

        let seconds = end.timeIntervalSince(now)
        let days = max(0, seconds / 86_400).rounded(.up)
        let countdown: String?
        let dayPhrase: String?
        if days.isFinite, days < Double(Int.max) {
            let count = Int(days)
            countdown = "\(count)d"
            dayPhrase = "\(count) day\(count == 1 ? "" : "s") left in the month"
        } else {
            countdown = nil
            dayPhrase = nil
        }

        let amount = MoneyText.format(cap, code: currencyCode)
        var parts = ["API budget \(amount)",
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

/// The configured spend cap as its own monthly line under the Gemini row.
///
/// Same anatomy as Codex's separate monthly credit: name and amount in the
/// name column, one bar, percentage and countdown beneath. The prepaid balance
/// and monthly grant are not drawn here. The enclosing provider row owns the
/// accessibility element, so this view is decorative and the row's combined
/// label speaks the line.
struct GeminiAPICreditView: View {
    let presentation: GeminiAPICreditPresentation

    var body: some View {
        GeminiAPIBudgetView(budget: presentation.budget)
            .help(presentation.spoken)
            .accessibilityHidden(true)
    }
}

/// The configured cap as a monthly progress line.
///
/// The name and amount sit in the name column, the meter spans the grid, and
/// the percentage and countdown sit beneath it. The "MO" token and the spoken
/// label say the figure is month progress; without them a percentage under a
/// budget title would read as budget spent.
struct GeminiAPIBudgetView: View {
    let budget: GeminiAPICreditPresentation.Budget

    var body: some View {
        HStack(alignment: .top, spacing: Theme.rowSpacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(GeminiAPICreditPresentation.Budget.title)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .lineLimit(1)
                Text(budget.amountText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: Theme.nameColumnWidth, alignment: .leading)

            VStack(spacing: 4) {
                MonthlyCycleBar(fraction: budget.fraction)
                HStack(spacing: 2) {
                    Text("MO")
                        .font(Theme.Typography.token)
                        .tracking(Theme.Tracking.token)
                        .foregroundStyle(Theme.onSurfaceVariant)
                        .padding(.trailing, 4)
                    Text(budget.percentText)
                        .font(Theme.Typography.gridPercent)
                        .foregroundStyle(Theme.primary)
                    Spacer(minLength: 0)
                    if let countdown = budget.countdown {
                        Text(countdown)
                            .font(Theme.Typography.gridReset)
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.78))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
        .accessibilityHidden(true)
    }
}
