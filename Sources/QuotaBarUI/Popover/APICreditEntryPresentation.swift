import Foundation
import QuotaBarCore

/// Pure presentation for one prepaid API credit entry.
///
/// Extracted so the entry's wording can be asserted for real rather than
/// re-read off a `View` value, the same reason `MetricRowPresentation` exists.
///
/// The balance label used by both standalone credits and subscription credits.
/// MonthlyPromoCreditPresentation adds a bar only with the promo's own limit.
public struct APICreditEntryPresentation: Equatable, Sendable {

    /// The entry's own name, vendor first: "OpenAI API credits".
    public let title: String
    /// The figure in the vendor's own unit — never reformatted across units.
    /// "62,500 credits" stays credits; "$183.42" stays money.
    public let figure: String
    /// The vendor's supporting note, when it published one ("$200.00 monthly
    /// limit", "Expires 15 Nov 2026"). nil rather than an inferred one.
    public let detail: String?
    /// Where the figure came from, for the row's tooltip.
    public let source: String?
    /// The whole entry in words, for a screen reader.
    public let spoken: String

    /// The entry in words when the vendor's newest poll failed and so this
    /// figure is carried over from an earlier one.
    ///
    /// The row speaks its figure and its note in one breath, so a reader has no
    /// way to notice the figure is not current — the same reason
    /// `MetricRowPresentation.staleSpoken` exists. Passed in rather than read
    /// from the entry, because staleness is the vendor poll's, not the entry's:
    /// every entry a failed poll retained is equally old.
    public func spoken(stale: Bool) -> String {
        stale ? "\(spoken), stale, the last poll failed" : spoken
    }

    public init(entry: APICreditEntry) {
        self.title = "\(entry.vendorId.displayName) \(entry.label)"
        self.figure = Self.figure(for: entry.metric)
        self.detail = entry.detail
        self.source = entry.source
        // `MetricRowPresentation.spoken` is the one spoken form: it words a
        // credit count as a count and money through `MoneyText.format`, the rule
        // every row now prints with, so this card's speech cannot drift from the
        // row it was read from. This type used to word money itself, because the
        // shared form consulted the process locale there and this card did not —
        // a divergence `MetricRowPresentation.currency` no longer has.
        var parts = [title, MetricRowPresentation.spoken(for: entry.metric)]
        if let detail = entry.detail { parts.append(detail) }
        self.spoken = parts.joined(separator: ", ")
    }

    /// The figure as the vendor published it.
    static func figure(for metric: MetricType) -> String {
        switch metric {
        case .credits(let remaining, let unitName):
            remaining.map { "\(CreditText.format($0)) \(unitName)" } ?? "Unlimited"
        case .currency(let balance, _, _, let code):
            // The same rule the money rows print with, so the card's figure and
            // its own detail note ("$200.00 monthly limit") cannot disagree.
            MoneyText.format(balance, code: code)
        case .count(let remaining, let limit, let unit):
            "\(remaining.formatted())/\(limit.formatted()) \(unit)"
        case .percentage(let used, _):
            "\(Int((used * 100).rounded()))%"
        case .subscription(let tierName, _):
            tierName ?? ""
        }
    }
}
