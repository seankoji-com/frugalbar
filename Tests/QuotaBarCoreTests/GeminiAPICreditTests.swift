import Testing
import Foundation
@testable import QuotaBarCore

@Suite("Configured Gemini API credit")
struct GeminiAPICreditTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func credit() throws -> GeminiAPICredit {
        try #require(GeminiAPICredit(
            currencyCode: "aud",
            prepaidBalance: Decimal(string: "12")!,
            monthlyCredit: Decimal(string: "7.50")!,
            monthlySpendCap: Decimal(string: "25")!,
            configuredAt: now))
    }

    @Test("the account's own figures are kept exact, in its own currency")
    func keepsConfiguredFigures() throws {
        let credit = try credit()
        #expect(credit.currencyCode == "AUD")
        #expect(credit.prepaidBalance == Decimal(string: "12"))
        #expect(credit.monthlyCredit == Decimal(string: "7.50"))
        #expect(credit.monthlySpendCap == Decimal(string: "25"))
        #expect(credit.configuredAt == now)
    }

    @Test("only a real money figure, in a real currency code, can be configured")
    func refusesInvalidFigures() {
        #expect(GeminiAPICredit(currencyCode: "AUD", configuredAt: now) == nil)
        #expect(GeminiAPICredit(currencyCode: "", prepaidBalance: 1, configuredAt: now) == nil)
        #expect(GeminiAPICredit(currencyCode: "AUDX", prepaidBalance: 1, configuredAt: now) == nil)
        #expect(GeminiAPICredit(currencyCode: "A1D", prepaidBalance: 1, configuredAt: now) == nil)
        // The monthly grant cannot be negative, and a zero cap would refuse
        // every request; it is not a cap.
        #expect(GeminiAPICredit(currencyCode: "AUD", monthlyCredit: -1, configuredAt: now) == nil)
        #expect(GeminiAPICredit(currencyCode: "AUD", prepaidBalance: 1,
                                monthlySpendCap: 0, configuredAt: now) == nil)
        // An empty prepay account is a real state, not a missing figure, and
        // Google documents a billing lag that can overdraw it.
        #expect(GeminiAPICredit(currencyCode: "AUD", prepaidBalance: 0, configuredAt: now) != nil)
        // The cap may be the only figure: the popover draws it as the API
        // budget, so a user who wants just that does not need a dummy balance.
        #expect(GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 25,
                                configuredAt: now)?.monthlySpendCap == 25)
        let overdrawn = GeminiAPICredit(currencyCode: "AUD", prepaidBalance: -5,
                                        configuredAt: now)
        #expect(overdrawn?.prepaidBalance == -5)
    }

    @Test("an amount field is parsed whole, never by its leading prefix")
    func amountParsing() {
        #expect(GeminiAPICredit.amount(from: "") == .empty)
        #expect(GeminiAPICredit.amount(from: "   ") == .empty)
        #expect(GeminiAPICredit.amount(from: "12") == .value(12))
        #expect(GeminiAPICredit.amount(from: "14.50") == .value(Decimal(string: "14.50")!))
        #expect(GeminiAPICredit.amount(from: "1,234.50")
            == .value(Decimal(string: "1234.50")!))
        #expect(GeminiAPICredit.amount(from: "-5") == .value(-5))
        #expect(GeminiAPICredit.amount(from: " 30 ") == .value(30))
        // Each of these was accepted by `Decimal(string:)` as a prefix and
        // saved a wrong figure before this rule existed.
        for invalid in ["1,234.50x", "12,50", "30abc", "0.1.2", "1e3", "1.", ".5", "--5", "1 234"] {
            #expect(GeminiAPICredit.amount(from: invalid) == .invalid)
        }
    }

    @Test("a decoded blob is validated again, so a corrupt save draws nothing")
    func decodeValidates() throws {
        let encoded = try JSONEncoder().encode(try credit())
        #expect(try JSONDecoder().decode(GeminiAPICredit.self, from: encoded) == (try credit()))

        let overdrawn = Data(#"""
            {"currencyCode":"AUD","prepaidBalance":-5,"configuredAt":0}
            """#.utf8)
        #expect(try JSONDecoder().decode(GeminiAPICredit.self, from: overdrawn)
            .prepaidBalance == -5)
        let negativeGrant = Data(#"""
            {"currencyCode":"AUD","monthlyCredit":-5,"configuredAt":0}
            """#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GeminiAPICredit.self, from: negativeGrant)
        }
        let noFigures = Data(#"""
            {"currencyCode":"AUD","configuredAt":0}
            """#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GeminiAPICredit.self, from: noFigures)
        }
    }

    @Test("the store round-trips in its own suite and clears on nil")
    func storeRoundTrip() throws {
        let name = "frugalbar.tests.gemini-api-credit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(GeminiAPICreditStore.load(preferences: defaults) == nil)
        let configured = try credit()
        GeminiAPICreditStore.save(configured, preferences: defaults)
        #expect(GeminiAPICreditStore.load(preferences: defaults) == configured)
        GeminiAPICreditStore.save(nil, preferences: defaults)
        #expect(GeminiAPICreditStore.load(preferences: defaults) == nil)
    }

    @Test("a configured credit is not a quota, a bar or a balance-history series")
    func staysOutOfQuotaMaths() throws {
        var snapshot = QuotaSnapshot(
            id: "gemini", vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.25, label: "5H", windowLength: QuotaWindow.fiveHours),
            row2: DualBarMetrics(primaryFraction: 0.4, label: "WK", windowLength: QuotaWindow.week))
        let fraction = snapshot.consumptionFraction
        let bars = snapshot.quotaBars
        let apiCredits = snapshot.apiCredits
        let series = BalanceSeries.all(of: snapshot)

        snapshot.geminiAPICredit = try credit()

        #expect(snapshot.consumptionFraction == fraction)
        #expect(snapshot.quotaBars == bars)
        #expect(snapshot.apiCredits == apiCredits)
        #expect(BalanceSeries.all(of: snapshot) == series)
        #expect(BalanceSeries.all(of: snapshot).isEmpty)
        #expect(!BalanceSeries.seriesIDs(in: [snapshot]).contains { $0.contains("gemini") })
        #expect(snapshot.status == .measured(.none))
    }
}
