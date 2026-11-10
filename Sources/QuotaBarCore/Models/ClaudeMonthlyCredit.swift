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
        guard payload.status == "linked", payload.grantsHeldReason != "program_ended",
              let amount = payload.monthlyCreditUSD, amount >= 0 else { return nil }
        return Self(amountUSD: amount,
            nextGrantAt: (payload.grantDue == true ? nil : payload.nextGrantAt).flatMap(Self.parseDate),
            measuredAt: now)
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private struct Payload: Decodable {
        let status: String?
        /// The billing page's own client reads this with `Number(value)`, so
        /// the field is accepted as either a JSON number or a numeric string.
        /// Decoding only `String?` silently produced no entitlement for a
        /// payload that published the figure numerically.
        let monthlyCreditUSD: Decimal?
        let nextGrantAt: String?
        let grantDue: Bool?
        let grantsHeldReason: String?

        enum CodingKeys: String, CodingKey {
            case status
            case monthlyCreditUSD = "monthly_credit_usd"
            case nextGrantAt = "next_grant_at"
            case grantDue = "grant_due"
            case grantsHeldReason = "grants_held_reason"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            nextGrantAt = try? c.decodeIfPresent(String.self, forKey: .nextGrantAt)
            grantDue = try? c.decodeIfPresent(Bool.self, forKey: .grantDue)
            grantsHeldReason = try? c.decodeIfPresent(String.self, forKey: .grantsHeldReason)
            monthlyCreditUSD = Self.amount(c, .monthlyCreditUSD)
        }

        /// An exact non-negative dollar figure from a numeric string or a JSON
        /// number. Anything else — a boolean, a negative, an exponent form, a
        /// non-finite value — is "not published", never 0.
        private static func amount(
            _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> Decimal? {
            if let text = try? c.decodeIfPresent(String.self, forKey: key) {
                return decimal(from: text)
            }
            // A JSON number. A boolean does not decode as `Decimal`, so the
            // wrong type stays "not published" rather than becoming 1.
            if let amount = try? c.decodeIfPresent(Decimal.self, forKey: key) {
                guard !amount.isNaN, amount >= 0 else { return nil }
                return amount
            }
            return nil
        }

        private static func decimal(from text: String) -> Decimal? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(
                of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                let amount = Decimal(
                    string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
                !amount.isNaN, amount >= 0
            else { return nil }
            return amount
        }
    }

    /// The Console organisation's monthly API-credit entitlement. Named "Org"
    /// because it belongs to the linked organisation, not to the subscription's
    /// promo/usage-credit pool drawn beside it.
    public var line: String { "Org monthly credit: \(MoneyText.format(amountUSD, code: "USD")) per month" }
    public func detail() -> String? {
        var parts: [String] = []
        if let nextGrantAt {
            parts.append("Next credit \(nextGrantAt.formatted(date: .abbreviated, time: .omitted))")
        }
        if refreshFailed { parts.append("Stale monthly credit reading") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
