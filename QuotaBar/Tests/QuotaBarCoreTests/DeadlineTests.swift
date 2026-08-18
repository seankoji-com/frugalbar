import Testing
import Foundation
@testable import QuotaBarCore

struct DeadlineTests {

    @Test("fast work completes with .success before the deadline")
    func fastWorkSucceeds() async {
        let outcome = await withDeadline(seconds: 2.0) {
            "ok"
        }
        switch outcome {
        case .success(let value): #expect(value == "ok")
        case .failure(let reason): Issue.record("expected success, got failure(\(reason))")
        }
    }

    @Test("slow work is cut off with .failure(.timedOut)")
    func slowWorkTimesOut() async {
        let outcome = await withDeadline(seconds: 0.1) {
            try await Task.sleep(for: .seconds(5))
            return "too slow"
        }
        switch outcome {
        case .success(let value): Issue.record("expected timeout, got success(\(value))")
        case .failure(let reason): #expect(reason == .timedOut)
        }
    }

    @Test("a thrown ProviderError maps to its own reason, not to a generic timeout")
    func thrownProviderErrorMapsToItsReason() async {
        let outcome: DeadlineOutcome<String> = await withDeadline(seconds: 2.0) {
            throw ProviderError.credentialRejected
        }
        switch outcome {
        case .success: Issue.record("expected failure")
        case .failure(let reason): #expect(reason == .credentialRejected)
        }
    }

    @Test("a thrown badResponse ProviderError maps to .badResponse")
    func thrownBadResponseMapsCorrectly() async {
        let outcome: DeadlineOutcome<String> = await withDeadline(seconds: 2.0) {
            throw ProviderError.badResponse
        }
        switch outcome {
        case .success: Issue.record("expected failure")
        case .failure(let reason): #expect(reason == .badResponse)
        }
    }
}
