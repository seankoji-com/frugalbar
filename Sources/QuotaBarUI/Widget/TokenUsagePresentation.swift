import Foundation
import QuotaBarCore

/// Pure presentation logic for the desktop widget's Tokens layout: raw
/// consumption across providers as a stacked area.
///
/// This is deliberately unlike the quota views. Tokens are one unit, so adding
/// them across providers is meaningful, where adding a 5-hour window at 40%
/// to a monthly one at 40% would not be. What it is *not* is a quota: it is
/// what local tools recorded, never a share of an allowance.
///
/// Everything drawn is observed:
/// - Only tools FrugalBar has a local adapter for have token counts at all
///   (`tokenVendors`). Every other configured provider is named in
///   `vendorsWithoutTokenData`, never drawn as a flat zero layer.
/// - A bucket where a tool recorded nothing is zero *observed* tokens, which
///   is true. A record whose tool reported no token figure is neither summed
///   nor zero: it is counted in `uncountedRecords` and said so.
/// - Cache tokens are included, as each tool reports them. The tools count
///   cache differently, so provider-to-provider comparison is of trends.
public enum TokenUsagePresentation {

    // MARK: - Types

    public struct Point: Identifiable, Sendable, Equatable {
        public var id: Date { bucketStart }
        /// Where the point is drawn: the bucket's centre, held inside the
        /// charted range so the first and current partial buckets do not
        /// poke past its edges.
        public let x: Date
        public let bucketStart: Date
        public let tokens: Int
        /// The layer's edges in the stack, in tokens.
        public let lower: Double
        public let upper: Double
    }

    public struct Layer: Identifiable, Sendable, Equatable {
        public var id: VendorIdentifier { vendorId }
        public let vendorId: VendorIdentifier
        public let points: [Point]
        public let totalTokens: Int
    }

    /// The top of the stack at one bucket: every drawn layer's tokens added.
    /// Tokens share one unit, so this sum is real.
    public struct TotalPoint: Identifiable, Sendable, Equatable {
        public var id: Date { bucketStart }
        public let x: Date
        public let bucketStart: Date
        public let tokens: Int
    }

    public struct Chart: Sendable, Equatable {
        /// Bottom to top. Only vendors with tokens in the range.
        public let layers: [Layer]
        /// The stack's total per bucket, for the line along its top.
        public let totals: [TotalPoint]
        public let domain: ClosedRange<Date>
        public let bucketSeconds: Int
        public let totalTokens: Int
        /// The tallest stack, for the y axis. 0 when nothing was counted.
        public let peak: Double
        /// Records in range, for the vendors shown, that reported no token
        /// figure. In no layer and no total.
        public let uncountedRecords: Int
        /// Providers the user has whose tools publish no token counts here.
        public let vendorsWithoutTokenData: [VendorIdentifier]

        public var isEmpty: Bool { totalTokens == 0 }

        /// Codex records one cumulative total per session, placed at the
        /// session's last turn, so its tokens land in lumps rather than
        /// spread over the session. Said on screen when it applies.
        public var hasSessionTotals: Bool { layers.contains { $0.vendorId == .openai } }
    }

    // MARK: - Which providers have token data

    /// Providers FrugalBar can count tokens for, in the order they stack.
    public static let tokenVendors: [VendorIdentifier] =
        ProviderDisplayPreferences.defaultOrder.filter {
            !AttributionEngine.localSourceIdentifiers(for: $0).isEmpty
        }

    /// The provider a local activity source belongs to, or nil for a source
    /// no adapter claims.
    public static func vendor(forSource source: String) -> VendorIdentifier? {
        tokenVendors.first { AttributionEngine.localSourceIdentifiers(for: $0).contains(source) }
    }

    // MARK: - Colour

    /// The colour each provider's layer is drawn in. Their brand accents,
    /// except OpenCode's: its amber sits too close to Claude's salmon to tell
    /// apart in a stack, so it takes a blue. Hue is the only thing identifying
    /// a layer, so the three are kept well apart.
    public static func layerColorHex(for vendor: VendorIdentifier) -> String {
        switch vendor {
        case .opencode: "#7aa2ff"
        default: vendor.accentColorHex
        }
    }

