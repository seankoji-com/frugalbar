import Foundation
import QuotaBarCore

/// Pure presentation logic for one metric row.
///
/// Extracted from the view so it can be tested for real. Assertions against a
/// `View` value can only re-read the data they were handed — they cannot tell
/// you what the row would actually display, which is how a previous revision
/// shipped "UI tests" that would have passed against an `EmptyView` body.
public struct MetricRowPresentation: Equatable, Sendable {

    public let name: String
    /// nil means draw no bar: there is no denominator.
    public let fraction: Double?
    public let valueLabel: String
    public let resetLabel: String
    public let isMeasured: Bool
    public let urgency: Urgency
    public let accessibilityLabel: String
    /// A window the vendor reports as fully spent. Deliberately narrower than
    /// `.critical` urgency, which also covers "nearly gone" — the struck-through
    /// logo is reserved for nothing-left-at-all.
    public let isExhausted: Bool
    /// What the vendor published about when the exhausted window reopens, e.g.
    /// "Resets on 1st of month". nil when it published nothing, in which case
    /// the row keeps showing the plan name rather than inventing a date.
    public let exhaustedResetText: String?

    /// A bar is only exhausted at the top of its range. `>= 1` would miss the
    /// floating-point residue of a percentage that arrived as 100.
    static let exhaustionThreshold = 0.999

    public init(snapshot: QuotaSnapshot, now: Date = Date()) {
        self.name = snapshot.displayName
        self.fraction = snapshot.consumptionFraction
        self.isMeasured = snapshot.status.confidence == .measured
        self.urgency = snapshot.status.urgency

        // An unreadable provider has no bars, so this reads false there — a
        // quota we could not fetch is not a quota we know is spent.
        let spentBar = snapshot.bars.first { $0.primaryFractionOrUnmeasured >= Self.exhaustionThreshold }
        self.isExhausted = spentBar != nil
        self.exhaustedResetText = spentBar?.resetText

        if let reason = snapshot.status.unavailableReason {
            self.valueLabel = reason.headline
            self.resetLabel = "—"
            self.accessibilityLabel =
                "\(snapshot.displayName), \(reason.headline), \(reason.remedy)"
            return
        }

        self.valueLabel = Self.value(for: snapshot.metric)
        self.resetLabel = ResetCountdownBadge.format(snapshot.resetsAt, now: now)

        var parts = [snapshot.displayName, Self.spoken(for: snapshot.metric)]
        if isExhausted {
            // Said outright rather than left to "critically low", which a
            // screen reader user cannot distinguish from 5% remaining.
            parts.append("exhausted")
            if let exhaustedResetText {
                parts.append(exhaustedResetText)
            }
        }
        switch snapshot.status.urgency {
        case .none:     break
        case .warning:  parts.append("running low")
        case .critical: parts.append("critically low")
        }
        if snapshot.resetsAt != nil {
            parts.append(ResetCountdownBadge.description(snapshot.resetsAt, now: now))
        }
        self.accessibilityLabel = parts.joined(separator: ", ")
    }

    // MARK: - Formatting

    static func value(for metric: MetricType) -> String {
        switch metric {
        case .percentage(let used, _):
            "\(Int((used * 100).rounded()))%"
        case .count(let remaining, let limit, _):
            "\(remaining.formatted())/\(limit.formatted())"
        case .currency(let balance, let limit, let spent, let code):
            // An uncapped key has no "left of" to show. Falling back to
            // `spent ?? balance` printed the *balance* under a spend label —
            // real money, described as the wrong thing.
            if let limit {
                "\(currency(balance, code)) left of \(currency(limit, code))"
            } else if let spent {
                "\(currency(spent, code)) spent"
            } else {
                currency(balance, code)
            }
        case .subscription(let tierName, _):
            tierName
        }
    }

    static func spoken(for metric: MetricType) -> String {
        switch metric {
        case .percentage(let used, _):
            "\(Int((used * 100).rounded())) percent used"
        case .count(let remaining, let limit, let unit):
            "\(remaining) of \(limit) \(unit) remaining"
        case .currency(let balance, let limit, let spent, let code):
            if let limit {
                "\(currency(balance, code)) of \(currency(limit, code)) remaining"
            } else if let spent {
                "\(currency(spent, code)) spent"
            } else {
                "\(currency(balance, code)) balance"
            }
        case .subscription(let tier, _):
            tier
        }
    }

    static func currency(_ value: Decimal, _ code: String) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(2)))
    }
}
