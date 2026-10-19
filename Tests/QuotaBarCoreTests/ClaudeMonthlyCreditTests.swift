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

    @Test("reconnecting rejects an old monthly read even for the same query")
    func connectionGenerationRejectsOldRead() throws {
        let query = "/api/quirky-lollipop/link-state?organization_uuid=fixture&include_candidates=false"
        let old = #"{"status":"linked","monthly_credit_usd":"10.00"}"#
        let current = #"{"status":"linked","monthly_credit_usd":"25.00"}"#
        var state = ClaudeMonthlyCreditSessionState()
        state.observe(text: old, query: query, retryAfter: "600", now: now)
        let generation = state.generation
        state.reset()
        #expect(state.query == nil)
        #expect(state.credit == nil)
        #expect(state.attemptedAt == nil)
        #expect(state.retryNotBefore == nil)
        state.observe(text: current, query: query, retryAfter: nil, now: now)
        state.completeRead(text: old, query: query, generation: generation, now: now)
        #expect(state.credit?.amountUSD == 25)
        #expect(state.retryNotBefore == nil)
        // An organisation change in the same session also invalidates the
        // prior query's completion without throwing away the new reading.
        state.completeRead(text: old, query: query + "-old", generation: state.generation, now: now)
        #expect(state.credit?.amountUSD == 25)
    }

    @Test("failed billing reads remove the entitlement and keep Retry-After")
    func failedReadClearsMonthlyCredit() {
        var state = ClaudeMonthlyCreditSessionState()
        let query = "/api/quirky-lollipop/link-state?organization_uuid=fixture&include_candidates=false"
        state.observe(text: #"{"status":"linked","monthly_credit_usd":"25.00"}"#,
                      query: query, retryAfter: nil, now: now)
        #expect(state.credit != nil)
        state.completeRead(text: #"{"_retryAfter":"600"}"#, query: query,
                           generation: state.generation, now: now)
        #expect(state.credit == nil)
        #expect(state.retryNotBefore == now.addingTimeInterval(600))
        state.observe(text: #"{"status":"linked","monthly_credit_usd":"25.00"}"#,
                      query: query, retryAfter: nil, now: now)
        state.completeRead(text: nil, query: query, generation: state.generation, now: now)
        #expect(state.credit == nil)
        #expect(state.retryNotBefore == nil)
    }

    @Test("a missing WebKit callback reaches the injected timeout and rejects late results")
    @MainActor
    func webReadIsBounded() async {
        let evaluation = ClaudeMonthlyCreditEvaluation()
        let outcome = await withDeadline(seconds: 5) {
            await evaluation.value(waitForTimeout: {}) { _ in }
        }
        if case .success(let result) = outcome { #expect(result == nil) }
        else { Issue.record("WebKit callback gate did not release on its own timeout") }
        evaluation.finish("late response")
        // Reusing a resolved gate cannot accept a callback from the old read.
        #expect(await evaluation.value(start: { $0("another late response") }) == nil)
    }

    @Test("cancelling a pending WebKit read releases its caller")
    @MainActor
    func webReadCancellation() async {
        let evaluation = ClaudeMonthlyCreditEvaluation()
        let (stream, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await evaluation.value(waitForTimeout: { try await Task.sleep(for: .seconds(60)) }) { _ in
                signal.yield(())
            }
        }
        for await _ in stream { break }
        signal.finish()
        task.cancel()
        let outcome = await withDeadline(seconds: 5) { await task.value }
        // Release a deliberately broken mutant too, so a rejected mutation
        // never leaves an orphaned continuation behind in the test process.
        evaluation.finish("late response")
        if case .success(let result) = outcome { #expect(result == nil) }
        else { Issue.record("Cancelling WebKit did not release its caller") }
    }
}
