import Foundation

/// The OpenAI API organization's recurring monthly credit, as published on the
/// Platform billing page.
///
/// This is the `$200 per monthly billing period` API-credits benefit a Pro 200
/// subscription links to an API organization, not the ChatGPT/Codex usage
/// credit count (`openai.api-credits`) and not a quota. It lives in its own
/// snapshot field rather than `apiCredits`, so it is neither quota maths nor a
/// prepaid balance-history series; `entry` is only the row's presentation.
///
/// The Platform's `credit_grants` summary also totals purchased credits, so
/// `total_available` is deliberately never used: a purchased pool is different
/// money with a different expiry. The row is built from one grant's own
/// published `grant_amount` and `used_amount`, only when the grant publishes
/// both ends of a monthly span and either expires at the ChatGPT subscription's
/// published cycle end or carries the vendor's subscription-benefit label.
/// A response that does not expose those facts yields no entry rather than a
/// derived figure, and more than one matching grant is refused as ambiguous.
public struct OpenAIMonthlyCredit: Sendable, Equatable {
    public let grantUSD: Decimal
    public let remainingUSD: Decimal
    public let periodStart: Date?
    public let periodEnd: Date?
    public let measuredAt: Date
    public var refreshFailed = false

    /// A grant that expired before the next renewal is not this period's
    /// credit. A monthly grant's own span is at most this; annual Business
    /// grants (a year at once) are deliberately outside the monthly row.
    static let maximumMonthlyPeriod: TimeInterval = 45 * 86_400

    public init(grantUSD: Decimal, remainingUSD: Decimal, periodStart: Date?,
                periodEnd: Date?, measuredAt: Date, refreshFailed: Bool = false) {
        self.grantUSD = grantUSD
        self.remainingUSD = remainingUSD
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.measuredAt = measuredAt
        self.refreshFailed = refreshFailed
    }

    public var entry: APICreditEntry {
        APICreditEntry(
            id: "openai.monthly-credit",
            vendorId: .openai,
            label: "Monthly credit",
            metric: .currency(balance: remainingUSD, limit: grantUSD, spent: nil,
                              currencyCode: "USD"),
            currencyBasis: .prepaidCredit,
            detail: detail(),
            source: "OpenAI Platform billing · credit grants",
            monthlyPeriodEnd: periodEnd,
            monthlyPeriodStart: periodStart
        )
    }

    public func detail() -> String? {
        var parts = ["\(MoneyText.format(grantUSD, code: "USD")) monthly credit"]
        if refreshFailed { parts.append("Stale monthly credit reading") }
        return parts.joined(separator: " · ")
    }

    /// Reads the Platform's credit-grant summary. `expectedPeriodEnd` is the
    /// ChatGPT subscription's published cycle end; the API-credits grant
    /// expires there. When it is unavailable, only a grant the vendor labelled
    /// as the subscription benefit is eligible.
    public static func decode(_ data: Data, now: Date,
                              expectedPeriodEnd: Date? = nil) throws -> Self? {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let summary = summaryObject(root) else { return nil }
        let grants = grantObjects(summary).compactMap { Grant(json: $0) }
        let candidates = grants.compactMap {
            $0.monthlyCredit(now: now, expectedPeriodEnd: expectedPeriodEnd)
        }
        // One grant only. A second matching grant could be a prorated extra or
        // a purchased pool with a short expiry, and the summary does not say
        // which one supersedes the other; summing or choosing between them
        // would assert a figure nobody published.
        guard candidates.count == 1, let chosen = candidates.first else { return nil }
        return Self(
            grantUSD: chosen.grantAmount,
            remainingUSD: chosen.remaining,
            periodStart: chosen.effectiveAt,
            periodEnd: chosen.expiresAt,
            measuredAt: now
        )
    }

    // MARK: - Shape tolerance

    /// The summary is normally the root object; accept the one-object wrappers
    /// the Platform has used without inventing a figure from anything else.
    private static func summaryObject(_ root: Any) -> [String: Any]? {
        guard let root = root as? [String: Any] else { return nil }
        for key in ["credit_summary", "data", "summary"] {
            if let nested = root[key] as? [String: Any],
               nested["grants"] != nil || nested["total_available"] != nil
                || nested["total_granted"] != nil {
                return nested
            }
        }
        if root["grants"] != nil || root["total_available"] != nil
            || root["total_granted"] != nil {
            return root
        }
        return nil
    }

    private static func grantObjects(_ summary: [String: Any]) -> [[String: Any]] {
        if let grants = summary["grants"] as? [String: Any],
           let data = grants["data"] as? [[String: Any]] {
            return data
        }
        if let data = summary["grants"] as? [[String: Any]] { return data }
        return []
    }

