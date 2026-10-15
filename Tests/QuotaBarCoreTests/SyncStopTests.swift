import Foundation
import Testing
@testable import QuotaBarCore

private struct SimulatedCrash: Error {}

/// An active session that has published once, with another Mac's file and
/// this session's own file in Drive.
private func publishedHarness() async throws -> (SyncHarness, ownFile: String, foreignFile: String) {
    let harness = try await SyncHarness.active()
    await harness.publisher.submit(SyncFakes.source())
    await harness.publisher.tick()
    let ownFile = try #require(await harness.google.files.keys.first)
    // A newer file from someone else: never this session's to delete. Made
    // after the publish, so the publisher's duplicate cleanup has not run on it.
    let foreignFile = await harness.google.seed(
        publisherId: "another-session-id", created: harness.clock.now().addingTimeInterval(1))
    return (harness, ownFile, foreignFile)
}

@Suite("Stop syncing (REQ-MAC-STOP)")
struct SyncStopTests {

    // MARK: (a)

    @Test("step 1 persists stopping and the cleanup record in one write, before any network call")
    func stopPersistsBeforeAnyNetworkCall() async throws {
        let (harness, _, _) = try await publishedHarness()
        let publisherId = try harness.secrets.read(SyncSecretAccount.publisherId)
        let requestsBefore = await harness.google.requests.count
        await harness.publisher.setStopCheckpoint { gap in
            if gap == .afterStoppingWrite { throw SimulatedCrash() }
        }
        await harness.publisher.stop()

        let saved = try harness.store.load()
        #expect(saved.phase == .stopping)
        let record = try #require(saved.cleanup)
        #expect(record.publisherId == publisherId)
        #expect(record.account == SyncFakes.account)
        #expect(record.refreshTokenAccount == SyncSecretAccount.refreshToken)
        #expect(record.relistAt == [120, 600].map { harness.clock.now().addingTimeInterval($0) })
        #expect(record.completed.isEmpty)
        #expect(await harness.google.requests.count == requestsBefore)
    }

