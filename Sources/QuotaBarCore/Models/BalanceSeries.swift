import Foundation

/// The identity and unit of a balance-over-time series.
///
/// A balance series is a figure a vendor published across polls: an account
/// credit, a key's remaining spend cap, a credit pool's left figure, or a count
/// of credits the vendor meters (OpenAI's `credits.balance`). It is charted and
/// never summed: a series has no window and no fraction, so it can no more
/// reach `consumptionFraction` than an `APICreditEntry` can. Two series of one
/// account never share a line unless they share a unit — a USD balance and a CNY
/// balance are different money, and a credits count is not money at all.
public enum BalanceSeries {

    /// What a series is measured in. A series never mixes units.
    public enum Unit: Sendable, Equatable {
        case currency(code: String)
        /// A count the vendor meters in its own unit word, e.g. OpenAI's
        /// "credits". Never money, never converted.
        case credits(name: String)

        /// The stable text the unit is keyed and stored by. Never localised.
        public var storageKey: String {
            switch self {
            case .currency(let code): "currency:\(code.uppercased())"
            case .credits(let name):  "credits:\(name)"
            }
        }

        public static func parse(storageKey: String) -> Unit? {
            if storageKey.hasPrefix("currency:") {
                return .currency(code: String(storageKey.dropFirst("currency:".count)))
            }
            if storageKey.hasPrefix("credits:") {
                return .credits(name: String(storageKey.dropFirst("credits:".count)))
            }
            return nil
        }

        /// The currency code, when this is money.
        public var currencyCode: String? {
            if case .currency(let code) = self { return code }
            return nil
        }
    }

    /// One figure a snapshot or credit entry contributes to history.
    public struct Series: Sendable, Equatable {
        /// `"<source>|<unit storage key>"`. Built from the facts (an instance
        /// or entry id and the unit), never a UUID or prose, so the same series
        /// is found again on the next poll and after a restart.
        public let id: String
        /// The shelf the figure belongs to — the same wording the vendor's own
        /// row prints, so a chart can never call a figure something its row
        /// does not. For a money figure this is the `CurrencyBasis` balance
        /// label; for a credit count it is the unit word.
        public let label: String
        public let unit: Unit
        /// `VendorIdentifier.rawValue`, kept for grouping and provenance.
        public let vendor: String
    }

    /// The series a snapshot's own metric contributes, or nil when that figure
    /// is not a balance: a lifetime-spend total is spend, not a balance, and an
    /// unread poll has no figure to record at all.
    public static func of(_ snapshot: QuotaSnapshot) -> Series? {
        guard snapshot.status.confidence == .measured else { return nil }
        return series(
            source: snapshot.id,
            vendor: snapshot.vendorId.rawValue,
            metric: snapshot.metric,
            basis: snapshot.currencyBasis
        )
    }

    /// The series a prepaid credit entry contributes. The entry carries a
    /// figure in the same vocabulary a snapshot's metric does, so the same
    /// extraction applies.
    public static func of(_ entry: APICreditEntry) -> Series? {
        series(
            source: entry.id,
            vendor: entry.vendorId.rawValue,
            metric: entry.metric,
            basis: entry.currencyBasis
        )
    }

    static func series(
        source: String, vendor: String, metric: MetricType, basis: CurrencyBasis?
    ) -> Series? {
        switch metric {
        case .currency(_, _, _, let code):
            // A cumulative spend total is not a balance. Charting it on the
            // same axis as a real balance would draw an ever-rising line under
            // a "balance history" heading — the wrong-label defect again. It is
            // left out entirely rather than relabelled.
            if basis == .lifetimeSpend { return nil }
            let unit = Unit.currency(code: code)
            return Series(
                id: id(source: source, unit: unit),
                label: basis?.balanceLabel ?? "Balance:",
                unit: unit, vendor: vendor
            )
        case .credits(let remaining, let name):
            // Unlimited is a statement, not a figure: nothing to chart.
            guard remaining != nil else { return nil }
            let unit = Unit.credits(name: name)
            return Series(id: id(source: source, unit: unit), label: name, unit: unit, vendor: vendor)
        default:
            return nil
        }
    }

    /// The series id for `source`'s figure in `unit`.
    public static func id(source: String, unit: Unit) -> String {
        "\(source)|\(unit.storageKey)"
    }

    /// Every series id a batch of snapshots contributes — each snapshot's own
    /// balance, plus one per prepaid credit entry it carries. Used to narrow a
    /// history read to the rows the popover is about to draw.
    public static func seriesIDs(in snapshots: [QuotaSnapshot]) -> [String] {
        snapshots.flatMap { all(of: $0).map(\.id) }
    }

    /// Every balance series a snapshot can chart: its own money figure (nil for
    /// a quota-only provider), then one per prepaid credit entry it published.
    /// Order is the order the popover draws them, so the inspector's default
    /// choice matches the row the user opened.
    public static func all(of snapshot: QuotaSnapshot) -> [Series] {
        var series: [Series] = []
        if let own = of(snapshot) { series.append(own) }
        series += snapshot.apiCredits.compactMap { of($0) }
        return series
    }

    /// The numeric figure a metric contributes to a series, or nil for a metric
    /// that carries none. A `.lifetimeSpend` figure is not returned: its series
    /// is nil by `series(...)`, and this must agree so a value is never written
    /// without a series to belong to.
    public static func value(of metric: MetricType) -> Decimal? {
        switch metric {
        case .currency(let balance, _, _, _): balance
        case .credits(let remaining, _): remaining.map { Decimal($0) }
        default: nil
        }
    }
}

/// One recorded figure in a balance series, as its poll received it.
///
/// A point is an observation, never an interpolation: it holds exactly the
/// balance some poll read, with no averaging between neighbours. `Decimal`
/// keeps a money figure exact — 179.50 stays 179.50, not the nearest binary
/// double.
public struct BalancePoint: Sendable, Equatable {
    public let measuredAt: Date
    public let value: Decimal

    public init(measuredAt: Date, value: Decimal) {
        self.measuredAt = measuredAt
        self.value = value
    }
}
