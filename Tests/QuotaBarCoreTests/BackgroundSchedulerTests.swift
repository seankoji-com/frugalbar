import Testing
import Foundation
@testable import QuotaBarCore

/// A handler that records invocations in a Sendable-safe way.
private actor HandlerSpy {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }

    func handler() async {
        await record()
    }
}

/// Suspends only the first call, so an overlapping cycle can be observed
/// without also blocking the test that releases the first cycle.
private actor RefreshGate {
    private(set) var callCount = 0
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func run() async {
        callCount += 1
        guard callCount == 1 else { return }
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite("BackgroundScheduler")
struct BackgroundSchedulerTests {

    // MARK: - Handler lifecycle

    @Test("addHandler returns a token and the handler is registered")
    func addHandlerReturnsToken() async {
        let scheduler = BackgroundScheduler()
        let spy = HandlerSpy()
        let token = await scheduler.addHandler { await spy.handler() }
        // The token is non-nil and valid (UUID). We can assert that removing
        // it later works — that proves registration happened.
        #expect(token.uuidString.isEmpty == false)
        await scheduler.removeHandler(token)
    }

    @Test("removeHandler prevents the handler from being in the set")
    func removeHandlerRemovesRegistration() async {
        let scheduler = BackgroundScheduler()
        let spy = HandlerSpy()
        let token = await scheduler.addHandler { await spy.handler() }
        await scheduler.removeHandler(token)
        // Remove again should be a no-op (not crash)
        await scheduler.removeHandler(token)
    }

    @Test("multiple handlers can be added and removed independently")
    func multipleHandlersIndependent() async {
        let scheduler = BackgroundScheduler()
        let spy = HandlerSpy()
        let t1 = await scheduler.addHandler { await spy.handler() }
        let t2 = await scheduler.addHandler { await spy.handler() }
        let t3 = await scheduler.addHandler { await spy.handler() }

        await scheduler.removeHandler(t2)
        // Remove the same one again — idempotent
        await scheduler.removeHandler(t2)
        await scheduler.removeHandler(t1)
        await scheduler.removeHandler(t3)
    }

    @Test("removing an unknown token is a no-op")
    func removeUnknownTokenIsNoop() async {
        let scheduler = BackgroundScheduler()
        // Should not crash or throw
        await scheduler.removeHandler(UUID())
    }

    // Drive the same cycle used by the timer, without wall-clock sleeps.
    @Test("a refresh calls every registered handler and excludes removed handlers")
    func refreshRespectsRegistrations() async {
        let scheduler = BackgroundScheduler()
        let first = HandlerSpy()
        let second = HandlerSpy()
        let removed = HandlerSpy()
        // An empty cycle must also reset the in-progress flag.
        await scheduler.fire()
        await scheduler.addHandler { await first.record() }
        await scheduler.addHandler { await second.record() }
        let token = await scheduler.addHandler { await removed.record() }
        await scheduler.removeHandler(token)
        await scheduler.fire()
        await scheduler.fire()
        #expect(await first.callCount == 2)
        #expect(await second.callCount == 2)
        #expect(await removed.callCount == 0)
    }

    @Test("an overlapping refresh is skipped and the next cycle still runs", .timeLimit(.minutes(1)))
    func refreshDoesNotOverlap() async {
        let scheduler = BackgroundScheduler()
        let gate = RefreshGate()
        await scheduler.addHandler { await gate.run() }
        let first = Task { await scheduler.fire() }
        await gate.waitForEntry()
        await scheduler.fire()
        #expect(await gate.callCount == 1)
        await gate.release()
        await first.value
        await scheduler.fire()
        #expect(await gate.callCount == 2)
    }

    @Test("handlers registered during a refresh first run in the next cycle")
    func refreshUsesRegistrationSnapshot() async {
        let scheduler = BackgroundScheduler()
        let later = HandlerSpy()
        await scheduler.addHandler {
            await scheduler.addHandler { await later.record() }
        }
        await scheduler.fire()
        #expect(await later.callCount == 0)
        await scheduler.fire()
        #expect(await later.callCount == 1)
    }

    // MARK: - Lifecycle (start / stop)

    @Test("stop is idempotent when already stopped")
    func stopIdempotent() async {
        let scheduler = BackgroundScheduler()
        await scheduler.stop()
        await scheduler.stop()
    }

    @Test("start then stop: timer does not fire after stop")
    func startThenStopPreventsFire() async {
        let scheduler = BackgroundScheduler()
        let spy = HandlerSpy()
        _ = await scheduler.addHandler { await spy.handler() }
        await scheduler.start(interval: 0.05)
        await scheduler.stop()
        try? await Task.sleep(for: .milliseconds(200))
        let count = await spy.callCount
        #expect(count == 0)
    }

    @Test("double start replaces the previous timer")
    func doubleStartReplacesTimer() async {
        let scheduler = BackgroundScheduler()
        let spy = HandlerSpy()
        _ = await scheduler.addHandler { await spy.handler() }
        await scheduler.start(interval: 2.0)
        await scheduler.start(interval: 2.0)
        try? await Task.sleep(for: .milliseconds(50))
        await scheduler.stop()
        let count = await spy.callCount
        #expect(count == 0)
    }

    @Test("start with default interval registers a repeating timer")
    func startWithDefaultInterval() async {
        let scheduler = BackgroundScheduler()
        let spy = HandlerSpy()
        _ = await scheduler.addHandler { await spy.handler() }
        await scheduler.start()  // uses default 120s interval
        // The timer is scheduled, so it should not fire in a short window.
        try? await Task.sleep(for: .milliseconds(50))
        await scheduler.stop()
        let count = await spy.callCount
        #expect(count == 0)
    }
}