    private struct Grant {
        let grantAmount: Decimal
        let remaining: Decimal
        let effectiveAt: Date?
        let expiresAt: Date?
        let hasPromotionalLabel: Bool

        /// A current grant whose own published span is monthly. With the
        /// subscription's cycle end, the grant must expire at that end; without
        /// it, the vendor must have labelled the grant as the subscription
        /// benefit. A missing start is not a monthly period: remaining
        /// lifetime cannot say how long the grant originally ran.
        func monthlyCredit(now: Date, expectedPeriodEnd: Date?) -> Grant? {
            guard let effectiveAt, let expiresAt,
                  effectiveAt <= now, expiresAt > now else { return nil }
            let span = expiresAt.timeIntervalSince(effectiveAt)
            guard span.isFinite, span > 0, span <= OpenAIMonthlyCredit.maximumMonthlyPeriod
            else { return nil }
            if let expectedPeriodEnd {
                // The benefit grant expires at the end of the ChatGPT billing
                // cycle. Match either the published renewal or expiry instant;
                // the two can differ by hours within the same cycle.
                guard abs(expiresAt.timeIntervalSince(expectedPeriodEnd)) <= 12 * 3600
                else { return nil }
            } else {
                guard hasPromotionalLabel else { return nil }
            }
            return self
        }

        init?(json: [String: Any]) {
            guard let grant = Self.decimal(json, keys: ["grant_amount", "amount", "granted_amount"]),
                  grant > 0, !grant.isNaN else { return nil }
            let used = Self.decimal(json, keys: ["used_amount", "used"])
            let publishedRemaining = Self.decimal(json,
                keys: ["remaining_amount", "remaining", "available_amount", "available"])
            let remaining: Decimal
            if let used {
                guard used >= 0, !used.isNaN else { return nil }
                remaining = Swift.max(grant - used, 0)
            } else if let publishedRemaining {
                guard publishedRemaining >= 0, !publishedRemaining.isNaN else { return nil }
                remaining = publishedRemaining
            } else {
                return nil
            }
            // A remaining figure larger than its own grant is not a reading of
            // this grant; refuse it rather than print a balance nobody sent.
            guard remaining <= grant else { return nil }
            self.grantAmount = grant
            self.remaining = remaining
            // `created_at` is not an effective start: it says when the row was
            // created, not when the grant's allowance began.
            self.effectiveAt = Self.date(json,
                keys: ["effective_at", "effective", "starts_at", "start_at"])
            self.expiresAt = Self.date(json,
                keys: ["expires_at", "expires", "expiration", "end_at"])
            let labels = ["grant_type", "source", "description", "name", "type"]
                .compactMap { json[$0] as? String }
                .joined(separator: " ")
                .lowercased()
            self.hasPromotionalLabel = ["promo", "chatgpt", "subscription", "benefit"]
                .contains { labels.contains($0) }
        }

        private static func decimal(_ json: [String: Any], keys: [String]) -> Decimal? {
            for key in keys {
                if let value = json[key] as? NSNumber {
                    // JSONSerialization backs a fractional JSON number with a
                    // Double. Go through its shortest decimal text so 12.34
                    // stays 12.34 instead of a long binary expansion.
                    let isFloat = String(cString: value.objCType) == "d"
                        || String(cString: value.objCType) == "f"
                    let decimal = isFloat
                        ? Decimal(string: NSDecimalNumber(value: value.doubleValue).stringValue,
                                  locale: Locale(identifier: "en_US_POSIX"))
                        : value.decimalValue
                    if let decimal, !decimal.isNaN { return decimal }
                }
                if let text = json[key] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
                       !value.isNaN {
                        return value
                    }
                }
            }
            return nil
        }

        private static func date(_ json: [String: Any], keys: [String]) -> Date? {
            for key in keys {
                if let value = json[key] as? NSNumber {
                    let seconds = value.doubleValue
                    guard seconds.isFinite, seconds > 0 else { continue }
                    // The documented shape is Unix seconds. Accept a
                    // millisecond stamp only when its magnitude says so.
                    return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
                }
                if let text = json[key] as? String {
                    if let seconds = TimeInterval(text.trimmingCharacters(in: .whitespaces)),
                       seconds.isFinite, seconds > 0 {
                        return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
                    }
                    let fractional = ISO8601DateFormatter()
                    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = fractional.date(from: text) { return date }
                    if let date = ISO8601DateFormatter().date(from: text) { return date }
                }
            }
            return nil
        }
    }
}
