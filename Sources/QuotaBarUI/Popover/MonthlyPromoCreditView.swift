import SwiftUI
import QuotaBarCore

/// The monthly promo credit, drawn in the same anatomy as a quota window:
/// a name and its reset on the left, a bar in the grid column, and the share
/// consumed with the countdown beneath it.
///
/// It still has no place in quota maths: `fraction` is presentation-only and
/// never reaches `consumptionFraction`, urgency, sorting or advice.
public struct MonthlyPromoCreditPresentation: Equatable, Sendable {
    /// "Usage credits" for Claude's promo, "Monthly credit" for OpenAI's
    /// API-organization grant, so the OpenAI row is not mistaken for the
    /// separate ChatGPT usage-credit count.
    let title: String
    let fraction: Double?
    let paceMarker: Double?
    /// "12d" — the reset countdown under the bar.
    let dayCountdown: String?
    /// "Resets in 12 days" — the second line beside the name.
    let resetText: String?
    /// "100%" — the share used, where the window cells put their figure.
    let percentText: String?
    let spoken: String
    let barMetrics: DualBarMetrics
    var isExhausted: Bool { fraction.map { $0 >= QuotaSnapshot.exhaustionThreshold } ?? false }

    init(entry: APICreditEntry, now: Date, isStale: Bool, calendar: Calendar = .current) {
        title = entry.vendorId == .openai ? "Monthly credit" : "Usage credits"
        if case .currency(let balance, let limit?, _, _) = entry.metric,
           limit > 0, balance >= 0 {
            let used = NSDecimalNumber(decimal: (limit - balance) / limit).doubleValue
            fraction = used.isFinite ? min(1, max(0, used)) : nil
        } else {
            fraction = nil
        }
        percentText = fraction.map { "\(Int(($0 * 100).rounded()))%" }

        let periodLength: TimeInterval?
        // A grant that states its own start has a measured period; the exact
        // span wins over the calendar-month approximation. Claude's promo
        // publishes only the end, so it keeps that fallback.
        let exactLength = entry.monthlyPeriodStart.flatMap { start -> TimeInterval? in
            guard let end = entry.monthlyPeriodEnd, end > start else { return nil }
            let length = end.timeIntervalSince(start)
            return length > 0 ? length : nil
        }
        if let end = entry.monthlyPeriodEnd,
           let length = exactLength
            ?? DualBarMetrics.monthWindowLength(endingAt: end, calendar: calendar) {
            periodLength = length
            // The confirmed recurring period is a calendar month, not 30 days.
            // Never roll a passed end forward and pretend a refill was read.
            let days = max(0, end.timeIntervalSince(now) / 86_400).rounded(.up)
            if days.isFinite && days < Double(Int.max) {
                let count = Int(days)
                dayCountdown = "\(count)d"
                resetText = "Resets in \(count) day\(count == 1 ? "" : "s")"
            } else {
                dayCountdown = nil
                resetText = nil
            }
            let elapsed: TimeInterval
            if let start = entry.monthlyPeriodStart {
                elapsed = now.timeIntervalSince(start) / length
            } else {
                elapsed = 1 - end.timeIntervalSince(now) / length
            }
            // This credit keeps its even-use marker when fully used, as requested.
            paceMarker = fraction != nil && elapsed > 0 && elapsed < 1 ? elapsed : nil
        } else {
            periodLength = nil
            paceMarker = nil
            dayCountdown = nil
            resetText = nil
        }
        var parts = [title, percentText.map { "\($0) used" } ?? "no reading"]
        if entry.vendorId == .openai,
           case .currency(let balance, let limit?, _, let code) = entry.metric {
            parts.append("\(MoneyText.format(balance, code: code)) of "
                + "\(MoneyText.format(limit, code: code)) remaining")
        }
        if entry.vendorId == .openai, let detail = entry.detail { parts.append(detail) }
        if let resetText { parts.append(resetText.lowercased()) }
        if let paceMarker { parts.append("even-use marker at \(Int((paceMarker * 100).rounded())) percent of the month") }
        if isStale { parts.append("stale, the last poll failed") }
        spoken = parts.joined(separator: ", ")
        barMetrics = DualBarMetrics(primaryFraction: fraction, expectedPaceFraction: paceMarker,
            label: "MO", resetsAt: entry.monthlyPeriodEnd, windowLength: periodLength)
    }
}

struct MonthlyPromoCreditView: View {
    let presentation: MonthlyPromoCreditPresentation

    private var color: Color {
        DualBarProgressView.stateColor(for: presentation.barMetrics, presentedPaceMarker: presentation.paceMarker)
    }

    nonisolated static func figureColor(for presentation: MonthlyPromoCreditPresentation) -> Color {
        DualBarProgressView.stateColor(
            for: presentation.barMetrics, presentedPaceMarker: presentation.paceMarker)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.rowSpacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .lineLimit(1)
                // Title only; the reset countdown lives on the right.
            }
            .frame(width: Theme.nameColumnWidth, alignment: .leading)

            VStack(spacing: 4) {
                if presentation.fraction != nil {
                    DualBarProgressView(metrics: presentation.barMetrics, showsLabel: false,
                        presentedPaceMarker: presentation.paceMarker)
                }
                HStack(spacing: 2) {
                    if let percent = presentation.percentText {
                        Text(percent)
                            .font(Theme.Typography.gridPercent)
                            .foregroundStyle(Self.figureColor(for: presentation))
                    }
                    Spacer(minLength: 0)
                    if let countdown = presentation.dayCountdown {
                        Text(countdown)
                            .font(Theme.Typography.gridReset)
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.78))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
        .foregroundStyle(Theme.onSurfaceVariant)
        .help(presentation.spoken)
        // The enclosing provider row speaks this alongside its quota windows.
        .accessibilityHidden(true)
    }
}
