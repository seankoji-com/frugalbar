import Foundation
import Testing
@testable import QuotaBarCore

private struct SimulatedCrash: Error {}

/// A foreign file seen through a Mac clock `macAhead` seconds ahead of Drive.
struct ForeignAgeCase: Sendable, CustomTestStringConvertible {
    let macAhead: TimeInterval
    let ageByDrive: TimeInterval
    let metadataHasDate: Bool
    let overwritten: Bool

    var testDescription: String {
        "Mac \(Int(macAhead)) s ahead, \(Int(ageByDrive)) s old by Drive, Date header \(metadataHasDate)"
    }
}

// Every durable write sync depends on fails closed (review round 2: S2-N2,
// S2-R5, S2-R6, S2-R7 and the audit of the other writes). Each test replays
// the reviewer's scenario under the fake clock, fake Google and a state store
// whose writes and reads can fail.
@Suite("Sync durable state fails closed (REQ-MAC-FILE, REQ-MAC-PUBLISH, REQ-MAC-STOP)")
struct SyncDurableStateTests {

    // MARK: S2-N2 activation

    @Test("a sign-in whose active record can't be saved leaves sync off, removes its Keychain items and contacts nothing")
    func activationSaveFailureLeavesSyncOff() async throws {
        let harness = SyncHarness()
        harness.store.failWrites()
        await #expect(throws: SyncActivationError.stateNotSaved) {
            try await harness.publisher.activate(account: SyncFakes.account)
        }
        var status = await harness.publisher.status()
        #expect(status.phase == .off)
        #expect(status.canStart)
        #expect(status.account == nil)
        #expect(try harness.secrets.read(SyncSecretAccount.publisherId) == nil)
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == nil)

        // Writes keep failing through what would have been the first upload.
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        await harness.run(for: 11 * 60)
        #expect(await harness.google.requests.isEmpty)
        #expect(await harness.google.files.isEmpty)

        let relaunched = harness.relaunched()
        status = await relaunched.publisher.status()
        #expect(status.phase == .off)
        #expect(status.canStart)
        #expect(harness.store.saved.phase == .off)

        // Once writes land, a new sign-in starts a session Stop can finish.
        harness.store.failWrites(false)
        try harness.secrets.write(SyncFakes.refreshToken, account: SyncSecretAccount.refreshToken)
        try await relaunched.publisher.activate(account: SyncFakes.account)
        #expect(harness.store.saved.phase == .active)
        #expect(harness.store.saved.account == SyncFakes.account)
        await relaunched.publisher.submit(SyncFakes.source())
        await relaunched.publisher.tick()
        #expect(await harness.google.uploads.count == 1)
        await relaunched.publisher.stop()
        await relaunched.run(for: 11 * 60)
        #expect(await relaunched.publisher.status().phase == .stopped)
        #expect(await harness.google.files.isEmpty)
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == nil)
    }

    // MARK: S2-R5 ownership age

    @Test("a foreign file's age is Drive's modifiedTime against the same response's Date header; an unknown age keeps the guard",
          arguments: [
              ForeignAgeCase(macAhead: 7200, ageByDrive: 0, metadataHasDate: true, overwritten: false),
              ForeignAgeCase(macAhead: -7200, ageByDrive: 61 * 60, metadataHasDate: true, overwritten: true),
              ForeignAgeCase(macAhead: 0, ageByDrive: 3 * 3600, metadataHasDate: false, overwritten: false),
          ])
    func foreignAgeUsesDriveTime(_ scenario: ForeignAgeCase) async throws {
        let harness = try await SyncHarness.active()
        let serverNow = harness.clock.now().addingTimeInterval(-scenario.macAhead)
        await harness.google.configure {
            $0.serverOffset = -scenario.macAhead
            if !scenario.metadataHasDate { $0.metadataServerOffset = .some(nil) }
        }
        let foreign = await harness.google.seed(
            publisherId: "fresh-foreign-session", created: serverNow.addingTimeInterval(-86_400),
            modified: serverNow.addingTimeInterval(-scenario.ageByDrive))
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        if scenario.overwritten {
            #expect(await harness.publisher.status().ownership == nil)
            #expect(await harness.google.uploads.count == 1)
            #expect(await harness.google.files[foreign]?.publisherId == (try harness.secrets.read(SyncSecretAccount.publisherId)))
        } else {
            #expect(await harness.publisher.status().ownership == .otherMacSyncing(label: nil))
            #expect(await harness.google.uploads.isEmpty)
            #expect(await harness.google.files[foreign]?.publisherId == "fresh-foreign-session")
        }
    }

    // MARK: S2-R6 unreadable state

    @Test("an unreadable stopping record keeps Start unavailable, is never written over, and its Stop finishes once it reads")
    func unreadableStateKeepsStartUnavailable() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let ownFile = try #require(await harness.google.files.keys.first)
        await harness.publisher.setStopCheckpoint { gap in
            if gap == .afterStoppingWrite { throw SimulatedCrash() }
        }
        await harness.publisher.stop()
        let record = harness.store.saved
        #expect(record.phase == .stopping)
        #expect(record.cleanup != nil)
        let publisherId = try harness.secrets.read(SyncSecretAccount.publisherId)
        let saves = harness.store.saves
        let requests = await harness.google.requests.count

        // Relaunch with the record intact but unreadable.
        harness.store.failLoads()
        let relaunched = harness.relaunched()
        await relaunched.publisher.resume()
        let status = await relaunched.publisher.status()
        #expect(status.stateUnreadable)
        #expect(!status.canStart)
        await #expect(throws: SyncActivationError.unavailable) {
            try await relaunched.publisher.activate(account: SyncFakes.account)
        }
        await #expect(throws: SyncActivationError.unavailable) {
            try await relaunched.publisher.reauthorized(account: SyncFakes.account)
        }
        await relaunched.publisher.stop()
        await relaunched.publisher.takeOver()
        await relaunched.publisher.finishWithoutDeleting()
        await relaunched.publisher.submit(SyncFakes.source())
        await relaunched.run(for: 11 * 60)

        #expect(harness.store.saves == saves)
        #expect(harness.store.saved == record)
        #expect(try harness.secrets.read(SyncSecretAccount.publisherId) == publisherId)
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) != nil)
        #expect(await harness.google.requests.count == requests)
        #expect(await relaunched.publisher.nextWakeup() != nil)

        // Readable again: the unfinished Stop resumes from its record.
        harness.store.failLoads(false)
        await relaunched.run(for: 12 * 60)
        #expect(await relaunched.publisher.status().phase == .stopped)
        #expect(await relaunched.publisher.status().stateUnreadable == false)
        #expect(await harness.google.files[ownFile] == nil)
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == nil)
    }

    @Test("the state file store tells a missing file (off) from one it can't decode, and the publisher never writes over the latter")
    func fileStoreDistinguishesMissingFromUnreadable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("frugalbar-sync-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSyncStateStore(file: directory.appendingPathComponent("sync-state.json"))
        #expect(try store.load() == SyncPersistentState())

        var stopping = SyncPersistentState()
        stopping.phase = .stopping
        try store.save(stopping)
        #expect(try store.load() == stopping)

        for bytes in [Data(#"{"phase":"stopp"#.utf8), Data(#"{"phase":"paused"}"#.utf8)] {
            try bytes.write(to: store.file)
            #expect(throws: (any Error).self) { try store.load() }

            let clock = FakeSyncClock()
            let secrets = InMemorySyncSecrets(initial: [SyncSecretAccount.refreshToken: SyncFakes.refreshToken])
            let publisher = SyncPublisher(
                configuration: SyncFakes.configuration, transport: FakeGoogle(clock: clock), secrets: secrets,
                stateStore: store, clock: clock, label: { "Test Mac" })
            #expect(await publisher.status().stateUnreadable)
            #expect(!(await publisher.status().canStart))
            await #expect(throws: SyncActivationError.unavailable) {
                try await publisher.activate(account: SyncFakes.account)
            }
            await publisher.tick()
            #expect(try Data(contentsOf: store.file) == bytes)
            #expect(try secrets.read(SyncSecretAccount.refreshToken) == SyncFakes.refreshToken)
        }
    }

    // MARK: S2-R7 pre-upload checkpoint

    @Test("a pre-upload checkpoint that can't be saved contacts no Google service, and a relaunch a second later uploads once")
    func failedCheckpointWithholdsTheUpload() async throws {
        let harness = try await SyncHarness.active()
        let t0 = harness.clock.now()
        harness.store.failWrites()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(await harness.google.requests.isEmpty)
        #expect(await harness.publisher.status().lastError == SyncPublisher.stateNotSavedMessage)
        #expect(await harness.publisher.nextWakeup() == t0.addingTimeInterval(SyncPublisher.backoff(1)))
        #expect(harness.store.saved.lastAttemptAt == nil)

        harness.clock.advance(by: 1)
        harness.store.failWrites(false)
        let relaunched = harness.relaunched()
        await relaunched.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.8)]))
        await relaunched.publisher.tick()
        #expect(await harness.google.uploads.count == 1)
        #expect(harness.store.saved.lastAttemptAt == t0.addingTimeInterval(1))

        // The floor now holds from the attempt that did go out.
        await relaunched.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        let times = await relaunched.run(for: 3 * 60)
        #expect(times == [t0.addingTimeInterval(1 + SyncPublisher.minimumInterval)])
    }

    @Test("after failed checkpoints the upload goes out once writes land, no sooner than the backoff")
    func failedCheckpointRetriesAfterBackoff() async throws {
        let harness = try await SyncHarness.active()
        let t0 = harness.clock.now()
        harness.store.failWrites()
        await harness.publisher.submit(SyncFakes.source())
        await harness.run(for: 60)
        #expect(await harness.google.requests.isEmpty)
        harness.store.failWrites(false)
        let times = await harness.run(for: 5 * 60)
        #expect(times == [t0.addingTimeInterval(SyncPublisher.backoff(1))])
        #expect(await harness.google.uploads.count == 1)
    }

    // MARK: Audit of the other durable writes

    @Test("an upload whose outcome can't be saved counts as uncertain at relaunch, so a later takeover is not overwritten")
    func unsavedOutcomeKeepsTheTakeoverGuard() async throws {
        let harness = try await SyncHarness.active()
        harness.store.failWrites(after: 1)
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(await harness.google.uploads.count == 1)
        #expect(harness.store.saved.uploadStartedAt != nil)
        #expect(harness.store.saved.lastSuccessfulPublishAt == nil)

        let fileId = try #require(await harness.google.files.keys.first)
        await harness.google.setPublisherId("another-mac-took-over", of: fileId, modified: harness.clock.now())
        harness.clock.advance(by: SyncPublisher.foreignWindow + 60)
        harness.store.failWrites(false)
        let relaunched = harness.relaunched()
        await relaunched.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.8)]))
        await relaunched.publisher.tick()

        guard case .tookOver = await relaunched.publisher.status().ownership else {
            Issue.record("expected the relaunched publisher to stop on the takeover")
            return
        }
        #expect(await harness.google.uploads.count == 1)
        #expect(await harness.google.files[fileId]?.publisherId == "another-mac-took-over")
    }

    @Test("an upload whose outcome can't be saved is forced and verified after a relaunch")
    func unsavedOutcomeIsVerifiedAfterRelaunch() async throws {
        let harness = try await SyncHarness.active()
        let t0 = harness.clock.now()
        harness.store.failWrites(after: 1)
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        harness.clock.advance(by: 1)
        harness.store.failWrites(false)
        let relaunched = harness.relaunched()
        #expect(harness.store.saved.repairPending == false)
        await relaunched.publisher.submit(SyncFakes.source())
        let times = await relaunched.run(for: 3 * 60)
        #expect(times == [t0.addingTimeInterval(1 + SyncPublisher.minimumInterval)])
        let reads = await harness.google.requests.filter { $0.method == "GET" && $0.queryItems["alt"] == "media" }
        #expect(reads.count == 1)
        #expect(harness.store.saved.repairPending == false)
        #expect(harness.store.saved.lastSuccessfulPublishAt != nil)
    }

    @Test("Stop whose stopping write fails publishes nothing more, and retries the write until cleanup can run")
    func stopWriteFailureWithholdsPublishing() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let ownFile = try #require(await harness.google.files.keys.first)

        harness.store.failWrites()
        await harness.publisher.stop()
        #expect(await harness.publisher.status().phase == .active)
        #expect(await harness.publisher.status().lastError == SyncPublisher.stateNotSavedMessage)
        #expect(harness.store.saved.phase == .active)
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        await harness.run(for: 10 * 60)
        #expect(await harness.google.uploads.count == 1)

        // A relaunch meanwhile still shows the session, with Stop.
        let relaunched = harness.relaunched()
        #expect(await relaunched.publisher.status().phase == .active)
        #expect(!(await relaunched.publisher.status().canStart))

        harness.store.failWrites(false)
        await harness.run(for: 30 * 60)
        #expect(await harness.publisher.status().phase == .stopped)
        #expect(await harness.google.files[ownFile] == nil)
        #expect(await harness.google.uploads.count == 1)
    }

    @Test("Take over keeps the prompt and uploads nothing when clearing it can't be saved")
    func takeOverWriteFailureKeepsThePrompt() async throws {
        let harness = try await SyncHarness.active()
        let foreign = await harness.google.seed(
            publisherId: "other-macs-publisher-id", created: SyncFakes.start.addingTimeInterval(-86_400),
            modified: SyncFakes.start.addingTimeInterval(-30 * 60))
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(await harness.publisher.status().ownership != nil)

        harness.store.failWrites()
        await harness.publisher.takeOver()
        #expect(await harness.publisher.status().ownership != nil)
        await harness.run(for: 5 * 60)
        #expect(await harness.google.uploads.isEmpty)
        #expect(await harness.google.files[foreign]?.publisherId == "other-macs-publisher-id")

        harness.store.failWrites(false)
        await harness.publisher.takeOver()
        await harness.run(for: 3 * 60)
        #expect(await harness.google.uploads.count == 1)
    }

    @Test("signing in again resumes nothing until the cleared Sign in again is saved")
    func reauthorizedWriteFailureKeepsSignInAgain() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure {
            $0.tokenResponses = [SyncHTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))]
        }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(await harness.publisher.status().needsSignIn)

        harness.store.failWrites()
        await #expect(throws: SyncActivationError.stateNotSaved) {
            try await harness.publisher.reauthorized(account: SyncFakes.account)
        }
        #expect(await harness.publisher.status().needsSignIn)
        #expect(await harness.publisher.nextWakeup() == nil)

        harness.store.failWrites(false)
        try await harness.publisher.reauthorized(account: SyncFakes.account)
        #expect(!(await harness.publisher.status().needsSignIn))
        #expect(harness.store.saved.needsSignIn == false)
    }

    @Test("a 2xx upload answer without a file id is uncertain: the upload landed, so a repair follows")
    func malformedUploadAnswerIsUncertain() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.commitMalformed] }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(await harness.google.files.count == 1)
        #expect(harness.store.saved.repairPending)
        #expect(harness.store.saved.mayHavePublished == true)
        #expect(harness.store.saved.uploadStartedAt == nil)
    }
}