    @Test("the protocol deletes this session's file, re-lists at +2 and +10 minutes, then deletes the token and sets stopped")
    func stopProtocolRunsInOrder() async throws {
        let (harness, ownFile, foreignFile) = try await publishedHarness()
        let stopAt = harness.clock.now()
        await harness.publisher.stop()
        var files = await harness.google.files
        #expect(files[ownFile] == nil)
        #expect(files[foreignFile] != nil)
        #expect(await harness.publisher.status().phase == .stopping)
        #expect(await harness.publisher.nextWakeup() == stopAt.addingTimeInterval(120))

        // A late create of this session's file lands after the delete.
        let publisherId = try harness.secrets.read(SyncSecretAccount.publisherId)
        let late = await harness.google.seed(publisherId: publisherId, created: stopAt.addingTimeInterval(30))
        harness.clock.set(stopAt.addingTimeInterval(119))
        await harness.publisher.tick()
        #expect(await harness.google.files[late] != nil)
        harness.clock.set(stopAt.addingTimeInterval(120))
        await harness.publisher.tick()
        #expect(await harness.google.files[late] == nil)
        #expect(await harness.publisher.nextWakeup() == stopAt.addingTimeInterval(600))
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) != nil)

        let lateAgain = await harness.google.seed(publisherId: publisherId, created: stopAt.addingTimeInterval(300))
        harness.clock.set(stopAt.addingTimeInterval(600))
        await harness.publisher.tick()
        files = await harness.google.files
        #expect(files[lateAgain] == nil)
        #expect(files[foreignFile] != nil)
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == nil)
        #expect(try harness.secrets.read(SyncSecretAccount.publisherId) == nil)
        #expect(try harness.store.load().phase == .stopped)
        #expect(try harness.store.load().cleanup == nil)
        #expect(await harness.publisher.nextWakeup() == nil)
    }

    @Test("Stop deletes nothing when the file carries another session's publisherId")
    func stopLeavesAForeignFile() async throws {
        let (harness, ownFile, _) = try await publishedHarness()
        await harness.google.setPublisherId("someone-took-over", of: ownFile)
        await harness.publisher.stop()
        await harness.run(for: 11 * 60)
        #expect(await harness.google.files[ownFile] != nil)
        #expect(await harness.google.requests.filter { $0.method == "DELETE" }.isEmpty)
        #expect(await harness.publisher.status().phase == .stopped)
    }

    @Test("Stop cancels the in-flight upload and awaits it")
    func stopSettlesTheInFlightUpload() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.hang] }
        await harness.publisher.submit(SyncFakes.source())
        let driver = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })

        await harness.publisher.stop()
        await driver.value
        #expect(await harness.google.heldCount == 0)
        let record = try #require(try harness.store.load().cleanup)
        #expect(record.isDone(.settleInFlight))
        #expect(record.isDone(.deleteOwn))
        #expect(try harness.store.load().repairPending == false)
    }

    @Test("a crash at any gap between steps resumes on relaunch and finishes", arguments: SyncStopGap.allCases)
    func crashBetweenStepsResumes(_ gap: SyncStopGap) async throws {
        let (harness, ownFile, foreignFile) = try await publishedHarness()
        let uploadsBefore = await harness.google.uploads.count
        let stopAt = harness.clock.now()
        await harness.publisher.setStopCheckpoint { reached in
            if reached == gap { throw SimulatedCrash() }
        }
        await harness.publisher.stop()
        // The later gaps are reached on the re-list tick; the process dies
        // there, at `gap`, and this instance is never used again.
        if [.afterFirstRelist, .afterSecondRelist, .afterTokenDelete].contains(gap) {
            harness.clock.set(stopAt.addingTimeInterval(600))
            await harness.publisher.tick()
        }
        let crashed = try harness.store.load()
        #expect(crashed.phase == .stopping)
        let expectedDone: [SyncStopGap: Int] = [
            .afterStoppingWrite: 0, .afterSettle: 1, .afterDeleteOwn: 2,
            .afterFirstRelist: 3, .afterSecondRelist: 4, .afterTokenDelete: 5,
        ]
        #expect(crashed.cleanup?.completed.count == expectedDone[gap])

        let relaunched = harness.relaunched()
        await relaunched.publisher.resume()
        await relaunched.run(for: 11 * 60)

        #expect(try harness.store.load().phase == .stopped)
        #expect(try harness.store.load().cleanup == nil)
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == nil)
        #expect(try harness.secrets.read(SyncSecretAccount.publisherId) == nil)
        let files = await harness.google.files
        #expect(files[ownFile] == nil)
        #expect(files[foreignFile] != nil)
        #expect(await harness.google.uploads.count == uploadsBefore)
    }

    @Test("a crash before the re-lists keeps their original deadlines")
    func relistDeadlinesSurviveACrash() async throws {
        let (harness, _, _) = try await publishedHarness()
        let stopAt = harness.clock.now()
        await harness.publisher.setStopCheckpoint { if $0 == .afterDeleteOwn { throw SimulatedCrash() } }
        await harness.publisher.stop()
        harness.clock.advance(by: 30)
        let relaunched = harness.relaunched()
        await relaunched.publisher.resume()
        #expect(await relaunched.publisher.nextWakeup() == stopAt.addingTimeInterval(120))
    }

    // MARK: (b)

    @Test("throughout stopping nothing uploads or repairs: queued, newly scheduled, forced, or resumed after a crash")
    func nothingPublishesWhileStopping() async throws {
        let harness = try await SyncHarness.active()
        // An uncertain upload leaves a forced repair pending...
        await harness.google.configure { $0.uploadModes = [.commitThenHang] }
        await harness.publisher.submit(SyncFakes.source())
        let driver = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })
        harness.clock.advance(by: SyncPublisher.requestTimeout)
        await driver.value
        #expect(try harness.store.load().repairPending)
        // ...and a material change is queued.
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        let uploads = await harness.google.uploads.count
        let reads = await harness.google.requests.filter { $0.queryItems["alt"] == "media" }.count

        await harness.publisher.setStopCheckpoint { if $0 == .afterDeleteOwn { throw SimulatedCrash() } }
        await harness.publisher.stop()
        // Newly scheduled work while stopping.
        for _ in 0..<5 {
            harness.clock.advance(by: SyncPublisher.minimumInterval)
            await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.1)]))
            await harness.publisher.tick()
        }
        // Resumed after the crash, with more input arriving.
        let relaunched = harness.relaunched()
        await relaunched.publisher.resume()
        for _ in 0..<10 {
            await relaunched.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.2)]))
            await relaunched.publisher.takeOver()
            await relaunched.drain()
            harness.clock.advance(by: SyncPublisher.minimumInterval)
        }
        #expect(await harness.google.uploads.count == uploads)
        #expect(await harness.google.requests.filter { $0.queryItems["alt"] == "media" }.count == reads)
        #expect(try harness.store.load().phase == .stopped)
    }

    // MARK: (c)

    @Test("while stopping, Start is unavailable")
    func startIsUnavailableWhileStopping() async throws {
        let (harness, _, _) = try await publishedHarness()
        await harness.publisher.stop()
        let status = await harness.publisher.status()
        #expect(status.phase == .stopping)
        #expect(!status.canStart)
        await #expect(throws: SyncActivationError.unavailable) {
            try await harness.publisher.activate(account: SyncFakes.account)
        }
    }

    // MARK: (d)

    /// Stop with an expired access token and a refresh token Google now
    /// rejects: cleanup pauses on the terminal failure.
    private func pausedCleanup() async throws -> (SyncHarness, ownFile: String) {
        let (harness, ownFile, _) = try await publishedHarness()
        harness.clock.advance(by: 2 * 3600)
        await harness.google.configure {
            $0.tokenResponses = [SyncHTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))]
        }
        await harness.publisher.stop()
        return (harness, ownFile)
    }

    @Test("a terminal auth failure during cleanup pauses it and offers the two choices")
    func terminalAuthDuringCleanupPauses() async throws {
        let (harness, ownFile) = try await pausedCleanup()
        let status = await harness.publisher.status()
        #expect(status.phase == .stopping)
        #expect(status.cleanupNeedsSignIn)
        #expect(await harness.publisher.nextWakeup() == nil)
        #expect(await harness.google.files[ownFile] != nil)
    }

    @Test("Sign in to finish cleanup needs the same account, keeps the publisherId, and never publishes")
    func signInToFinishCleanup() async throws {
        let (harness, ownFile) = try await pausedCleanup()
        let record = try #require(try harness.store.load().cleanup)
        let uploads = await harness.google.uploads.count

        // The wrong account is turned away, and its token is never stored.
        let flow = SyncSignInFlow(
            configuration: SyncFakes.configuration, transport: harness.google,
            secrets: harness.secrets, clock: harness.clock)
        await harness.google.configure { $0.aboutAccount = SyncFakes.otherAccount }
        let wrong = FakeCallbackListener()
        await #expect(throws: SyncSignInError.wrongAccount) {
            _ = try await flow.run(
                listener: wrong, loginHint: record.account?.email,
                expectedPermissionId: record.account?.permissionId
            ) { url in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value ?? ""
                wrong.answer(["state": state, "code": "fake-auth-code"])
            }
        }
        await #expect(throws: SyncSignInError.wrongAccount) {
            try await harness.publisher.reauthorized(account: SyncFakes.otherAccount)
        }
        #expect(await harness.publisher.status().cleanupNeedsSignIn)

        await harness.google.configure { $0.aboutAccount = SyncFakes.account }
        let right = FakeCallbackListener()
        let result = try await flow.run(
            listener: right, loginHint: record.account?.email, expectedPermissionId: record.account?.permissionId
        ) { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            right.answer(["state": state, "code": "fake-auth-code"])
        }
        try await harness.publisher.reauthorized(account: result.account)
        #expect(try harness.store.load().cleanup?.publisherId == record.publisherId)
        #expect(try harness.secrets.read(SyncSecretAccount.publisherId) == record.publisherId)

        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        await harness.run(for: 11 * 60)
        #expect(await harness.google.files[ownFile] == nil)
        #expect(await harness.google.uploads.count == uploads)
        #expect(await harness.publisher.status().phase == .stopped)
        #expect(await harness.publisher.status().abandoned == nil)
    }

    @Test("Finish without deleting stops, and the notice names the persisted email, hidden while publishing to that account again")
    func finishWithoutDeletingShowsNoticeWithEmail() async throws {
        let (harness, ownFile) = try await pausedCleanup()
        await harness.publisher.finishWithoutDeleting()

        var status = await harness.publisher.status()
        #expect(status.phase == .stopped)
        #expect(status.abandoned?.account.email == "owner@example.test")
        #expect(await harness.google.files[ownFile] != nil)
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == nil)
        // Persisted: a relaunch still names the account.
        #expect(await harness.relaunched().publisher.status().abandoned?.account.email == "owner@example.test")

        try harness.secrets.write(SyncFakes.refreshToken, account: SyncSecretAccount.refreshToken)
        try await harness.publisher.activate(account: SyncFakes.account)
        status = await harness.publisher.status()
        #expect(status.abandoned == nil)

        // Publishing to a different account does not hide it.
        let other = harness.relaunched()
        await other.publisher.stop()
        await other.run(for: 11 * 60)
        try harness.secrets.write(SyncFakes.refreshToken, account: SyncSecretAccount.refreshToken)
        try await other.publisher.activate(account: SyncFakes.otherAccount)
        #expect(await other.publisher.status().abandoned?.account.email == "owner@example.test")
    }

    // MARK: (e)

    @Test("no code path calls Google's revoke endpoint")
    func noRevokeEndpoint() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            #expect(!text.contains("/revoke"), "\(url.lastPathComponent)")
            #expect(!text.contains("oauth2.googleapis.com/revoke"), "\(url.lastPathComponent)")
            if url.path.contains("/Sync/") {
                #expect(!text.lowercased().contains("revoke"), "\(url.lastPathComponent)")
            }
        }
        #expect(scanned > 100)
    }
}
