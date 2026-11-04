import Foundation
import Testing
@testable import QuotaBarUI
import QuotaBarCore

/// A money row prints its figure once, in the value chip. The line under the
/// name says what that figure is, and must follow the chip's own choice of
/// figure: naming a "spent" or "left of" chip as a balance would put the wrong
/// label on real money.
@MainActor
@Suite("Money row caption")
struct MetricRowMoneyCaptionTests {

    private func snapshot(_ metric: MetricType, basis: CurrencyBasis? = nil,
                          status: ProviderStatus = .measured(.none)) -> QuotaSnapshot {
        var s = QuotaSnapshot(
            id: "openrouter", vendorId: .openrouter, displayName: "OpenRouter",
            category: .apiSpendAndCredits, metric: metric,
            status: status, resetsAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0), auxiliaryInfo: nil,
            row1: nil, row2: nil
        )
        s.currencyBasis = basis
        return s
    }

    @Test("a bare balance is named by its basis, or as a balance")
    func bareBalanceIsNamed() {
        let balance = MetricType.currency(balance: 24.61, limit: nil, spent: nil, currencyCode: "USD")
        #expect(MetricRowView.moneyCaption(for: snapshot(balance, basis: .accountCredit)) == "Account credit")
        #expect(MetricRowView.moneyCaption(for: snapshot(balance)) == "Balance")
    }

    @Test("a capped or spend figure carries its own words in the chip")
    func otherFiguresAreNotRelabelled() {
        #expect(MetricRowView.moneyCaption(for: snapshot(
            .currency(balance: 5, limit: 20, spent: nil, currencyCode: "USD"), basis: .keySpendCap)) == nil)
        #expect(MetricRowView.moneyCaption(for: snapshot(
            .currency(balance: 0, limit: nil, spent: 12, currencyCode: "USD"), basis: .lifetimeSpend)) == nil)
    }

    @Test("an unmeasured row names nothing")
    func unmeasuredRowIsSilent() {
        let balance = MetricType.currency(balance: 24.61, limit: nil, spent: nil, currencyCode: "USD")
        #expect(MetricRowView.moneyCaption(
            for: snapshot(balance, status: .unavailable(.notConfigured))) == nil)
    }
}
