import Testing
import Foundation
import SwiftUI
import QuotaBarCore
@testable import QuotaBarUI

@Suite("TokenUsagePresentation")
struct TokenUsagePresentationTests {

    typealias T = TokenUsagePresentation

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 08:20 UTC. For the 24h range the window starts 08:20 the day before,
    /// the grid anchors at that day's midnight, and 30-minute slot 16 is
    /// 08:00 — the bucket that holds `since`.
    private let now = Date(timeIntervalSince1970: 1_800_000_000 + 20 * 60)
    private let anchor = Date(timeIntervalSince1970: 1_799_884_800)
    private let slot: TimeInterval = 1800

    private func bucket(_ source: String, slot index: Int, _ tokens: Int, records: Int = 1) -> QuotaHistoryStore.TokenBucket {
        .init(source: source, start: anchor.addingTimeInterval(Double(index) * slot), tokens: tokens, records: records)
    }

    private func chart(
        _ buckets: [QuotaHistoryStore.TokenBucket] = [],
        uncounted: [String: Int] = [:],
        filters: WidgetFilters = WidgetFilters(layout: .tokens),
        hidden: Set<VendorIdentifier> = [],
        configured: [VendorIdentifier] = []
    ) -> T.Chart {
        T.chart(
            usage: .init(buckets: buckets, uncountedRecords: uncounted),
            filters: filters, hidden: hidden, configured: configured,
            now: now, calendar: calendar)
    }

    // MARK: Providers and sources

    @Test("only tools with a local adapter have token data, and they stack in a fixed order")
    func tokenVendors() {
        #expect(T.tokenVendors == [.claude, .openai, .opencode])
        #expect(T.vendor(forSource: "claude_code") == .claude)
        #expect(T.vendor(forSource: "codex") == .openai)
        #expect(T.vendor(forSource: "opencode") == .opencode)
        #expect(T.vendor(forSource: "mystery") == nil)
    }

    // MARK: Stacking

    @Test("layers stack bottom to top in provider order, with cumulative edges")
    func stacking() {
        let c = chart([
            bucket("codex", slot: 20, 40),
            bucket("claude_code", slot: 20, 100),
            bucket("claude_code", slot: 21, 10),
        ])
        #expect(c.layers.map(\.vendorId) == [.claude, .openai])
        let claude = c.layers[0].points.first { $0.tokens == 100 }
        let codex = c.layers[1].points.first { $0.tokens == 40 }
        #expect(claude?.lower == 0 && claude?.upper == 100)
        #expect(codex?.lower == 100 && codex?.upper == 140)
        #expect(c.peak == 140)
        #expect(c.totalTokens == 150)
        #expect(c.layers.map(\.totalTokens) == [110, 40])
        #expect(!c.isEmpty)
    }

    @Test("every layer shares one x grid, and a quiet bucket is zero observed tokens")
    func sharedGridAndZeroFill() {
        let c = chart([bucket("claude_code", slot: 20, 100), bucket("codex", slot: 30, 5)])
        // From the bucket holding 08:20 yesterday to the one holding now.
        #expect(c.layers.allSatisfy { $0.points.count == 49 })
        #expect(c.layers[0].points.map(\.bucketStart) == c.layers[1].points.map(\.bucketStart))
        #expect(c.layers[0].points.map(\.bucketStart) == c.layers[0].points.map(\.bucketStart).sorted())
        #expect(c.layers[0].points.first?.bucketStart == anchor.addingTimeInterval(16 * slot))
        #expect(c.layers[0].points.last?.bucketStart == anchor.addingTimeInterval(64 * slot))
        #expect(c.layers[0].points.first { $0.bucketStart == anchor.addingTimeInterval(22 * slot) }?.tokens == 0)
    }

    @Test("a provider with no tokens in the range is not drawn as a flat layer")
    func zeroLayerOmitted() {
        let c = chart([bucket("opencode", slot: 20, 9)])
        #expect(c.layers.map(\.vendorId) == [.opencode])
    }

    @Test("nothing counted is an empty chart, not zeros")
    func empty() {
        #expect(chart().isEmpty)
        #expect(chart().layers.isEmpty)
        #expect(chart().peak == 0)
        // A source no adapter claims is ignored rather than invented a layer.
        #expect(chart([bucket("mystery", slot: 20, 500)]).isEmpty)
    }

    // MARK: Who is shown

    @Test("hidden providers are not drawn, and a selection narrows the layers")
    func hiddenAndSelected() {
        let data = [bucket("claude_code", slot: 20, 100), bucket("codex", slot: 20, 40), bucket("opencode", slot: 20, 7)]
        #expect(chart(data, hidden: [.claude]).layers.map(\.vendorId) == [.openai, .opencode])
        #expect(chart(data, filters: WidgetFilters(vendors: [.openai], layout: .tokens)).layers.map(\.vendorId) == [.openai])
        #expect(chart(data, filters: WidgetFilters(vendors: [.gemini], layout: .tokens)).isEmpty)
    }

