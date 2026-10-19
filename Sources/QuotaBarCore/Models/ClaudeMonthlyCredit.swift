import Foundation

/// A linked Console grant entitlement, never a remaining balance or spend cap.
/// Kept outside APICreditEntry so it cannot be recorded as a balance series.
public struct ClaudeMonthlyCredit: Sendable, Equatable {
    public let amountUSD: Decimal
    public let nextGrantAt: Date?
    public let measuredAt: Date
    public var refreshFailed = false

    public static func decode(_ data: Data, now: Date) throws -> Self? {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.status == "linked", payload.grants_held_reason != "program_ended",
              let text = payload.monthly_credit_usd,
              text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              amount >= 0 else { return nil }
        return Self(amountUSD: amount,
            nextGrantAt: (payload.grant_due == true ? nil : payload.next_grant_at).flatMap(Self.parseDate),
            measuredAt: now)
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private struct Payload: Decodable {
        let status: String?
        let monthly_credit_usd: String?
        let next_grant_at: String?
        let grant_due: Bool?
        let grants_held_reason: String?
    }

    public var line: String { "Monthly API credit: \(MoneyText.format(amountUSD, code: "USD")) per month" }
    public func detail(now: Date) -> String? {
        var parts: [String] = []
        if let nextGrantAt {
            parts.append("Next credit \(nextGrantAt.formatted(date: .abbreviated, time: .omitted))")
        }
        if refreshFailed { parts.append("Stale monthly credit reading") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
