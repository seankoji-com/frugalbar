import Foundation
import Testing
@testable import QuotaBarCore

@Suite("Claude monthly API credit")
struct ClaudeMonthlyCreditTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("monthly grant preserves entitlement and next date without inventing a balance")
    func publishedGrant() async throws {
        let data = Data(#"{"status":"linked","monthly_credit_usd":"123.45","next_grant_at":"2027-02-15T14:49:22Z","granted_total_usd":"999.00","grant_count":9}"#.utf8)
        let credit = try #require(ClaudeMonthlyCredit.decode(data, now: now))
        #expect(credit.amountUSD == Decimal(string: "123.45"))
        #expect(credit.nextGrantAt == ISO8601DateFormatter().date(from: "2027-02-15T14:49:22Z"))
        #expect(credit.measuredAt == now)
        #expect(credit.line == "Monthly API credit: $123.45 per month")
        #expect(credit.detail(now: now)?.contains("Next credit") == true)
        #expect(credit.detail(now: now.addingTimeInterval(300))?.contains("Stale") == true)
        let provider = ClaudeQuotaProvider(apiKey: "", monthlyCredit: { _ in credit })
        let snapshot = try await provider.fetchSnapshot(now: now)
        #expect(snapshot.monthlyAPICredit == credit)
        #expect(snapshot.apiCredits.isEmpty)
        #expect(snapshot.consumptionFraction == nil)
        #expect(snapshot.quotaBars.isEmpty)
        #expect(snapshot.status == .unavailable(.notConfigured))
        #expect(BalanceSeries.of(snapshot) == nil)
    }

    @Test("absent, unlinked, ended or invalid monthly grants yield no entitlement")
    func absentGrant() throws {
        for body in ["{}", #"{"status":"linked"}"#,
                     #"{"status":"unlinked","monthly_credit_usd":"123.45"}"#,
                     #"{"status":"linked","monthly_credit_usd":"123.45","grants_held_reason":"program_ended"}"#,
                     #"{"status":"linked","monthly_credit_usd":"1..2"}"#,
                     #"{"status":"linked","monthly_credit_usd":"-1"}"#,
                     #"{"status":"linked","monthly_credit_usd":"NaN"}"#,
                     #"{"status":"linked","granted_total_usd":"999"}"#] {
            #expect(try ClaudeMonthlyCredit.decode(Data(body.utf8), now: now) == nil)
        }
        let noDate = try #require(ClaudeMonthlyCredit.decode(
            Data(#"{"status":"linked","monthly_credit_usd":"0.00"}"#.utf8), now: now))
        #expect(noDate.amountUSD == 0)
        #expect(noDate.nextGrantAt == nil)
        #expect(noDate.detail(now: now) == nil)
        let due = try #require(ClaudeMonthlyCredit.decode(Data(#"{"status":"linked","monthly_credit_usd":"25","grant_due":true,"next_grant_at":"2027-02-15T14:49:22Z"}"#.utf8), now: now))
        #expect(due.nextGrantAt == nil)
    }
}
