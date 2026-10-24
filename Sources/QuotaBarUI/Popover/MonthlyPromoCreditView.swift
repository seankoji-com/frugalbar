import SwiftUI
import QuotaBarCore

/// A credit's own usage and calendar month, never a quota snapshot or urgency.
public struct MonthlyPromoCreditPresentation: Equatable, Sendable {
    let figure: String
    let fraction: Double?
    let paceMarker: Double?
    let dayCountdown: String?
    let spoken: String
    let barMetrics: DualBarMetrics
    var isExhausted: Bool { fraction.map { $0 >= QuotaSnapshot.exhaustionThreshold } ?? false }

    init(entry: APICreditEntry, now: Date, isStale: Bool, calendar: Calendar = .current) {
        figure = APICreditEntryPresentation(entry: entry).figure + " left"
        if case .currency(let balance, let limit?, _, _) = entry.metric,
           limit > 0, balance >= 0 {
            let used = NSDecimalNumber(decimal: (limit - balance) / limit).doubleValue
            fraction = used.isFinite ? min(1, max(0, used)) : nil
        } else {
            fraction = nil
        }

        let periodLength: TimeInterval?
        if let end = entry.monthlyPeriodEnd,
           let length = DualBarMetrics.monthWindowLength(endingAt: end, calendar: calendar) {
            periodLength = length
            // The confirmed recurring period is a calendar month, not 30 days.
            // Never roll a passed end forward and pretend a refill was read.
            let days = max(0, end.timeIntervalSince(now) / 86_400).rounded(.up)
            dayCountdown = days.isFinite && days < Double(Int.max) ? "\(Int(days))d" : nil
            let elapsed = 1 - end.timeIntervalSince(now) / length
            // This credit keeps its even-use marker when fully used, as requested.
            paceMarker = fraction != nil && elapsed > 0 && elapsed < 1 ? elapsed : nil
        } else {
            periodLength = nil
            paceMarker = nil
            dayCountdown = nil
        }
        var parts = ["Monthly promo credit", figure]
        if let dayCountdown { parts.append("subscription month ends in \(dayCountdown.dropLast()) days") }
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
        presentation.isExhausted ? Theme.error : DualBarProgressView.stateColor(
            for: presentation.barMetrics, presentedPaceMarker: presentation.paceMarker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Promo credit").font(Theme.Typography.subtitle)
                Spacer(minLength: 0)
                Text("Monthly").font(Theme.Typography.token).foregroundStyle(Theme.outline)
            }
            if let fraction = presentation.fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.08))
                            if fraction > 0 {
                                Rectangle().fill(color)
                                    .frame(width: max(3, fraction * geometry.size.width))
                            }
                        }
                        .frame(height: DualBarProgressView.barHeight)
                        .clipShape(Capsule())
                        if let pace = presentation.paceMarker {
                            Capsule().fill(Color.white.opacity(0.9))
                                .frame(width: DualBarProgressView.tickWidth, height: DualBarProgressView.tickHeight)
                                .shadow(color: .black.opacity(0.6), radius: 1.5)
                                .position(x: min(max(pace * geometry.size.width, 1), geometry.size.width - 1),
                                          y: geometry.size.height / 2)
                        }
                    }
                    .frame(height: geometry.size.height)
                }
                .frame(height: DualBarProgressView.tickHeight)
            }
            HStack {
                Text(presentation.figure).font(Theme.Typography.chip)
                    .foregroundStyle(Self.figureColor(for: presentation))
                Spacer(minLength: 0)
                if let countdown = presentation.dayCountdown {
                    Text(countdown).font(Theme.Typography.gridReset).foregroundStyle(Theme.outline)
                }
            }
        }
        .foregroundStyle(Theme.onSurfaceVariant)
        .padding(.top, 8)
        .help(presentation.spoken)
        // The enclosing provider row speaks this alongside its quota windows.
        .accessibilityHidden(true)
    }
}
