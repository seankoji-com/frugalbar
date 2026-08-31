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

    @Test("URLError(.notConnectedToInternet) maps to .offline")
    func urlErrorNotConnectedToInternetMapsToOffline() async {
        let outcome: DeadlineOutcome<String> = await withDeadline(seconds: 2.0) {
            throw URLError(.notConnectedToInternet)
        }
        switch outcome {
        case .success: Issue.record("expected failure")
        case .failure(let reason): #expect(reason == .offline)
        }
    }

    @Test("URLError(.dnsLookupFailed) maps to .offline")
    func urlErrorDnsLookupFailedMapsToOffline() async {
        let outcome: DeadlineOutcome<String> = await withDeadline(seconds: 2.0) {
            throw URLError(.dnsLookupFailed)
        }
        switch outcome {
        case .success: Issue.record("expected failure")
        case .failure(let reason): #expect(reason == .offline)
        }
    }

    @Test("URLError(.timedOut) maps to .timedOut")
    func urlErrorTimedOutMapsCorrectly() async {
        let outcome: DeadlineOutcome<String> = await withDeadline(seconds: 2.0) {
            throw URLError(.timedOut)
        }
        switch outcome {
        case .success: Issue.record("expected failure")
        case .failure(let reason): #expect(reason == .timedOut)
        }
    }

    @Test("URLError(.badServerResponse) maps to .badResponse")
    func urlErrorBadServerResponseMapsToBadResponse() async {
        let outcome: DeadlineOutcome<String> = await withDeadline(seconds: 2.0) {
            throw URLError(.badServerResponse)
        }
        switch outcome {
        case .success: Issue.record("expected failure")
        case .failure(let reason): #expect(reason == .badResponse)
        }
    }
}

// MARK: - Why this is not a TaskGroup

/// `withTaskGroup` awaits every child before returning, so an operation that
/// cannot observe cancellation would hold the deadline open indefinitely. This
/// suite pins the behaviour that motivates the unstructured implementation:
/// the deadline fires on time even when the work is genuinely uncancellable.
@Suite("withDeadline — uncancellable work")
struct DeadlineUncancellableTests {

    /// Blocks a background thread outright. `Task.cancel()` has no effect on it,
    /// which is exactly the case a structured race cannot escape.
    private func blockingWork(seconds: TimeInterval) async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: seconds)
                continuation.resume(returning: 42)
            }
        }
    }

    @Test("the deadline fires even though the operation ignores cancellation")
    func timesOutUncancellableWork() async {
        let started = Date()
        let outcome = await withDeadline(seconds: 0.2) {
            await blockingWork(seconds: 3.0)
        }
        let elapsed = Date().timeIntervalSince(started)

        guard case .failure(let reason) = outcome else {
            Issue.record("expected a timeout, got \(outcome)")
            return
        }
        #expect(reason == .timedOut)
        // Must return on the deadline, not after the 3s blocking sleep.
        #expect(elapsed < 1.5, "took \(elapsed)s — the deadline did not preempt blocking work")
    }

    @Test("uncancellable work that finishes in time still succeeds")
    func fastBlockingWorkSucceeds() async {
        let outcome = await withDeadline(seconds: 2.0) {
            await blockingWork(seconds: 0.05)
        }
        guard case .success(let value) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(value == 42)
    }
}
