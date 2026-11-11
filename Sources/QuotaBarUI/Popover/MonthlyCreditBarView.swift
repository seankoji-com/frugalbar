import SwiftUI
import QuotaBarCore

/// The linked Console organisation's monthly credit, drawn as the monthly
/// meter the row now uses.
///
/// The fill is **billing-cycle progress**, not API spend: the linked payload
/// publishes the monthly amount and the next grant date, but no used figure.
/// Filling it with a spend number would invent one, so the bar measures the
/// calendar month ending at `nextGrantAt` and the foot says "elapsed". It is
/// deliberately outside quota maths — no urgency, sorting, advice, history or
/// menu-bar icon reads it — and uses the informational `Theme.primary` rather
/// than the quota state colours.
public struct MonthlyCreditBarPresentation: Equatable, Sendable {
    public let title: String
    /// Elapsed share of the billing month, 0…1. Nil when the next grant date
    /// is not published, or when that date is outside the current cycle; then
    /// no bar, percentage or countdown is drawn.
    public let fraction: Double?
    public let percentText: String?
    /// The compact countdown, e.g. "4d".
    public let countdown: String?
    public let isStale: Bool
    public let spoken: String

    public init(credit: ClaudeMonthlyCredit, now: Date, calendar: Calendar = .current) {
        self.title = credit.line
        self.isStale = credit.refreshFailed

        var elapsed: Double?
        var countdown: String?
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
            }
        }
        self.fraction = elapsed
        self.percentText = elapsed.map { "\(Int(($0 * 100).rounded()))%" }
        self.countdown = countdown

        var parts = [title]
        if let percentText = self.percentText {
            parts.append("\(percentText) of the billing month elapsed")
        }
        if let end = credit.nextGrantAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "d MMMM yyyy"
            parts.append("next credit \(formatter.string(from: end))")
        }
        if credit.refreshFailed {
            parts.append("stale monthly credit reading")
        }
        self.spoken = parts.joined(separator: ", ")
    }
}

struct MonthlyCreditBarView: View {
    let presentation: MonthlyCreditBarPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if presentation.isStale {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Stale")
                    }
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                }
            }
            .frame(width: 116, alignment: .leading)

            VStack(spacing: 4) {
                if let fraction = presentation.fraction {
                    MonthlyCycleBar(fraction: fraction)
                }
                HStack(spacing: 2) {
                    if presentation.percentText != nil {
                        Text("MO")
                            .font(Theme.Typography.token)
                            .tracking(Theme.Tracking.token)
                            .foregroundStyle(Theme.onSurfaceVariant)
                            .padding(.trailing, 4)
                    }
                    if let percent = presentation.percentText {
                        Text(percent)
                            .font(Theme.Typography.gridPercent)
                            .foregroundStyle(Theme.primary)
                        Text("elapsed")
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.78))
                    }
                    Spacer(minLength: 0)
                    if let countdown = presentation.countdown {
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
        .padding(.leading, Theme.rowAvatarSize + Theme.rowSpacing)
        .help(presentation.spoken)
        // The enclosing provider row speaks this alongside its quota figures.
        .accessibilityHidden(true)
    }
}

/// A track and one informational fill. No pace tick and no state colour: the
/// fill is time through the billing month, not a quota reading, so there is no
/// "ahead of pace" verdict to draw.
private struct MonthlyCycleBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Theme.primary)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: DualBarProgressView.barHeight)
    }
}
