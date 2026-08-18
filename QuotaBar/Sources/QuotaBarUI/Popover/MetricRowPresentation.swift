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

    public init(snapshot: QuotaSnapshot, now: Date = Date()) {
        self.name = snapshot.displayName
        self.fraction = snapshot.consumptionFraction
        self.isMeasured = snapshot.status.confidence == .measured
        self.urgency = snapshot.status.urgency

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
            limit.map { "\(currency(balance, code)) of \(currency($0, code))" }
                ?? currency(spent ?? balance, code)
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
            limit.map { "\(currency(balance, code)) of \(currency($0, code)) remaining" }
                ?? "\(currency(spent ?? balance, code)) spent"
        case .subscription(let tier, _):
            tier
        }
    }

    static func currency(_ value: Decimal, _ code: String) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(2)))
    }
}