    // MARK: What is not covered

    /// Naming them is the honest alternative to a zero layer.
    @Test("providers with no token data are named, once, without hidden ones or GitHub's rate limits")
    func vendorsWithoutData() {
        let configured: [VendorIdentifier] = [.claude, .gemini, .grok, .githubRest, .githubGraphql, .openrouter, .gemini]
        #expect(chart(configured: configured).vendorsWithoutTokenData == [.gemini, .grok, .openrouter])
        #expect(chart(hidden: [.grok], configured: configured).vendorsWithoutTokenData == [.gemini, .openrouter])
        #expect(chart(filters: WidgetFilters(vendors: [.gemini], layout: .tokens), configured: configured).vendorsWithoutTokenData == [.gemini])
        #expect(chart(configured: [.claude, .openai]).vendorsWithoutTokenData.isEmpty)
    }

    @Test("records with no token figure are counted only for the providers shown")
    func uncounted() {
        let counts = ["claude_code": 3, "codex": 2, "mystery": 9]
        #expect(chart(uncounted: counts).uncountedRecords == 5)
        #expect(chart(uncounted: counts, hidden: [.openai]).uncountedRecords == 3)
    }

    @Test("Codex's per-session placement is flagged only when Codex is drawn")
    func sessionTotals() {
        #expect(chart([bucket("codex", slot: 20, 1)]).hasSessionTotals)
        #expect(!chart([bucket("claude_code", slot: 20, 1)]).hasSessionTotals)
    }

    // MARK: Time axis

