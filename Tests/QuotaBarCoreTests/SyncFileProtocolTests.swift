import Foundation
import Testing
@testable import QuotaBarCore

private func used(_ document: [String: Any]) -> Double? {
    let providers = document["providers"] as? [[String: Any]]
    return (providers?.first?["primary"] as? [String: Any])?["usedFraction"] as? Double
}

@Suite("Sync file protocol (REQ-MAC-FILE)")
struct SyncFileProtocolTests {

    // MARK: (a) discovery

    @Test("discovery sends the exact query and fields")
    func discoveryUsesExactQueryAndFields() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let list = try #require(await harness.google.requests.first { $0.method == "GET" && $0.url.path == "/drive/v3/files" })
        let q = list.queryItems
        #expect(q["spaces"] == "appDataFolder")
        #expect(q["q"] == "name='snapshot.json' and trashed=false")
        #expect(q["orderBy"] == "createdTime")
        #expect(q["fields"] == "nextPageToken,files(id,createdTime,appProperties)")
    }

    @Test("discovery reads every page, picks the oldest file and deletes the duplicates")
    func readsEveryPageAndKeepsTheOldest() async throws {
        let harness = try await SyncHarness.active()
        let t = SyncFakes.start
        await harness.google.configure { $0.pageSize = 2 }
        let newer = await harness.google.seed(publisherId: nil, created: t.addingTimeInterval(-100))
        let oldest = await harness.google.seed(publisherId: nil, created: t.addingTimeInterval(-500))
        let middle = await harness.google.seed(publisherId: nil, created: t.addingTimeInterval(-300))
        let newest = await harness.google.seed(publisherId: nil, created: t.addingTimeInterval(-10))
        let alsoNew = await harness.google.seed(publisherId: nil, created: t.addingTimeInterval(-50))

        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        let lists = await harness.google.requests.filter { $0.method == "GET" && $0.url.path == "/drive/v3/files" }
        #expect(lists.count == 3)
        #expect(lists.map { $0.queryItems["pageToken"] } == [nil, "2", "4"])
        let files = await harness.google.files
        #expect(Array(files.keys) == [oldest])
        let deleted = Set(await harness.google.requests.filter { $0.method == "DELETE" }.map { $0.url.lastPathComponent })
        #expect(deleted == [newer, middle, newest, alsoNew])
        #expect(await harness.google.uploads.map(\.url.lastPathComponent) == [oldest])
    }

    @Test("equal createdTime breaks ties by id, and a file seen twice counts once")
    func tiesBreakById() {
        let t = SyncFakes.start
        let b = SyncDriveFile(id: "b", createdTime: t, publisherId: nil)
        let a = SyncDriveFile(id: "a", createdTime: t, publisherId: nil)
        let later = SyncDriveFile(id: "0", createdTime: t.addingTimeInterval(1), publisherId: nil)
        let selection = SyncDriveClient.select([b, later, a, b])
        #expect(selection.canonical == a)
        #expect(selection.duplicates == [b, later])
    }

    @Test("an invalid page token restarts the listing once; a second fails the run without uploading")
    func invalidPageTokenRestartsOnce() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure {
            $0.pageSize = 1
            $0.invalidPageTokens = 1
        }
        await harness.google.seed(publisherId: nil, created: SyncFakes.start.addingTimeInterval(-60))
        await harness.google.seed(publisherId: nil, created: SyncFakes.start.addingTimeInterval(-30))
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let firstPages = await harness.google.requests.filter { $0.url.path == "/drive/v3/files" }.map { $0.queryItems["pageToken"] }
        #expect(firstPages == [nil, "1", nil, "1"])
        #expect(await harness.google.uploads.count == 1)

        let failing = try await SyncHarness.active()
        await failing.google.configure {
            $0.pageSize = 1
            $0.invalidPageTokens = 2
        }
        await failing.google.seed(publisherId: nil, created: SyncFakes.start.addingTimeInterval(-60))
        await failing.google.seed(publisherId: nil, created: SyncFakes.start.addingTimeInterval(-30))
        await failing.publisher.submit(SyncFakes.source())
        await failing.publisher.tick()
        #expect(await failing.google.uploads.isEmpty)
        #expect(await failing.publisher.status().lastError != nil)
        #expect(await failing.publisher.nextWakeup() != nil)
    }

    @Test("after an uncertain create, the next publish re-lists and updates the file instead of creating another")
    func uncertainCreateRelistsBeforeCreatingAgain() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.commitThenHang] }
        await harness.publisher.submit(SyncFakes.source())
        let first = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })
        harness.clock.advance(by: SyncPublisher.requestTimeout)
        await first.value
        #expect(await harness.publisher.status().lastError == "The last upload's outcome is unknown; publishing again")

        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.tick()
        let requests = await harness.google.requests
        let secondUpload = try #require(requests.lastIndex { $0.url.path.hasPrefix("/upload/") })
        let firstUpload = try #require(requests.firstIndex { $0.url.path.hasPrefix("/upload/") })
        #expect(requests[(firstUpload + 1)..<secondUpload].contains { $0.url.path == "/drive/v3/files" })
        #expect(requests[firstUpload].method == "POST")
        #expect(requests[secondUpload].method == "PATCH")
        #expect(await harness.google.files.count == 1)
    }

    // MARK: (b) one upload at a time

    @Test("only one upload is in flight, and a newer snapshot replaces the queued one")
    func oneUploadInFlightAndNewestWins() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.hang] }
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.1)]))
        let first = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })

        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.2)]))
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.3)]))
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.tick()   // a second tick while one is in flight does nothing
        #expect(await harness.google.uploads.count == 1)

        await harness.google.releaseAll()
        await first.value
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.tick()
        let documents = await harness.google.uploadedDocuments()
        #expect(documents.compactMap(used) == [0.1, 0.3])
    }

    // MARK: (c) repair after an uncertain upload

    @Test("after an uncertain upload the next publish runs at the next 2-minute slot and is verified; 3 forced publishes, then the heartbeat")
    func uncertainUploadForcesVerifiedPublishes() async throws {
        let harness = try await SyncHarness.active()
        let t0 = harness.clock.now()
        await harness.google.configure { $0.uploadModes = [.hang] }
        await harness.publisher.submit(SyncFakes.source())
        let first = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })
        harness.clock.advance(by: SyncPublisher.requestTimeout)
        await first.value

        // Not the heartbeat: the next 2-minute slot.
        #expect(await harness.publisher.nextWakeup() == t0.addingTimeInterval(SyncPublisher.minimumInterval))

        // Each forced publish is followed by a verification read; a late older
        // write makes all three mismatch.
        await harness.google.configure { $0.staleReads = 3 }
        var slot = t0
        for forced in 1...3 {
            slot = slot.addingTimeInterval(SyncPublisher.minimumInterval)
            harness.clock.set(slot)
            await harness.publisher.tick()
            #expect(await harness.google.uploads.count == 1 + forced)
            let reads = await harness.google.requests.filter { $0.queryItems["alt"] == "media" }.count
            #expect(reads == forced)
        }
        let lastSuccess = try #require(await harness.publisher.status().lastSuccessfulPublishAt)
        #expect(await harness.publisher.nextWakeup() == lastSuccess.addingTimeInterval(SyncPublisher.heartbeatInterval))
    }

    @Test("a verification read compares SHA-256 against the exact bytes published, and a match ends the repair")
    func verificationMatchEndsRepair() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.commitThenHang] }
        await harness.publisher.submit(SyncFakes.source())
        let first = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })
        harness.clock.advance(by: SyncPublisher.requestTimeout)
        await first.value

        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.tick()
        #expect(await harness.google.requests.filter { $0.queryItems["alt"] == "media" }.count == 1)
        let lastSuccess = try #require(await harness.publisher.status().lastSuccessfulPublishAt)
        #expect(await harness.publisher.nextWakeup() == lastSuccess.addingTimeInterval(SyncPublisher.heartbeatInterval))
        #expect(await harness.publisher.status().lastError == nil)
    }

    // MARK: (d) ownership

    @Test("a foreign publisherId written less than an hour ago stops publishing and offers Take over")
    func foreignPublisherStopsAndOffersTakeOver() async throws {
        let harness = try await SyncHarness.active()
        let other = Data(#"{"publisherLabel":"Office Mac","providers":[]}"#.utf8)
        let id = await harness.google.seed(
            publisherId: "other-macs-publisher-id", created: SyncFakes.start.addingTimeInterval(-86_400),
            modified: SyncFakes.start.addingTimeInterval(-30 * 60), content: other)
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        #expect(await harness.publisher.status().ownership == .otherMacSyncing(label: "Office Mac"))
        #expect(await harness.google.uploads.isEmpty)
        #expect(await harness.publisher.nextWakeup() == nil)

        await harness.publisher.takeOver()
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.tick()
        let ours = try harness.secrets.read(SyncSecretAccount.publisherId)
        #expect(await harness.google.uploadedPublisherIds() == [ours])
        #expect(await harness.google.files[id]?.publisherId == ours)
    }

    @Test("a foreign publisherId more than an hour old is overwritten")
    func staleForeignPublisherIsOverwritten() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.seed(
            publisherId: "other-macs-publisher-id", created: SyncFakes.start.addingTimeInterval(-86_400),
            modified: SyncFakes.start.addingTimeInterval(-61 * 60))
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(await harness.publisher.status().ownership == nil)
        #expect(await harness.google.uploads.count == 1)
    }

    @Test("the previous publisher stops when its pre-upload check finds a takeover")
    func formerPublisherStopsOnTakeover() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let fileId = try #require(await harness.google.files.keys.first)

        harness.clock.advance(by: 60)
        await harness.google.setPublisherId("another-mac-took-over", of: fileId, modified: harness.clock.now())
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.8)]))
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.tick()

        guard case .tookOver = await harness.publisher.status().ownership else {
            Issue.record("expected the takeover to stop this Mac")
            return
        }
        #expect(await harness.google.uploads.count == 1)
        #expect(await harness.publisher.nextWakeup() == nil)
    }

    @Test("every session gets a fresh publisherId")
    func everySessionGetsAFreshPublisherId() async throws {
        let harness = try await SyncHarness.active()
        let first = try #require(try harness.secrets.read(SyncSecretAccount.publisherId))
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        await harness.publisher.stop()
        await harness.run(for: 11 * 60)
        #expect(await harness.publisher.status().phase == .stopped)

        try harness.secrets.write(SyncFakes.refreshToken, account: SyncSecretAccount.refreshToken)
        try await harness.publisher.activate(account: SyncFakes.account)
        let second = try #require(try harness.secrets.read(SyncSecretAccount.publisherId))
        #expect(second != first)

        // Another Mac's session is different again.
        let otherMac = try await SyncHarness.active()
        #expect(try otherMac.secrets.read(SyncSecretAccount.publisherId) != second)
    }

    // MARK: (e) the session id lives in the Keychain

    @Test("the active session's publisherId is in the Keychain and survives relaunches unchanged")
    func publisherIdSurvivesRelaunch() async throws {
        let harness = try await SyncHarness.active()
        let id = try #require(try harness.secrets.read(SyncSecretAccount.publisherId))
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        for used in [0.5, 0.6] {
            let relaunched = harness.relaunched()
            #expect(await relaunched.publisher.status().phase == .active)
            harness.clock.advance(by: SyncPublisher.minimumInterval)
            await relaunched.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: used)]))
            await relaunched.publisher.tick()
            #expect(try harness.secrets.read(SyncSecretAccount.publisherId) == id)
        }
        let ids = await harness.google.uploadedPublisherIds()
        #expect(ids == [id, id, id])
        let documents = await harness.google.uploadedDocuments()
        #expect(documents.allSatisfy { $0["publisherId"] as? String == id })
    }

    @Test("the publisherId changes only when sync is turned on again after reaching stopped")
    func publisherIdChangesOnlyAfterStopped() async throws {
        let harness = try await SyncHarness.active()
        let id = try harness.secrets.read(SyncSecretAccount.publisherId)
        await #expect(throws: SyncActivationError.unavailable) {
            try await harness.publisher.activate(account: SyncFakes.account)
        }
        await harness.publisher.setStopCheckpoint { gap in if gap == .afterStoppingWrite { throw CancellationError() } }
        await harness.publisher.stop()
        #expect(await harness.publisher.status().phase == .stopping)
        await #expect(throws: SyncActivationError.unavailable) {
            try await harness.publisher.activate(account: SyncFakes.account)
        }
        #expect(try harness.secrets.read(SyncSecretAccount.publisherId) == id)
    }
}
