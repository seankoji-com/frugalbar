import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

/// The pure shape behind the inline balance strip and the inspector's balance
/// chart. Both draw from this, so the two things that can actually go wrong are
/// tested here rather than re-read off a `View` value: drawing a trend from a
/// single reading, and normalising a flat series off its own box.
@Suite("Balance sparkline")
struct BalanceSparklineTests {

    private func point(_ seconds: TimeInterval, _ value: String) -> BalancePoint {
        BalancePoint(measuredAt: Date(timeIntervalSince1970: seconds), value: Decimal(string: value)!)
    }

    /// One observation is not a trend. A strip drawn from it would assert a
    /// direction nobody recorded.
    @Test("fewer than two readings has no shape to draw")
    func singleReadingDrawsNothing() {
        #expect(BalanceSparklinePresentation.make(from: []) == nil)
        #expect(BalanceSparklinePresentation.make(from: [point(0, "10.00")]) == nil)
    }

    /// A flat series has no top or bottom. Centred, it reads as "unchanged";
    /// pinned to 0 it would read as a reserve that emptied.
    @Test("a flat series is centred, not pinned to an edge")
    func flatSeriesIsCentred() throws {
        let p = try #require(BalanceSparklinePresentation.make(from: [
            point(0, "25.00"), point(3600, "25.00"), point(7200, "25.00")]))
        #expect(p.isFlat)
        #expect(p.points.allSatisfy { $0.y == 0.5 })
        #expect(p.change == 0)
        #expect(p.minValue == Decimal(string: "25.00"))
        #expect(p.maxValue == Decimal(string: "25.00"))
    }

    /// The newest reading is the right-hand end and the highest reading is the
    /// top — a balance that fell ends low, not high.
    @Test("a falling series normalises the newest reading to the bottom")
    func fallingSeriesNormalises() throws {
        let p = try #require(BalanceSparklinePresentation.make(from: [
            point(0, "210.00"), point(3600, "200.00"), point(7200, "179.50")]))
        #expect(p.points.first?.y == 1.0)
        #expect(p.points.last?.y == 0.0)
        #expect(p.points.first?.x == 0.0)
        #expect(p.points.last?.x == 1.0)
        #expect(p.latestValue == Decimal(string: "179.50"))
        #expect(p.maxValue == Decimal(string: "210.00"))
        #expect(p.minValue == Decimal(string: "179.50"))
        #expect(p.change == Decimal(string: "-30.50"))
    }

    /// Points are ordered by time regardless of the order they arrive in, so a
    /// read that returned a bucket out of order cannot draw a backwards line.
    @Test("points are sorted by time before normalising")
    func outOfOrderInputIsSorted() throws {
        let p = try #require(BalanceSparklinePresentation.make(from: [
            point(7200, "5.00"), point(0, "15.00"), point(3600, "10.00")]))
        #expect(p.points.map(\.x) == [0.0, 0.5, 1.0])
        #expect(p.latestValue == Decimal(string: "5.00"))
        #expect(p.change == Decimal(string: "-10.00"))
    }

    /// The exact figure is the vendor's, not the normalised position: the strip
    /// must be able to say "$179.50" and not only "15% up the box".
    @Test("the latest figure is carried exactly, alongside the shape")
    func latestFigureIsExact() throws {
        let p = try #require(BalanceSparklinePresentation.make(from: [
            point(0, "199.99"), point(3600, "179.50")]))
        #expect(p.latestValue == Decimal(string: "179.50"))
        #expect(p.sampleCount == 2)
    }

    /// The unit decides the wording; the shape must never be money-shaped.
    @Test("units parse back from their storage key, and never mix")
    func unitRoundTrips() {
        #expect(BalanceSeries.Unit.parse(storageKey: "currency:USD") == .currency(code: "USD"))
        #expect(BalanceSeries.Unit.parse(storageKey: "credits:credits") == .credits(name: "credits"))
        #expect(BalanceSeries.Unit.parse(storageKey: "something-else") == nil)
        #expect(BalanceSeries.Unit.currency(code: "usd").storageKey == "currency:USD")
        #expect(BalanceSeries.Unit.currency(code: "USD").currencyCode == "USD")
        #expect(BalanceSeries.Unit.credits(name: "credits").currencyCode == nil)
    }

    /// A money series keys by code, so two currencies of one account are two
    /// series and can never be drawn as one line.
    @Test("series ids separate currencies and units")
    func seriesIDsSeparateUnits() {
        #expect(BalanceSeries.id(source: "deepseek", unit: .currency(code: "USD"))
             != BalanceSeries.id(source: "deepseek", unit: .currency(code: "CNY")))
        #expect(BalanceSeries.id(source: "openai", unit: .credits(name: "credits"))
             != BalanceSeries.id(source: "openai", unit: .currency(code: "USD")))
    }

    // MARK: - The caption under the chart

    /// The three directions are the handed-out contract, so nothing downstream
    /// has to ask what a zero change means.
    @Test("a change is classified by its sign, and a zero change is neither way")
    func changeClassification() {
        #expect(BalanceSparklinePresentation.Trend.of(change: Decimal(string: "15.50")!) == .rose)
        #expect(BalanceSparklinePresentation.Trend.of(change: Decimal(string: "-30.50")!) == .fell)
        #expect(BalanceSparklinePresentation.Trend.of(change: 0) == .returned)
    }

    /// A series can move and come back: 5, 1, 5 has a range of 4, so it is not
    /// flat, yet its net change is zero. The arrow used to be chosen from
    /// `change >= 0`, which printed "▲ 0" — a rise that did not happen.
    @Test("a series that ends where it began claims no direction")
    func returnedToStartClaimsNothing() throws {
        let p = try #require(BalanceSparklinePresentation.make(
            from: [point(0, "5.00"), point(60, "1.00"), point(120, "5.00")]))
        #expect(!p.isFlat)
        #expect(p.change == 0)
        #expect(p.caption(in: .currency(code: "USD")) == "$5.00 · no net change across 3 readings")
    }

    @Test("a rising and a falling series are said with their own direction and figure")
    func directionAndMagnitude() throws {
        let up = try #require(BalanceSparklinePresentation.make(
            from: [point(0, "10.00"), point(60, "25.50")]))
        #expect(up.caption(in: .currency(code: "USD")) == "$25.50 · ▲ $15.50 across 2 readings")

        let down = try #require(BalanceSparklinePresentation.make(
            from: [point(0, "210.00"), point(60, "179.50")]))
        #expect(down.caption(in: .currency(code: "USD")) == "$179.50 · ▼ $30.50 across 2 readings")
    }

    /// Every figure is the same, so there was no movement to describe.
    @Test("a flat series is said as unchanged, not as a zero change")
    func flatIsSaidAsUnchanged() throws {
        let p = try #require(BalanceSparklinePresentation.make(
            from: [point(0, "25.00"), point(60, "25.00")]))
        #expect(p.caption(in: .currency(code: "USD")) == "Unchanged at $25.00 across 2 readings")
    }

    /// A count stays a count: the caption never words credits as money, and a
    /// credit series never picks up a currency symbol from a neighbour.
    @Test("a credit series is captioned in credits")
    func creditCaptionKeepsTheUnit() throws {
        let p = try #require(BalanceSparklinePresentation.make(
            from: [point(0, "500"), point(60, "600")]))
        #expect(p.caption(in: .credits(name: "credits"))
                == "600 credits · ▲ 100 credits across 2 readings")
        #expect(BalanceSeries.Unit.credits(name: "credits").format(500) == "500 credits")
    }
}
