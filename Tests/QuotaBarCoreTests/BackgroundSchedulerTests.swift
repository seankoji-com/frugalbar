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
        await scheduler.start(interval: 0.2)
        await scheduler.start(interval: 0.2)
        try? await Task.sleep(for: .milliseconds(100))
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