    // MARK: - Buckets

    /// Bucket width per range, keeping a chart to a few dozen points.
    public static func bucketSeconds(for range: HistoryPresentation.TimeRange) -> Int {
        switch range {
        case .last24Hours: 1_800      // 30 min, 48 buckets
        case .last7Days:   10_800     // 3 h, 56 buckets
        case .last30Days:  43_200     // 12 h, 60 buckets
        case .allTime:     86_400
        }
    }

    /// The charted window and the grid its buckets sit on: local midnight of
    /// the start day, so every width above divides the day and bucket edges
    /// fall on whole hours.
    public static func window(
        range: HistoryPresentation.TimeRange,
        now: Date,
        calendar: Calendar = .current
    ) -> (since: Date, anchor: Date) {
        // "All" is not offered by the widget; if asked for it, 30 days.
        let since = range.startDate(from: now) ?? now.addingTimeInterval(-30 * 86_400)
        return (since, calendar.startOfDay(for: since))
    }

    // MARK: - Chart

    /// - Parameters:
    ///   - hidden: Providers the user has hidden. They are not drawn, like
    ///     everywhere else.
    ///   - configured: Providers the user has set up, to name the ones with
    ///     no token data. Pass the store's snapshots' vendors.
    public static func chart(
        usage: QuotaHistoryStore.TokenUsage,
        filters: WidgetFilters,
        hidden: Set<VendorIdentifier>,
        configured: [VendorIdentifier],
        now: Date,
        calendar: Calendar = .current
    ) -> Chart {
        let window = window(range: filters.range, now: now, calendar: calendar)
        let size = bucketSeconds(for: filters.range)
        let step = TimeInterval(size)

        let shown = tokenVendors.filter {
            !hidden.contains($0) && (filters.vendors.isEmpty || filters.vendors.contains($0))
        }

        // Tokens per vendor per bucket start.
        var tokens: [VendorIdentifier: [Date: Int]] = [:]
        for bucket in usage.buckets {
            guard let vendor = vendor(forSource: bucket.source), shown.contains(vendor) else { continue }
            tokens[vendor, default: [:]][bucket.start, default: 0] += bucket.tokens
        }

        // Every bucket from the one holding `since` to the one holding `now`,
        // for every vendor, so the layers share one x grid. A bucket where a
        // tool recorded nothing is zero observed tokens.
        let first = Int(floor(window.since.timeIntervalSince(window.anchor) / step))
        let last = max(first, Int(floor(now.timeIntervalSince(window.anchor) / step)))
        let starts = (first...last).map { window.anchor.addingTimeInterval(Double($0) * step) }

        let vendorTotals = shown.map { vendor in
            (vendor, tokens[vendor]?.values.reduce(0, +) ?? 0)
        }
        let drawn = vendorTotals.filter { $0.1 > 0 }.map(\.0)

        var pointsByVendor: [VendorIdentifier: [Point]] = [:]
        var totals: [TotalPoint] = []
        var peak = 0.0
        for start in starts {
            let x = min(max(start.addingTimeInterval(step / 2), window.since), now)
            var running = 0.0
            for vendor in drawn {
                let value = tokens[vendor]?[start] ?? 0
                let point = Point(
                    x: x, bucketStart: start, tokens: value,
                    lower: running, upper: running + Double(value))
                running = point.upper
                pointsByVendor[vendor, default: []].append(point)
            }
            peak = max(peak, running)
            totals.append(TotalPoint(x: x, bucketStart: start, tokens: Int(running)))
        }

        let layers = drawn.map { vendor in
            Layer(
                vendorId: vendor,
                points: pointsByVendor[vendor] ?? [],
                totalTokens: tokens[vendor]?.values.reduce(0, +) ?? 0)
        }

        let shownSources = Set(shown.flatMap { AttributionEngine.localSourceIdentifiers(for: $0) })
        let uncounted = usage.uncountedRecords
            .filter { shownSources.contains($0.key) }
            .values.reduce(0, +)

        // Providers the user has that have no token source here. A selection
        // narrows the note to what was asked about.
        var seen = Set<VendorIdentifier>()
        let without = configured.filter { vendor in
            guard !hidden.contains(vendor),
                  vendor != .githubRest, vendor != .githubGraphql,   // rate limits, not a model
                  AttributionEngine.localSourceIdentifiers(for: vendor).isEmpty,
                  filters.vendors.isEmpty || filters.vendors.contains(vendor)
            else { return false }
            return seen.insert(vendor).inserted
        }

        return Chart(
            layers: layers,
            totals: totals,
            domain: window.since...max(now, window.since),
            bucketSeconds: size,
            totalTokens: layers.reduce(0) { $0 + $1.totalTokens },
            peak: peak,
            uncountedRecords: uncounted,
            vendorsWithoutTokenData: without
        )
    }

