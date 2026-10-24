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

    /// How far the local-activity ingestion has got, which decides whether an
    /// empty or short chart may be read as "nothing happened".
    public enum IngestionProgress: Sendable, Equatable {
        /// A pass has finished in this run and read everything it found.
        case complete
        /// No pass has finished in this run (running, or not yet started), so
        /// the table is empty or partly filled on a first run, and on a later
        /// one is missing whatever the tools wrote while the app was closed.
        case indexing
        /// The latest pass could not read everything, so some tokens are
        /// missing from every total.
        case incomplete

        /// `nil` means the status could not be read at all. That is never
        /// evidence of completeness, so it reads as still indexing.
        public init(_ status: ActivityIngestionEngine.Status?) {
            guard let status else { self = .indexing; return }
            if status.lastPassIncomplete { self = .incomplete }
            else if status.hasCompletedCleanPass { self = .complete }
            else { self = .indexing }
        }
    }

    /// Why a chart with nothing in it is empty.
    public enum EmptyReason: Sendable, Equatable {
        /// Ingestion is complete and recorded no tokens in the range.
        case noActivity
        case indexing
        case incomplete
    }

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
        /// How far ingestion has got: a short or empty chart is only
        /// "no activity" when this is `.complete`.
        public let ingestion: IngestionProgress
        /// Per-source scan and malformed/incomplete counts, already worded.
        public let sourceNotes: [String]

        public var isEmpty: Bool { totalTokens == 0 }

        /// nil when something is drawn.
        public var emptyReason: EmptyReason? {
            guard isEmpty else { return nil }
            switch ingestion {
            case .complete: return .noActivity
            case .indexing: return .indexing
            case .incomplete: return .incomplete
            }
        }

        /// True only when a drawn source's records are whole-session totals.
        /// Codex request rows place each request at its own time, so they do
        /// not carry the session-lump caveat.
        public let usesSessionTotals: Bool

        /// Codex fell back to one cumulative total per session for a source
        /// that exposed no request rows; its tokens land in lumps rather than
        /// being spread over the session. Said on screen only then.
        public var hasSessionTotals: Bool { usesSessionTotals }
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
    ///   - ingestion: How far the local-activity ingestion has got. There is
    ///     no default: whoever draws a chart must say, since an empty table
    ///     before the first pass is not an empty week.
    ///   - sources: Retained per-source scan diagnostics. Their counts are
    ///     shown beside the chart, and an unchanged-file skip cannot erase
    ///     them.
    public static func chart(
        usage: QuotaHistoryStore.TokenUsage,
        filters: WidgetFilters,
        hidden: Set<VendorIdentifier>,
        configured: [VendorIdentifier],
        ingestion: IngestionProgress,
        now: Date,
        calendar: Calendar = .current,
        sources: [ActivitySourceStatus] = []
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

        let usesSessionTotals: Bool
        if usage.granularityKnown {
            usesSessionTotals = drawn.contains(.openai)
                && (usage.sessionTotalRecords["codex"] ?? 0) > 0
        } else {
            usesSessionTotals = drawn.contains(.openai)
        }

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
            vendorsWithoutTokenData: without,
            ingestion: ingestion,
            sourceNotes: sourceNotes(sources: sources, shownSources: shownSources),
            usesSessionTotals: usesSessionTotals
        )
    }

    // MARK: - Source diagnostics

    /// Word each retained diagnostic once. Counts arrive from the ingest
    /// engine, never from the chart's own arithmetic.
    public static func sourceNotes(
        sources: [ActivitySourceStatus],
        shownSources: Set<String>
    ) -> [String] {
        let visible = sources
            .filter { shownSources.contains($0.source) }
            .sorted { $0.source < $1.source }
        guard !visible.isEmpty else { return [] }

        var notes: [String] = []
        for status in visible {
            let name = sourceDisplayName(status.source)
            if status.readFailures > 0 {
                notes.append("\(name): \(status.readFailures) input\(status.readFailures == 1 ? "" : "s") could not be read on the last scan.")
            }
            if status.malformedRecords > 0 {
                notes.append("\(name): \(status.malformedRecords) malformed record\(status.malformedRecords == 1 ? "" : "s") \(status.malformedRecords == 1 ? "was" : "were") not counted.")
            }
            if status.inconsistentRecords > 0 {
                notes.append("\(name): \(status.inconsistentRecords) record\(status.inconsistentRecords == 1 ? "" : "s") disagreed with the source's cumulative counter and \(status.inconsistentRecords == 1 ? "was" : "were") not reconciled.")
            }
            if status.incompleteRecords > 0 {
                notes.append("\(name): \(status.incompleteRecords) record\(status.incompleteRecords == 1 ? "" : "s") had an incomplete token breakdown.")
            }
        }

        let scanned = visible.compactMap { status -> String? in
            guard let at = status.lastSuccessfulScanAt else { return nil }
            return "\(sourceDisplayName(status.source)) \(scanTimestamp(at))"
        }
        if !scanned.isEmpty {
            notes.append("Last successful scan: \(scanned.joined(separator: ", ")).")
        }
        return notes
    }

    static func sourceDisplayName(_ source: String) -> String {
        switch source {
        case "claude_code": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        default: source
        }
    }

    static func scanTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
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

    // MARK: - Empty states

    public static func emptyTitle(_ reason: EmptyReason) -> String {
        switch reason {
        case .noActivity: "No token activity in this range"
        case .indexing: "Reading your local sessions…"
        case .incomplete: "Could not read all local sessions"
        }
    }

    /// The line under the title, or nil when the chart is not empty.
    public static func emptyDetail(for chart: Chart) -> String? {
        guard let reason = chart.emptyReason else { return nil }
        switch reason {
        case .noActivity:
            return (["FrugalBar counts tokens from local Claude Code, Codex and OpenCode sessions on this Mac."]
                    + notes(for: chart)).joined(separator: " ")
        case .indexing:
            return "FrugalBar is reading your Claude Code, Codex and OpenCode history. Totals appear as it finishes."
        case .incomplete:
            return "Some session history could not be read, so this is not an absence of activity."
        }
    }

    /// What the chart does not say for itself, in the words drawn under it.
    /// The spoken summary uses these same strings, so what is read out and
    /// what is on screen cannot drift apart.
    public static func notes(for chart: Chart) -> [String] {
        var notes: [String] = []
        // First, and on a chart that has data too: while the first pass runs
        // the layers drawn may be only the sources read so far.
        switch chart.ingestion {
        case .complete: break
        case .indexing: notes.append("Still reading your local sessions, so these totals may be incomplete.")
        case .incomplete: notes.append("Some local sessions could not be read, so these totals may be incomplete.")
        }
        if chart.hasSessionTotals {
            notes.append("Codex counts tokens per session, at its last turn.")
        }
        if chart.layers.contains(where: { $0.vendorId == .opencode }) {
            notes.append("OpenCode sessions are local tool activity; they do not record which account or workspace billed them.")
        }
        if chart.uncountedRecords == 1 {
            notes.append("1 record had no token count and is not included.")
        } else if chart.uncountedRecords > 1 {
            notes.append("\(chart.uncountedRecords) records had no token count and are not included.")
        }
        if !chart.vendorsWithoutTokenData.isEmpty {
            notes.append("No token counts for \(chart.vendorsWithoutTokenData.map(\.displayName).joined(separator: ", ")).")
        }
        notes += chart.sourceNotes
        return notes
    }

    /// Spoken summary of the chart: the total and each provider's share of
    /// the observed tokens, with what it does not cover.
    public static func accessibilitySummary(
        chart: Chart, range: HistoryPresentation.TimeRange
    ) -> String {
        if let reason = chart.emptyReason {
            // The title says why it is empty; "no activity" only when it is
            // true. The detail is spoken too, since it is on screen.
            let title = emptyTitle(reason)
            guard let detail = emptyDetail(for: chart) else { return title }
            return "\(title). \(detail)"
        }
        var parts = ["\(spoken(chart.totalTokens)) observed tokens in the \(range.title.lowercased()) range, from local sessions on this Mac, cache included"]
        parts += chart.layers.map { "\($0.vendorId.displayName) \(spoken($0.totalTokens))" }
        parts += notes(for: chart).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return parts.joined(separator: ". ")
    }
}
