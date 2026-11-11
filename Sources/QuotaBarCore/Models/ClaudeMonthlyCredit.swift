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
            // Sibling fields keep the plain decoder's behaviour: a wrong type
            // is a failed read, which the session reports as stale, not the
            // vendor saying "no entitlement".
            status = try c.decodeIfPresent(String.self, forKey: .status)
            nextGrantAt = try c.decodeIfPresent(String.self, forKey: .nextGrantAt)
            grantDue = try c.decodeIfPresent(Bool.self, forKey: .grantDue)
            grantsHeldReason = try c.decodeIfPresent(String.self, forKey: .grantsHeldReason)
            monthlyCreditUSD = try Self.amount(c, .monthlyCreditUSD)
        }

        /// An exact non-negative dollar figure from a numeric string or a JSON
        /// number. A string that is not a plain decimal (an empty string, an
        /// exponent form, `NaN`, a negative) yields no entitlement, matching
        /// the earlier decoder. A value of any other type is a decode failure,
        /// not an entitlement the vendor withheld.
        private static func amount(
            _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) throws -> Decimal? {
            guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
            if let text = try? c.decodeIfPresent(String.self, forKey: key) {
                return decimal(from: text)
            }
            if let amount = try? c.decodeIfPresent(Decimal.self, forKey: key) {
                guard !amount.isNaN, amount >= 0 else { return nil }
                return amount
            }
            throw DecodingError.typeMismatch(
                Decimal.self,
                DecodingError.Context(
                    codingPath: c.codingPath + [key],
                    debugDescription: "monthly_credit_usd is neither a number nor a numeric string"))
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

    /// The Console organisation's monthly API-credit entitlement, in the
    /// amount-first form the row uses: "$200.00 monthly credit". It belongs to
    /// the linked organisation, not to the subscription's promo/usage-credit
    /// pool drawn beside it.
    public var line: String { "\(MoneyText.format(amountUSD, code: "USD")) monthly credit" }
    public func detail() -> String? {
        var parts: [String] = []
        if let nextGrantAt {
            parts.append("Next credit \(nextGrantAt.formatted(date: .abbreviated, time: .omitted))")
        }
        if refreshFailed { parts.append("Stale monthly credit reading") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
