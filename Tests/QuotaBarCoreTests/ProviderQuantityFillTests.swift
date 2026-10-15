import Foundation
import Testing
@testable import QuotaBarCore

/// Serves GitHub's rate-limit body for this file's tests alone, so its
/// handler never races another suite's stub.
private final class QuantityStub: URLProtocol {
    nonisolated(unsafe) static var hits = 0
    static let lock = NSLock()
    static let body = #"""
    {"resources":{"core":{"limit":5000,"remaining":4500,"reset":1792025000},"graphql":{"limit":5000,"remaining":1000,"reset":1792025500}}}
    """#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.hits += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuantityStub.self]
        return URLSession(configuration: configuration)
    }
}

@Suite("Provider quantity fields", .serialized)
struct ProviderQuantityFillTests {

    @Test("DualBarMetrics gains only the four quantity fields")
    func dualBarMetricsGainsOnlyTheFourQuantityFields() {
        let labels = Mirror(reflecting: DualBarMetrics(primaryFraction: nil, label: "x")).children.compactMap(\.label)
        #expect(labels == [
            "primaryFraction", "expectedPaceFraction", "secondaryFraction", "label", "blockedColor", "isBlocked",
            "measuresElapsedTimeOnly", "usedText", "resetText", "resetsAt", "windowLength",
            "quantityUsed", "quantityRemaining", "quantityLimit", "quantityUnit",
        ])
    }

    @Test("only the providers in the table's last column fill quantities")
    func onlyTheTabledProvidersFillQuantities() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QuotaBarCore/Providers")
        let sources = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        let filling = try sources.filter { file in
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            return source.contains("quantity")
        }
        #expect(Set(filling) == [
            "GitHubProviders.swift", "GrokQuotaProvider.swift", "KiroQuotaProvider.swift",
            "DevPassQuotaProvider.swift", "CommandCodeQuotaProvider.swift",
        ])
    }

    @Test("Kiro fills used and limit in credits on every row, from the figures behind its text")
    func kiroFillsEveryRow() throws {
        let snapshot = try #require(try ProviderBranchSnapshots.kiro().first)
        let (plan, bonus, overage) = (try #require(snapshot.row1), try #require(snapshot.row2), try #require(snapshot.row3))
        // Plan usage is the total less overage: 60.5 − 10.5 = 50.
        #expect(plan.quantityUsed == 50 && plan.quantityLimit == 50 && plan.quantityUnit == "credits")
        #expect(plan.usedText == "50/50 credits used")
        #expect(bonus.quantityUsed == 25 && bonus.quantityLimit == 100 && bonus.quantityUnit == "credits")
        #expect(overage.quantityUsed == 10.5 && overage.quantityLimit == 1000 && overage.quantityUnit == "credits")
        for row in [plan, bonus, overage] { #expect(row.quantityRemaining == nil) }
        // An overage figure the vendor did not send stays nil in the quantity, beside the cap it did send.
        let unreported = try #require(try ProviderBranchSnapshots.kiroEnabledOverage(reported: nil).row3)
        #expect(unreported.quantityUsed == nil && unreported.quantityLimit == 1000 && unreported.quantityUnit == "credits")
    }

    @Test("Grok fills the on-demand row's used and cap in USD, and nothing on the plan row")
    func grokFillsOnDemandOnly() throws {
        let snapshots = try ProviderBranchSnapshots.grok()
        for snapshot in snapshots {
            let onDemand = try #require(snapshot.row2)
            #expect(onDemand.label == "OD")
            #expect(onDemand.quantityUnit == "USD")
            #expect(snapshot.row1?.quantityUsed == nil && snapshot.row1?.quantityUnit == nil)
        }
        #expect(snapshots[0].row2?.quantityUsed == 5 && snapshots[0].row2?.quantityLimit == 20)
        #expect(snapshots[1].row2?.quantityUsed == 10.5 && snapshots[1].row2?.quantityLimit == 21)
        // The daily plan is 86400 s; a plan with no published start has no length.
        #expect(snapshots[0].row1?.windowLength == 86400)
        #expect(snapshots[1].row1?.windowLength == nil)
    }

    @Test("DevPass fills credits on its plan, USD on its spend rows, and never sets a basis")
    func devPassFillsEachBranch() throws {
        let (plan, capped, uncapped) = try { () throws -> (QuotaSnapshot, QuotaSnapshot, QuotaSnapshot) in
            let all = try ProviderBranchSnapshots.devPass()
            return (all[0], all[1], all[2])
        }()
        #expect(plan.row1?.quantityUsed == 20 && plan.row1?.quantityLimit == 80 && plan.row1?.quantityUnit == "credits")
        #expect(capped.row1?.quantityUsed == 10 && capped.row1?.quantityLimit == 25 && capped.row1?.quantityUnit == "USD")
        #expect(uncapped.row1?.quantityUsed == 3.5 && uncapped.row1?.quantityLimit == nil && uncapped.row1?.quantityUnit == "USD")
        // Basis handling is the exporter's: the uncapped snapshot keeps a nil basis.
        #expect(uncapped.currencyBasis == nil)
        #expect(capped.currencyBasis == .keySpendCap)
        // Usage the vendor did not send stays nil in the quantity, beside the limit it did send.
        let unreported = Array(try ProviderBranchSnapshots.devPass().suffix(2))
        #expect(unreported[0].row1?.quantityUsed == nil && unreported[0].row1?.quantityLimit == 25)
        #expect(unreported[1].row1?.quantityUsed == nil && unreported[1].row1?.quantityUnit == "USD")
    }

    @Test("Command Code fills capped windows and the total, and only remaining on the remaining-only row")
    func commandCodeFillsEachBranch() throws {
        let all = try ProviderBranchSnapshots.commandCode()
        let capped = all[0]
        #expect(capped.row1?.quantityUsed == 1.25 && capped.row1?.quantityLimit == 5 && capped.row1?.quantityUnit == "credits")
        #expect(capped.row2?.quantityUsed == 5 && capped.row2?.quantityLimit == 20)
        // Pro's 80-credit allowance with 60 left: 20 used of a total of 80.
        #expect(capped.row3?.quantityUsed == 20 && capped.row3?.quantityLimit == 80)
        for (snapshot, remaining) in [(all[1], Decimal(42.5)), (all[2], Decimal(0))] {
            let row = try #require(snapshot.row3)
            #expect(row.quantityRemaining == remaining)
            #expect(row.quantityUsed == nil && row.quantityLimit == nil)
            #expect(row.quantityUnit == "credits")
            #expect(row.primaryFraction == nil)
        }
    }

    @Test("GitHub fills remaining and limit per row: req/hr for REST, pts/hr for GraphQL")
    func gitHubFillsRemainingAndLimit() async throws {
        let (rest, graphql) = try await QuotaHTTP.$session.withValue(QuantityStub.session()) {
            (try await GitHubRestProvider(token: "quantity-fill-rest").fetchSnapshot(),
             try await GitHubGraphQLProvider(token: "quantity-fill-graphql").fetchSnapshot())
        }
        #expect(QuantityStub.lock.withLock { QuantityStub.hits } >= 1)
        #expect(rest.row1?.quantityRemaining == 4500 && rest.row1?.quantityLimit == 5000 && rest.row1?.quantityUnit == "req/hr")
        #expect(rest.row2?.quantityRemaining == 1000 && rest.row2?.quantityLimit == 5000 && rest.row2?.quantityUnit == "pts/hr")
        #expect(graphql.row1?.quantityRemaining == 1000 && graphql.row1?.quantityLimit == 5000 && graphql.row1?.quantityUnit == "pts/hr")
        for row in [rest.row1, rest.row2, graphql.row1] { #expect(row?.quantityUsed == nil) }
        // The standalone row keeps its existing label; the exporter only copies it.
        #expect(graphql.row1?.label == "REST")
    }
}

/// Snapshots built by the providers' own builders, one per branch they ship.
enum ProviderBranchSnapshots {
    static let now = Date(timeIntervalSince1970: 1_792_022_400)

    static func all() throws -> [QuotaSnapshot] {
        try kiro() + [kiroEnabledOverage(reported: nil)] + grok() + devPass() + commandCode()
    }

    static func kiro(overage: Bool = true) throws -> [QuotaSnapshot] {
        let body = """
        {"nextDateReset":1793404800,"overageConfiguration":{"overageStatus":"\(overage ? "ENABLED" : "DISABLED")"},
         "subscriptionInfo":{"subscriptionTitle":"KIRO PRO"},
         "usageBreakdownList":[{"resourceType":"CREDIT","currentUsageWithPrecision":60.5,
           "usageLimitWithPrecision":50,"currentOveragesWithPrecision":10.5,"overageCapWithPrecision":1000,
           "overageRate":0.04,"overageCharges":0.42,"currency":"USD","nextDateReset":1793404800,
           "bonuses":[{"currentUsage":25,"usageLimit":100,"expiresAt":1795000000,"status":"ACTIVE"}]}]}
        """
        let response = try JSONDecoder().decode(KiroQuotaProvider.UsageLimitsResponse.self, from: Data(body.utf8))
        return [KiroQuotaProvider.snapshot(from: response, provider: KiroQuotaProvider(), now: now)]
    }

    /// Overage switched on with a cap, and `currentOveragesWithPrecision` as
    /// given, or absent when nil: the live body sends `0.0` when there is no
    /// overage, so absence is not a zero.
    static func kiroEnabledOverage(reported currentOverages: String?) throws -> QuotaSnapshot {
        let overages = currentOverages.map { #""currentOveragesWithPrecision":\#($0),"# } ?? ""
        let body = """
        {"nextDateReset":1793404800,"overageConfiguration":{"overageStatus":"ENABLED"},
         "subscriptionInfo":{"subscriptionTitle":"KIRO PRO"},
         "usageBreakdownList":[{"resourceType":"CREDIT","currentUsageWithPrecision":40,
           "usageLimitWithPrecision":50,\(overages)"overageCapWithPrecision":1000,
           "overageRate":0.04,"currency":"USD","nextDateReset":1793404800}]}
        """
        let response = try JSONDecoder().decode(KiroQuotaProvider.UsageLimitsResponse.self, from: Data(body.utf8))
        return KiroQuotaProvider.snapshot(from: response, provider: KiroQuotaProvider(), now: now)
    }

    static func grok() throws -> [QuotaSnapshot] {
        func make(_ config: String) throws -> QuotaSnapshot {
            let response = try JSONDecoder().decode(GrokQuotaProvider.BillingResponse.self, from: Data(config.utf8))
            return GrokQuotaProvider.snapshot(from: try #require(response.config), tier: nil,
                                              provider: GrokQuotaProvider(accessToken: "tok"), now: now)
        }
        return [
            try make("""
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_DAILY","start":"2026-10-14T12:00:00+00:00",
              "end":"2026-10-15T12:00:00+00:00"},"creditUsagePercent":40.0,"onDemandCap":{"val":20},"onDemandUsed":{"val":5}}}
            """),
            try make("""
            {"config":{"billingPeriodEnd":"2026-10-20T00:00:00+00:00","onDemandCap":{"val":21},"onDemandUsed":{"val":10.5}}}
            """),
        ]
    }

    static func devPass() throws -> [QuotaSnapshot] {
        let bodies = [
            #"{"label":"key","usage":"0","limit":null,"devPlan":"lite","devPlanCreditsUsed":"20.00","devPlanCreditsLimit":"80.00","devPlanCreditsRemaining":"60.00"}"#,
            #"{"label":"key","usage":"10","limit":"25","devPlan":"none"}"#,
            #"{"label":"key","usage":"3.5","limit":null,"devPlan":"none"}"#,
            // The vendor sent no usage: capped, then uncapped.
            #"{"label":"key","limit":"25","devPlan":"none"}"#,
            #"{"label":"key","limit":null,"devPlan":"none"}"#,
        ]
        return try bodies.map {
            let key = try JSONDecoder().decode(DevPassQuotaProvider.KeyData.self, from: Data($0.utf8))
            return DevPassQuotaProvider.snapshot(from: key, provider: DevPassQuotaProvider(), now: now)
        }
    }

    static func commandCode() throws -> [QuotaSnapshot] {
        func make(_ body: String) throws -> QuotaSnapshot {
            let response = try #require(CommandCodeQuotaProvider.decode(
                CommandCodeQuotaProvider.CreditsResponse.self, from: Data(body.utf8)))
            return CommandCodeQuotaProvider.snapshot(from: response, provider: CommandCodeQuotaProvider(), now: now)
        }
        return [
            try make("""
            {"success":true,"credits":{"planId":"individual-pro","monthlyCredits":60,"purchasedCredits":0,"freeCredits":0},
             "windowLimits":{"limited":false,"fiveHour":{"used":1.25,"cap":5,"resetAt":1792040400000},
                             "weekly":{"used":5,"cap":20,"resetAt":1792627200000}}}
            """),
            try make(#"{"success":true,"credits":{"planId":"individual-provider","monthlyCredits":42.5}}"#),
            try make(#"{"success":true,"credits":{"planId":"individual-provider","monthlyCredits":0}}"#),
        ]
    }
}