    @Test("points sit at bucket centres, held inside the charted window")
    func xClamped() {
        let c = chart([bucket("claude_code", slot: 20, 1)])
        let since = now.addingTimeInterval(-24 * 3600)
        #expect(c.domain.lowerBound == since)
        #expect(c.domain.upperBound == now)
        let xs = c.layers[0].points.map(\.x)
        #expect(xs.allSatisfy { c.domain.contains($0) })
        // The partial first bucket's centre (08:15) is before the window
        // starts (08:20), so it is held at the edge.
        #expect(xs.first == since)
        // The current bucket's centre (08:15) is already past, so it stays put.
        #expect(xs.last == anchor.addingTimeInterval(64 * slot + slot / 2))
        #expect(c.layers[0].points.first { $0.bucketStart == anchor.addingTimeInterval(20 * slot) }?.x
                == anchor.addingTimeInterval(20 * slot + slot / 2))
    }

    /// Early in the current bucket its centre is still in the future, and a
    /// point there would sit past the right edge of the chart.
    @Test("a current bucket whose centre is still ahead is held at now")
    func currentBucketHeldAtNow() {
        let early = anchor.addingTimeInterval(64 * slot + 300)       // 08:05
        let c = T.chart(
            usage: .init(buckets: [bucket("claude_code", slot: 64, 5)], uncountedRecords: [:]),
            filters: WidgetFilters(layout: .tokens), hidden: [], configured: [],
            now: early, calendar: calendar)
        #expect(c.layers[0].points.last?.x == early)
        #expect(c.layers[0].points.allSatisfy { c.domain.contains($0.x) })
    }

    @Test("bucket widths divide a day, and the grid starts at local midnight")
    func buckets() {
        for range in [HistoryPresentation.TimeRange.last24Hours, .last7Days, .last30Days, .allTime] {
            #expect(86_400 % T.bucketSeconds(for: range) == 0)
        }
        let w = T.window(range: .last24Hours, now: now, calendar: calendar)
        #expect(w.since == now.addingTimeInterval(-24 * 3600))
        #expect(w.anchor == anchor)
        let seven = chart(filters: WidgetFilters(range: .last7Days, layout: .tokens))
        #expect(seven.bucketSeconds == 10_800)
    }

    // MARK: Numbers

    @Test("compact token counts promote units instead of printing 1000k")
    func compact() {
        let cases: [(Int, String)] = [
            (0, "0"), (999, "999"), (1000, "1k"), (1234, "1.2k"), (9949, "9.9k"), (9950, "10k"),
            (12_345, "12k"), (340_000, "340k"), (999_499, "999k"), (999_500, "1M"),
            (1_234_567, "1.2M"), (12_500_000, "13M"), (2_000_000_000, "2B"), (-1500, "-1.5k"),
        ]
        for (tokens, text) in cases { #expect(T.compact(tokens) == text, "\(tokens)") }
    }

    @Test("spoken token counts use words")
    func spoken() {
        let cases: [(Int, String)] = [
            (999, "999"), (1000, "1 thousand"), (340_000, "340 thousand"), (999_500, "1 million"),
            (1_234_567, "1.2 million"), (2_000_000_000, "2 billion"),
        ]
        for (tokens, text) in cases { #expect(T.spoken(tokens) == text, "\(tokens)") }
    }

    // MARK: Spoken summary

    @Test("the summary states the total, each provider and every caveat")
    func summary() {
        let c = chart(
            [bucket("claude_code", slot: 20, 2_000_000), bucket("codex", slot: 20, 500_000)],
            uncounted: ["claude_code": 4], configured: [.gemini])
        let text = T.accessibilitySummary(chart: c, range: .last7Days)
        #expect(text.contains("2.5 million observed tokens in the 7 days range"))
        #expect(text.contains("local sessions on this Mac, cache included"))
        #expect(text.contains("Claude 2 million"))
        #expect(text.contains("OpenAI 500 thousand"))
        #expect(text.contains("Codex counts tokens per session, at its last turn"))
        #expect(text.contains("4 records had no token count and are not included"))
        #expect(text.contains("No token counts for Gemini"))
        #expect(T.accessibilitySummary(chart: chart(), range: .last24Hours).hasPrefix("No token activity"))
    }

    // MARK: Footnotes

    @Test("the footnotes say what the chart leaves out, and are silent when it leaves nothing out")
    func notes() {
        #expect(T.notes(for: chart([bucket("claude_code", slot: 20, 1)])).isEmpty)
        let all = chart(
            [bucket("claude_code", slot: 20, 1), bucket("codex", slot: 20, 1)],
            uncounted: ["codex": 1], configured: [.gemini, .grok])
        #expect(T.notes(for: all) == [
            "Codex counts tokens per session, at its last turn.",
            "1 record had no token count and is not included.",
            "No token counts for Gemini, Grok.",
        ])
        #expect(T.notes(for: chart([bucket("claude_code", slot: 20, 1)], uncounted: ["claude_code": 7]))
                == ["7 records had no token count and are not included."])
    }

    /// What is read out must be what is drawn.
    @Test("every footnote on screen is in the spoken summary")
    func notesAreSpoken() {
        let c = chart(
            [bucket("codex", slot: 20, 9)], uncounted: ["codex": 2], configured: [.gemini])
        let spoken = T.accessibilitySummary(chart: c, range: .last24Hours)
        for note in T.notes(for: c) {
            #expect(spoken.contains(note.dropLast()), "\(note)")
        }
    }

    // MARK: The total line

    @Test("the total is every drawn layer added, per bucket, and tops the stack")
    func totals() {
        let c = chart([
            bucket("claude_code", slot: 20, 100), bucket("codex", slot: 20, 40),
            bucket("opencode", slot: 20, 7), bucket("claude_code", slot: 21, 10),
        ])
        #expect(c.totals.count == c.layers[0].points.count)
        #expect(c.totals.map(\.bucketStart) == c.layers[0].points.map(\.bucketStart))
        #expect(c.totals.map(\.x) == c.layers[0].points.map(\.x))
        #expect(c.totals.first { $0.bucketStart == anchor.addingTimeInterval(20 * slot) }?.tokens == 147)
        #expect(c.totals.first { $0.bucketStart == anchor.addingTimeInterval(21 * slot) }?.tokens == 10)
        // The total is the top edge of the last layer in every bucket.
        let top = c.layers.last!.points.map { Int($0.upper) }
        #expect(c.totals.map(\.tokens) == top)
        #expect(c.totals.map(\.tokens).reduce(0, +) == c.totalTokens)
        #expect(Double(c.totals.map(\.tokens).max() ?? 0) == c.peak)
    }

    // MARK: Colour

    private func hue(_ hex: String) -> Double {
        let v = UInt32(hex.dropFirst(), radix: 16)!
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        let hi = max(r, g, b), lo = min(r, g, b), d = hi - lo
        guard d > 0 else { return 0 }
        let h: Double
        if hi == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if hi == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Hue is the only thing that says which layer is which, and OpenCode's
    /// brand amber is next to Claude's salmon.
    @Test("the layer colours are valid and well apart in hue")
    func layerColours() {
        let hexes = T.tokenVendors.map { T.layerColorHex(for: $0) }
        #expect(hexes.allSatisfy { Color(hexString: $0) != nil })
        #expect(Set(hexes).count == hexes.count)
        let hues = hexes.map(hue)
        var smallest = 360.0
        for i in hues.indices {
            for j in hues.indices where j > i {
                let d = abs(hues[i] - hues[j])
                smallest = min(smallest, min(d, 360 - d))
            }
        }
        #expect(smallest >= 50, "closest pair of layer hues is \(Int(smallest))°")
        // The brand amber that was too close to Claude's salmon.
        #expect(T.layerColorHex(for: .opencode) != VendorIdentifier.opencode.accentColorHex)
    }
}
