import SwiftUI
import QuotaBarCore

/// Pure presentation for the configured Gemini API credit.
///
/// Every figure is the one the user saved; nothing here is derived from a poll,
/// divided into a cap or dressed as a percentage. The title says "Gemini API"
/// rather than the Antigravity row's "Gemini" so it cannot read as part of the
/// subscription quota beside it, and the note always says the figures were
/// configured.
public struct GeminiAPICreditPresentation: Equatable, Sendable {

    /// One labelled money figure. The label is the one thing a bare amount
    /// cannot say for itself: a balance, a recurring grant and a spend cap are
    /// different money, and printing one under another's name is the
    /// wrong-label defect.
    public struct Figure: Equatable, Sendable, Identifiable {
        public let label: String
        public let figure: String
        public var id: String { label }
    }

    public static let title = "Gemini API credit"

    public let figures: [Figure]
    /// "Configured 20 Nov 2026" — the date the user saved the figures, because
    /// a typed balance ages without a poll saying so.
    public let configuredNote: String
    /// The whole line in words, for the row's one accessibility element and
    /// its tooltip. It names the figures as configured and explicitly says
    /// they are not a vendor reading.
    public let spoken: String

    public init(credit: GeminiAPICredit, calendar: Calendar = .current) {
        var figures: [Figure] = []
        if let balance = credit.prepaidBalance {
            figures.append(Figure(label: "Prepaid balance",
                figure: MoneyText.format(balance, code: credit.currencyCode)))
        }
        if let monthly = credit.monthlyCredit {
            figures.append(Figure(label: "Monthly credit",
                figure: MoneyText.format(monthly, code: credit.currencyCode)))
        }
        if let cap = credit.monthlySpendCap {
            figures.append(Figure(label: "Monthly spend cap",
                figure: MoneyText.format(cap, code: credit.currencyCode)))
        }
        self.figures = figures
        self.configuredNote = "Configured \(Self.dateText(credit.configuredAt, month: .abbreviated, calendar: calendar))"

        var parts = [
            Self.title,
            "configured \(Self.dateText(credit.configuredAt, month: .wide, calendar: calendar))",
            "not a vendor reading",
        ]
        parts += figures.map { "\($0.label) \($0.figure)" }
        self.spoken = parts.joined(separator: ", ")
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

/// The configured Gemini API credit, drawn under the Gemini row.
///
/// No bar, no marker, no countdown and no state colour: those belong to a
/// measured quota window, and this is neither. The enclosing provider row owns
/// the accessibility element, so this view is decorative and the row's combined
/// label speaks every figure.
struct GeminiAPICreditView: View {
    let presentation: GeminiAPICreditPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(GeminiAPICreditPresentation.title)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.onSurfaceVariant)
                Text(presentation.configuredNote)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            ForEach(presentation.figures) { figure in
                HStack(spacing: 8) {
                    Text(figure.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                    Spacer(minLength: 0)
                    Text(figure.figure)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.onSurface)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
        }
        .padding(.top, 6)
        .help(presentation.spoken)
        .accessibilityHidden(true)
    }
}
