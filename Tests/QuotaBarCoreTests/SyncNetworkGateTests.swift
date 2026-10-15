import Foundation
import Testing
@testable import QuotaBarCore

private struct SimulatedCrash: Error {}

// Review round 3 (S2-N5, S2-R8, S2-R9) found runtime state running ahead of
// durable state after a failed write. The rule now: every request passes the
// gate immediately before it is sent, and an outcome whose write fails holds
// back every request until a later write lands. A relaunch meanwhile is a
// crash at that point, which the saved record keeps safe.
@Suite("Sync network gate and lost writes (REQ-MAC-STOP, REQ-MAC-OAUTH c, REQ-MAC-FILE c)")
struct SyncNetworkGateTests {

    private static let rejected = SyncHTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))

    // MARK: S2-N5

    @Test("Stop whose write fails while a metadata read is open: the attempt sends nothing more, and Stop finishes once writes land")
    func failedStopDuringMetadataSendsNothingMore() async throws {
        let harness = try await SyncHarness.active()
        let ownId = try harness.secrets.read(SyncSecretAccount.publisherId)
        let ownFile = await harness.google.seed(publisherId: ownId, created: harness.clock.now())
        await harness.google.configure { $0.metadataHolds = 1 }
        await harness.publisher.submit(SyncFakes.source())
        let driver = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })
        let requests = await harness.google.requests.count

        harness.store.failWrites()
        await harness.publisher.stop()
        #expect(await harness.publisher.status().lastError == SyncPublisher.stateNotSavedMessage)
        await harness.google.releaseAll()
        await driver.value

        #expect(await harness.google.requests.count == requests)
        #expect(await harness.google.uploads.isEmpty)
        #expect(harness.store.saved.phase == .active)
        await harness.run(for: 10 * 60)
        #expect(await harness.google.requests.count == requests)

        harness.store.failWrites(false)
        await harness.run(for: 30 * 60)
        #expect(await harness.publisher.status().phase == .stopped)
        #expect(await harness.google.files[ownFile] == nil)
        #expect(await harness.google.uploads.isEmpty)
    }

    @Test("Stop whose write fails while an upload is in flight records its outcome but sends no verification read")
    func failedStopDuringUploadSendsNoVerification() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.status(500), .commitThenHang] }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(harness.store.saved.repairPending)

        harness.clock.advance(by: SyncPublisher.minimumInterval)
        let driver = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })
        harness.store.failWrites()
        await harness.publisher.stop()
        await harness.google.releaseAll()
        await driver.value

        let reads = await harness.google.requests.filter { $0.queryItems["alt"] == "media" }
        #expect(reads.isEmpty)
        #expect(await harness.google.uploads.count == 2)
        let requests = await harness.google.requests.count
        await harness.run(for: 10 * 60)
        #expect(await harness.google.requests.count == requests)

        harness.store.failWrites(false)
        await harness.run(for: 30 * 60)
        #expect(await harness.publisher.status().phase == .stopped)
        #expect(await harness.google.files.isEmpty)
        #expect(await harness.google.uploads.count == 2)
    }

    // MARK: S2-R8

    @Test("a terminal sign-in failure whose write is lost never sends that refresh token again, even after a relaunch")
    func lostTerminalAuthWriteNeverResendsTheToken() async throws {
        let harness = try await SyncHarness.active()
        harness.store.failWrites(after: 1)
        await harness.google.configure { $0.tokenResponses = [Self.rejected] }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(await harness.publisher.status().needsSignIn)
        #expect(harness.store.saved.needsSignIn == false)
        #expect(harness.store.saved.uploadStartedAt != nil)
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == nil)
        // Only the lost write is scheduled, not a publish.
        #expect(await harness.publisher.nextWakeup() == harness.clock.now().addingTimeInterval(SyncPublisher.stateRetryInterval))

        // Relaunch with storage recovered and the floor expired.
        harness.store.failWrites(false)
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        let relaunched = harness.relaunched()
        await relaunched.publisher.submit(SyncFakes.source())
        await relaunched.publisher.tick()
        #expect(await relaunched.publisher.status().needsSignIn)
        #expect(harness.store.saved.needsSignIn)
        #expect(await relaunched.publisher.nextWakeup() == nil)
        await relaunched.run(for: 30 * 60)
        #expect(await harness.google.tokenRequests == 1)
        #expect(await harness.google.uploads.isEmpty)
    }

    @Test("a terminal sign-in failure whose write is lost reaches disk on a later tick, and nothing is sent meanwhile")
    func lostTerminalAuthWriteIsRetried() async throws {
        let harness = try await SyncHarness.active()
        harness.store.failWrites(after: 1)
        await harness.google.configure { $0.tokenResponses = [Self.rejected] }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        await harness.run(for: 5 * 60)
        #expect(await harness.google.requests.count == 1)
        #expect(await harness.publisher.status().lastError == SyncPublisher.stateNotSavedMessage)

        harness.store.failWrites(false)
        await harness.run(for: 2 * 60)
        #expect(harness.store.saved.needsSignIn)
        #expect(harness.store.saved.uploadStartedAt == nil)
        #expect(await harness.publisher.nextWakeup() == nil)
        #expect(await harness.publisher.status().lastError != SyncPublisher.stateNotSavedMessage)
        #expect(await harness.google.requests.count == 1)
    }

    @Test("a terminal failure during cleanup whose write is lost is not retried with the same token after a relaunch")
    func lostCleanupAuthWriteNeverResendsTheToken() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let ownFile = try #require(await harness.google.files.keys.first)
        harness.clock.advance(by: 2 * 3600)
        await harness.google.configure { $0.tokenResponses = [Self.rejected] }
        // The stopping write and the settle step land; the paused cleanup does not.
        harness.store.failWrites(after: 2)
        await harness.publisher.stop()
        #expect(await harness.publisher.status().cleanupNeedsSignIn)
        #expect(harness.store.saved.cleanup?.authLost == false)
        let tokenRequests = await harness.google.tokenRequests

        harness.store.failWrites(false)
        let relaunched = harness.relaunched()
        await relaunched.publisher.resume()
        await relaunched.run(for: 15 * 60)
        #expect(await relaunched.publisher.status().cleanupNeedsSignIn)
        #expect(harness.store.saved.cleanup?.authLost == true)
        #expect(await harness.google.tokenRequests == tokenRequests)
        #expect(await harness.google.files[ownFile] != nil)
    }

    // MARK: S2-R9

    /// Publish at t=0, fail the material upload and all three forced ones,
    /// then the heartbeat at t=900, whose checkpoint lands and whose
    /// uncertain outcome does not.
    private func lostHeartbeatOutcome() async throws -> (SyncHarness, start: Date) {
        let harness = try await SyncHarness.active()
        let start = harness.clock.now()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        await harness.google.configure { $0.uploadModes = Array(repeating: .status(500), count: 8) }
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        for minute in [2, 4, 6, 8] {
            harness.clock.set(start.addingTimeInterval(Double(minute * 60)))
            await harness.publisher.tick()
        }
        #expect(harness.store.saved.forcedPublishes == SyncPublisher.maxForcedPublishes)
        harness.clock.set(start.addingTimeInterval(SyncPublisher.heartbeatInterval))
        harness.store.failWrites(after: 1)
        await harness.publisher.tick()
        #expect(await harness.google.uploads.count == 6)
        return (harness, start)
    }

    @Test("an uncertain heartbeat whose outcome is lost keeps its 15-minute deadline across a relaunch")
    func lostHeartbeatOutcomeKeepsItsDeadline() async throws {
        let (harness, start) = try await lostHeartbeatOutcome()
        #expect(harness.store.saved.lastHeartbeatAttemptAt == start.addingTimeInterval(SyncPublisher.heartbeatInterval))

        harness.store.failWrites(false)
        harness.clock.set(start.addingTimeInterval(1020))
        let relaunched = harness.relaunched()
        await relaunched.publisher.submit(SyncFakes.source())
        #expect(await relaunched.publisher.nextWakeup() == start.addingTimeInterval(2 * SyncPublisher.heartbeatInterval))
        await relaunched.publisher.tick()
        #expect(await harness.google.uploads.count == 6)
        let times = await relaunched.run(for: 15 * 60)
        #expect(times == [start.addingTimeInterval(2 * SyncPublisher.heartbeatInterval)])
    }

    @Test("an uncertain heartbeat whose outcome is lost holds every request until the write lands, then keeps the deadline")
    func lostHeartbeatOutcomeIsRetried() async throws {
        let (harness, start) = try await lostHeartbeatOutcome()
        let lost = start.addingTimeInterval(SyncPublisher.heartbeatInterval)
        #expect(await harness.publisher.nextWakeup() == lost.addingTimeInterval(SyncPublisher.stateRetryInterval))
        let requests = await harness.google.requests.count
        await harness.run(for: 3 * 60)
        #expect(await harness.google.requests.count == requests)

        harness.store.failWrites(false)
        await harness.run(for: 70)
        #expect(harness.store.saved.uploadStartedAt == nil)
        #expect(await harness.publisher.nextWakeup() == lost.addingTimeInterval(SyncPublisher.heartbeatInterval))
        #expect(await harness.google.requests.count == requests)
    }

    @Test("a heartbeat that cannot have landed gives its deadline back, so it is retried after the backoff")
    func failedHeartbeatRestoresItsDeadline() async throws {
        let harness = try await SyncHarness.active()
        let start = harness.clock.now()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        await harness.google.configure { $0.uploadModes = [.status(403)] }
        harness.clock.set(start.addingTimeInterval(SyncPublisher.heartbeatInterval))
        await harness.publisher.tick()
        #expect(await harness.google.uploads.count == 2)
        #expect(harness.store.saved.lastHeartbeatAttemptAt == nil)
        #expect(await harness.publisher.nextWakeup()
            == start.addingTimeInterval(SyncPublisher.heartbeatInterval + SyncPublisher.backoff(1)))
    }

    // MARK: The rule in general

    @Test("an upload outcome whose write fails holds back every request, retries the write each tick, then repairs")
    func lostOutcomeWriteHoldsEveryRequest() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.status(500)] }
        harness.store.failWrites(after: 1)
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let requests = await harness.google.requests.count
        #expect(await harness.publisher.status().lastError == SyncPublisher.stateNotSavedMessage)
        #expect(harness.store.saved.uploadStartedAt != nil)

        // A material change and the forced repair are both due; neither goes out.
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        await harness.run(for: 10 * 60)
        #expect(await harness.google.requests.count == requests)
        #expect(await harness.publisher.permits(.publish) == false)

        // The tick that lands the write goes on to the forced, verified publish.
        harness.store.failWrites(false)
        await harness.publisher.tick()
        #expect(await harness.publisher.permits(.publish))
        #expect(await harness.google.uploads.count == 2)
        #expect(await harness.google.requests.contains { $0.queryItems["alt"] == "media" })
        #expect(harness.store.saved.repairPending == false)
    }

    @Test("a confirmed repair upload whose write fails sends no verification read in the same attempt")
    func lostConfirmedWriteSendsNoVerification() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.status(500)] }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(harness.store.saved.repairPending)

        harness.clock.advance(by: SyncPublisher.minimumInterval)
        harness.store.failWrites(after: 1)
        await harness.publisher.tick()
        #expect(await harness.google.uploads.count == 2)
        #expect(await harness.google.requests.contains { $0.queryItems["alt"] == "media" } == false)
        #expect(harness.store.saved.uploadStartedAt != nil)

        harness.store.failWrites(false)
        await harness.run(for: 3 * 60)
        #expect(await harness.google.requests.contains { $0.queryItems["alt"] == "media" })
        #expect(harness.store.saved.repairPending == false)
    }

    @Test("a cleanup error whose write fails holds cleanup's requests until it lands")
    func lostCleanupWriteHoldsCleanup() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let ownFile = try #require(await harness.google.files.keys.first)
        harness.clock.advance(by: 2 * 3600)
        await harness.google.configure { $0.tokenFailure = URLError(.notConnectedToInternet) }
        harness.store.failWrites(after: 2)
        await harness.publisher.stop()
        #expect(await harness.publisher.permits(.cleanup) == false)
        let requests = await harness.google.requests.count
        await harness.google.configure { $0.tokenFailure = nil }
        await harness.run(for: 10 * 60)
        #expect(await harness.google.requests.count == requests)

        harness.store.failWrites(false)
        await harness.run(for: 20 * 60)
        #expect(await harness.publisher.status().phase == .stopped)
        #expect(await harness.google.files[ownFile] == nil)
    }

    @Test("a request with no publisher scope, or one the publisher refuses, is never sent")
    func gatedTransportWithholdsUnscopedRequests() async throws {
        let google = FakeGoogle(clock: FakeSyncClock())
        let gated = GatedSyncTransport(google)
        let request = SyncHTTPRequest(method: "GET", url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        await #expect(throws: SyncRequestWithheld.self) { _ = try await gated.send(request) }

        gated.bind { scope in scope == .publish }
        await #expect(throws: SyncRequestWithheld.self) { _ = try await gated.send(request) }
        await #expect(throws: SyncRequestWithheld.self) {
            _ = try await SyncNetworkScope.$current.withValue(.cleanup) { try await gated.send(request) }
        }
        #expect(await google.requests.isEmpty)
        _ = try await SyncNetworkScope.$current.withValue(.publish) { try await gated.send(request) }
        #expect(await google.requests.count == 1)
    }

    @Test("an attempt still open when Stop's cleanup begins sends nothing, even if cleanup is cut short")
    func openAttemptSendsNothingAfterStopping() async throws {
        let harness = try await SyncHarness.active()
        let ownId = try harness.secrets.read(SyncSecretAccount.publisherId)
        await harness.google.seed(publisherId: ownId, created: harness.clock.now())
        await harness.google.configure { $0.metadataHolds = 1 }
        await harness.publisher.submit(SyncFakes.source())
        let driver = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })
        let requests = await harness.google.requests.count

        // Stop's first write lands and the process "crashes" before settling.
        await harness.publisher.setStopCheckpoint { gap in
            if gap == .afterStoppingWrite { throw SimulatedCrash() }
        }
        await harness.publisher.stop()
        await harness.google.releaseAll()
        await driver.value
        #expect(await harness.google.requests.count == requests)
        #expect(await harness.google.uploads.isEmpty)
    }
}