    // MARK: - Text

    private static let units = ["", "k", "M", "B"]

    /// `999`, `1.2k`, `12k`, `340k`, `1.2M`, `2B`. One decimal under ten, none
    /// above, and a rounded thousand promotes to the next unit ("999.6k" is
    /// "1M", never "1000k").
    public static func compact(_ tokens: Int) -> String {
        let sign = tokens < 0 ? "-" : ""
        let (value, unit) = scaled(Double(abs(tokens)))
        guard unit > 0 else { return "\(sign)\(Int(value))" }
        return "\(sign)\(trimmed(value))\(units[unit])"
    }

    /// The spoken form: "1.2 million", "340 thousand", "999".
    public static func spoken(_ tokens: Int) -> String {
        let words = ["", "thousand", "million", "billion"]
        let sign = tokens < 0 ? "minus " : ""
        let (value, unit) = scaled(Double(abs(tokens)))
        guard unit > 0 else { return "\(sign)\(Int(value))" }
        return "\(sign)\(trimmed(value)) \(words[unit])"
    }

    private static func scaled(_ magnitude: Double) -> (Double, Int) {
        var value = magnitude
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        guard unit > 0 else { return (value, 0) }
        var rounded = value < 10 ? (value * 10).rounded() / 10 : value.rounded()
        if rounded >= 1000, unit < units.count - 1 {
            rounded = (rounded / 1000 * 10).rounded() / 10
            unit += 1
        }
        return (rounded, unit)
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    /// What the chart does not say for itself, in the words drawn under it.
    /// The spoken summary uses these same strings, so what is read out and
    /// what is on screen cannot drift apart.
    public static func notes(for chart: Chart) -> [String] {
        var notes: [String] = []
        if chart.hasSessionTotals {
            notes.append("Codex counts tokens per session, at its last turn.")
        }
        if chart.uncountedRecords == 1 {
            notes.append("1 record had no token count and is not included.")
        } else if chart.uncountedRecords > 1 {
            notes.append("\(chart.uncountedRecords) records had no token count and are not included.")
        }
        if !chart.vendorsWithoutTokenData.isEmpty {
            notes.append("No token counts for \(chart.vendorsWithoutTokenData.map(\.displayName).joined(separator: ", ")).")
        }
        return notes
    }

    /// Spoken summary of the chart: the total and each provider's share of
    /// the observed tokens, with what it does not cover.
    public static func accessibilitySummary(
        chart: Chart, range: HistoryPresentation.TimeRange
    ) -> String {
        guard !chart.isEmpty else {
            return "No token activity recorded in the \(range.title.lowercased()) range"
        }
        var parts = ["\(spoken(chart.totalTokens)) observed tokens in the \(range.title.lowercased()) range, from local sessions on this Mac, cache included"]
        parts += chart.layers.map { "\($0.vendorId.displayName) \(spoken($0.totalTokens))" }
        parts += notes(for: chart).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return parts.joined(separator: ". ")
    }
}
