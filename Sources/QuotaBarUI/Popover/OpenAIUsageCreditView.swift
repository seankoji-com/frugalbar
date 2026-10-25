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
}

/// A one-time grant uses the account holder's original allowance and the
/// vendor's exact remaining count. It has no pace marker or quota urgency.
public struct OpenAIUsageCreditPresentation: Equatable, Sendable {
    let fraction: Double
    let percentText: String
    let totalText: String
    let expiryText: String
    let spoken: String

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
        var parts = ["Usage credits", percentText, "\(totalText) credits", expiryText,
                     "Original allowance and expiry entered by you"]
        if isStale { parts.append("stale, the last poll failed") }
        spoken = parts.joined(separator: ", ")
    }
}

struct OpenAIUsageCreditView: View {
    let presentation: OpenAIUsageCreditPresentation

    var body: some View {
        HStack(alignment: .top, spacing: Theme.rowSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Usage credits")
                    .font(Theme.Typography.subtitle)
                Text(presentation.expiryText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: Theme.nameColumnWidth, alignment: .leading)

            VStack(spacing: 5) {
                GeometryReader { geometry in
                    Capsule().fill(Theme.surfaceContainerHighest)
                    Capsule().fill(Theme.primary)
                        .frame(width: geometry.size.width * presentation.fraction)
                }
                .frame(height: 6)
                HStack(spacing: 2) {
                    Text(presentation.percentText)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Spacer(minLength: 0)
                    Text(presentation.totalText)
                        .font(.system(size: 10))
                }
                .lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(.top, 3)
        }
        .foregroundStyle(Theme.onSurfaceVariant)
        .padding(.top, 8)
        .help(presentation.spoken)
        .accessibilityHidden(true)
    }
}

struct ResetTicketsView: View {
    let credits: MetricRowPresentation.ResetCredits

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<credits.tickets, id: \.self) { index in
                HStack(spacing: 5) {
                    GoldenTicketView(index: index)
                        .help(credits.expiryText(at: index, now: credits.now))
                    Text(credits.expiryCountdown(at: index))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            if credits.overflow > 0 {
                Text("+\(credits.overflow)")
                    .font(Theme.Typography.subtitle)
                    .help("\(credits.overflow) more banked reset credits")
            }
        }
        .accessibilityHidden(true)
    }
}
