import Foundation
import Security
import Testing
@testable import QuotaBarCore

@Suite("Sync secret refresh retry (PR 192 review)")
struct SyncSecretRefreshRetryTests {
    @Test("a refresh that leaves the secrets unreadable stays armed across an unrelated publish failure")
    func failedRefreshStaysArmed() async throws {
        let harness = try await SyncHarness.active()
        let start = harness.clock.now()
        // A locked Keychain fails the first publish and arms the refresh.
        harness.secrets.failReads(.unknown(-25308)) // errSecInteractionNotAllowed
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(harness.secrets.refreshCount == 0)

        // The refresh still reports the secrets unreadable, and Google then
        // fails the upload for an unrelated reason.
        harness.secrets.failReads(nil)
        harness.secrets.answerRefreshes([false])
        await harness.google.configure { $0.uploadModes = [.status(500)] }
        harness.clock.set(start.addingTimeInterval(2 * 60))
        await harness.publisher.tick()
        #expect(harness.secrets.refreshCount == 1)

        // The next due attempt refreshes again rather than giving up.
        harness.clock.set(start.addingTimeInterval(6 * 60))
        await harness.publisher.tick()
        #expect(harness.secrets.refreshCount == 2)
    }

    @Test("a non-Keychain publish error does not disarm a refresh that has not yet succeeded")
    func unrelatedErrorKeepsRefreshArmed() async throws {
        let harness = try await SyncHarness.active()
        let start = harness.clock.now()
        harness.secrets.failReads(.unknown(-25308)) // errSecInteractionNotAllowed
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        // The refresh fails, then the pre-upload checkpoint fails to save for
        // a reason that has nothing to do with Keychain.
        harness.secrets.failReads(nil)
        harness.secrets.answerRefreshes([false])
        harness.store.failWrites()
        harness.clock.set(start.addingTimeInterval(2 * 60))
        await harness.publisher.tick()
        #expect(harness.secrets.refreshCount == 1)

        harness.store.failWrites(false)
        harness.clock.set(start.addingTimeInterval(30 * 60))
        await harness.publisher.tick()
        #expect(harness.secrets.refreshCount == 2)
    }

    @Test("R15-01: an Unlock clears a Keychain backoff but not a later unrelated one, even with the refresh still armed")
    func unlockKeepsUnrelatedBackoff() async throws {
        let harness = try await SyncHarness.active()
        let start = harness.clock.now()
        harness.secrets.failReads(.unknown(-25308)) // errSecInteractionNotAllowed
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        // The refresh fails and the next attempt fails for a non-Keychain
        // reason, which sets its own backoff while the refresh stays armed.
        harness.secrets.failReads(nil)
        harness.secrets.answerRefreshes([false])
        harness.store.failWrites()
        harness.clock.set(start.addingTimeInterval(2 * 60))
        await harness.publisher.tick()
        harness.store.failWrites(false)
        let backedOffUntil = await harness.publisher.nextWakeup()
        #expect(backedOffUntil == start.addingTimeInterval(2 * 60 + SyncPublisher.backoff(2)))

        await harness.publisher.vaultDidUnlock()
        #expect(await harness.publisher.nextWakeup() == backedOffUntil)
    }
}

@Suite("Sync secret refresh readiness (PR 192 review)")
struct SyncSecretRefreshReadinessTests {
    @Test("R15-02: a provider-key scan failure does not make readable Sync secrets report unrefreshed")
    func providerKeyScanFailureDoesNotBlockSyncRefresh() async throws {
        let backend = InMemoryKeychainBackend()
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("frugalbar-vault-test-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let vault = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        try vault.write("rt-live", namespace: .sync, account: SyncSecretAccount.refreshToken)
        try vault.write("pub-real", namespace: .sync, account: SyncSecretAccount.publisherId)

        let fresh = KeychainVault(keysService: "test.keys", syncService: "test.sync", backend: backend, lockFileURL: lockURL)
        backend.setListFailure(service: "test.keys", status: errSecAuthFailed)
        let secrets = KeychainSyncSecretStore(service: "test.sync", vault: fresh)
        #expect(await secrets.refreshNonInteractively())
        #expect(!fresh.statusSnapshot().legacyScanSucceeded)
        #expect(try secrets.read(SyncSecretAccount.refreshToken) == "rt-live")
    }
}

private func gaps(_ times: [Date]) -> [TimeInterval] {
    zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
}

/// The billing-cycle fixture, as a poll measured at `measuredAt` would give it.
private func billingCycleSource(measuredAt: Date) throws -> SyncExportSource {
    var raw = try SnapshotFixtures.rawInput("billing-cycle")
    var snapshots = try #require(raw["snapshots"] as? [[String: Any]])
    for index in snapshots.indices { snapshots[index]["lastUpdated"] = FakeGoogle.rfc3339(measuredAt) }
    raw["snapshots"] = snapshots
    let input = try SnapshotFixtures.decodeInput(raw)
    return SyncExportSource(snapshots: input.snapshots, events: input.events, notificationPrefs: input.notificationPrefs)
}

@Suite("Sync publishing cadence (REQ-MAC-PUBLISH)")
struct SyncPublishTests {

    // MARK: (a)

    @Test("material changes publish at most once every 2 minutes")
    func materialChangesAreRateLimited() async throws {
        let harness = try await SyncHarness.active()
        var times: [Date] = []
        let end = harness.clock.now().addingTimeInterval(20 * 60)
        var step = 0
        while harness.clock.now() < end {
            step += 1
            await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: Double(step % 100) / 100)]))
            let before = await harness.google.uploads.count
            await harness.drain()
            if await harness.google.uploads.count > before { times.append(harness.clock.now()) }
            harness.clock.advance(by: 10)
        }
        #expect(times.count == 10)
        #expect(gaps(times).allSatisfy { $0 >= SyncPublisher.minimumInterval })
    }

    @Test("a relaunch keeps the 2-minute floor from the last attempt")
    func relaunchKeepsTheTwoMinuteFloor() async throws {
        let harness = try await SyncHarness.active()
        let t0 = harness.clock.now()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        harness.clock.advance(by: 1)
        let relaunched = harness.relaunched()
        await relaunched.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        await relaunched.publisher.tick()
        #expect(await harness.google.uploads.count == 1)
        #expect(await relaunched.publisher.nextWakeup() == t0.addingTimeInterval(SyncPublisher.minimumInterval))

        // The run ticks every 10 s from t0+1, so the slot is taken at t0+121.
        let times = await relaunched.run(for: 3 * 60)
        #expect(times == [t0.addingTimeInterval(SyncPublisher.minimumInterval + 1)])
    }

    @Test("a relaunch while an upload is still in flight keeps the 2-minute floor from that attempt")
    func relaunchMidUploadKeepsTheTwoMinuteFloor() async throws {
        let harness = try await SyncHarness.active()
        let t0 = harness.clock.now()
        await harness.google.configure { $0.uploadModes = [.hang] }
        await harness.publisher.submit(SyncFakes.source())
        let first = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })

        // The process dies with the upload unanswered.
        harness.clock.advance(by: 1)
        let relaunched = harness.relaunched()
        await relaunched.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        await relaunched.publisher.tick()
        #expect(await harness.google.uploads.count == 1)
        #expect(await relaunched.publisher.nextWakeup() == t0.addingTimeInterval(SyncPublisher.minimumInterval))

        first.cancel()
        await harness.google.releaseAll()
        await first.value
    }

    @Test("an attempt time the wall clock has gone back past counts from now, at relaunch and on a clock change")
    func floorCountsFromNowAfterClockGoesBack() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        let back = harness.clock.now().addingTimeInterval(-3600)
        harness.clock.set(back)
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.7)]))
        await harness.publisher.clockDidChange()
        #expect(await harness.publisher.nextWakeup() == back.addingTimeInterval(SyncPublisher.minimumInterval))

        let relaunched = harness.relaunched()
        await relaunched.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        #expect(await relaunched.publisher.nextWakeup() == back.addingTimeInterval(SyncPublisher.minimumInterval))
    }

    @Test("a material change publishes at the next 2-minute slot, not at the heartbeat")
    func materialChangePublishesAtNextSlot() async throws {
        let harness = try await SyncHarness.active()
        let t0 = harness.clock.now()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        harness.clock.advance(by: 30)
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
        #expect(await harness.publisher.nextWakeup() == t0.addingTimeInterval(SyncPublisher.minimumInterval))
    }

    @Test("a change to measuredAt alone is not material and waits for the heartbeat")
    func measuredAtAloneIsNotMaterial() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        for minute in 1...14 {
            harness.clock.advance(by: 60)
            await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(measuredAt: harness.clock.now())]))
            await harness.drain()
            #expect(await harness.google.uploads.count == 1, "minute \(minute)")
        }
        harness.clock.advance(by: 60)
        await harness.drain()
        #expect(await harness.google.uploads.count == 2)
    }

    @Test("material fields: event ids and notification prefs are material; event text and timestamps are not")
    func materialKeyFields() throws {
        func document(_ overrides: (inout [String: Any]) -> Void) throws -> Data {
            var root: [String: Any] = [
                "publishedAt": "2026-10-15T00:00:00.000Z", "macClockOffsetMs": "10", "macClockSampledAt": NSNull(),
                "providersOmitted": 0,
                "providers": [["instanceId": "a", "measuredAt": "x", "lastAttemptAt": "y",
                               "lastPollFailure": ["reason": "offline", "at": "z"], "status": ["kind": "measured"]]],
                "events": [["id": "e1", "title": "One"]],
                "notificationPrefs": ["disabledKinds": [], "resetAlertVendors": []],
            ]
            overrides(&root)
            return try JSONSerialization.data(withJSONObject: root)
        }
        let base = try #require(SyncMaterial.key(try document { _ in }))
        let timesChanged = try document {
            $0["publishedAt"] = "later"
            $0["macClockOffsetMs"] = "99"
            $0["providers"] = [["instanceId": "a", "measuredAt": "x2", "lastAttemptAt": "y2",
                                "lastPollFailure": ["reason": "offline", "at": "z2"], "status": ["kind": "measured"]]]
            $0["events"] = [["id": "e1", "title": "Renamed"]]
        }
        #expect(SyncMaterial.key(timesChanged) == base)
        #expect(SyncMaterial.key(try document { $0["events"] = [["id": "e2", "title": "One"]] }) != base)
        #expect(SyncMaterial.key(try document {
            $0["notificationPrefs"] = ["disabledKinds": ["newModel"], "resetAlertVendors": []]
        }) != base)
        #expect(SyncMaterial.key(try document {
            $0["providers"] = [["instanceId": "a", "measuredAt": "x", "lastAttemptAt": "y",
                                "lastPollFailure": ["reason": "timedOut", "at": "z"], "status": ["kind": "measured"]]]
        }) != base)
    }

    // MARK: (b)

    @Test("a full-document heartbeat goes out at least every 15 minutes, unconditionally")
    func heartbeatEveryFifteenMinutes() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        let times = await harness.run(for: 61 * 60)
        #expect(times.count == 5)
        #expect(gaps(times).allSatisfy { $0 <= SyncPublisher.heartbeatInterval + 10 })
        // Each heartbeat uploads the whole document, not a diff.
        let documents = await harness.google.uploadedDocuments()
        #expect(documents.allSatisfy { ($0["providers"] as? [[String: Any]])?.count == 1 })
    }

    // MARK: (c)

    @Test("stable quotas with a billing cycle produce only heartbeats")
    func billingCycleProducesOnlyHeartbeats() async throws {
        let harness = try await SyncHarness.active()
        var times: [Date] = []
        let end = harness.clock.now().addingTimeInterval(46 * 60)
        while harness.clock.now() < end {
            // A poll every 2 minutes: same figures, a new measuredAt.
            try await harness.publisher.submit(billingCycleSource(measuredAt: harness.clock.now()))
            let before = await harness.google.uploads.count
            await harness.drain()
            if await harness.google.uploads.count > before { times.append(harness.clock.now()) }
            harness.clock.advance(by: SyncPublisher.minimumInterval)
        }
        // Polls every 2 minutes, so each heartbeat lands on the first poll
        // at or after the 15-minute mark.
        #expect(times.count == 3)
        #expect(gaps(times).allSatisfy {
            $0 >= SyncPublisher.heartbeatInterval && $0 <= SyncPublisher.heartbeatInterval + SyncPublisher.minimumInterval
        })
    }

    @Test("repeated identical failures produce no material publish", arguments: [true, false])
    func repeatedFailuresAreNotMaterial(hadReading: Bool) async throws {
        let harness = try await SyncHarness.active()
        var times: [Date] = []
        let end = harness.clock.now().addingTimeInterval(46 * 60)
        while harness.clock.now() < end {
            let now = harness.clock.now()
            var snapshot: QuotaSnapshot
            if hadReading {
                // The old figures kept, with this poll's failure.
                snapshot = SyncFakes.snapshot(measuredAt: SyncFakes.start.addingTimeInterval(-600))
                snapshot.staleReading = StaleReading(reason: .offline, at: now)
            } else {
                snapshot = SyncFakes.snapshot(measuredAt: now, status: .unavailable(.offline))
            }
            await harness.publisher.submit(SyncFakes.source([snapshot]))
            let before = await harness.google.uploads.count
            await harness.drain()
            if await harness.google.uploads.count > before { times.append(now) }
            harness.clock.advance(by: SyncPublisher.minimumInterval)
        }
        #expect(times.count == 3)
        #expect(gaps(times).allSatisfy {
            $0 >= SyncPublisher.heartbeatInterval && $0 <= SyncPublisher.heartbeatInterval + SyncPublisher.minimumInterval
        })
    }

    // MARK: (d)

    @Test("publishing runs off the BackgroundScheduler path: a poll hands over its input and returns while an upload hangs")
    func publishingIsOffTheSchedulerPath() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.hang] }
        await harness.publisher.submit(SyncFakes.source())
        let driver = Task { await harness.publisher.tick() }
        #expect(await eventually { await harness.google.heldCount == 1 })

        let scheduler = BackgroundScheduler()
        let publisher = harness.publisher
        await scheduler.addHandler {
            await publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.7)]))
        }
        await scheduler.fire()   // returns with the upload still in flight
        #expect(await harness.google.heldCount == 1)
        #expect(await harness.google.uploads.count == 1)

        // The upload's own 20 s timeout ends it, as an uncertain outcome.
        harness.clock.advance(by: SyncPublisher.requestTimeout - 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await harness.google.heldCount == 1)
        harness.clock.advance(by: 1)
        await driver.value
        #expect(await harness.google.heldCount == 0)
        #expect(await harness.publisher.status().lastError == "The last upload's outcome is unknown; publishing again")
    }

    @Test("every Drive request has a 20 s timeout and failures back off")
    func requestsTimeOutAndFailuresBackOff() async throws {
        #expect(SyncPublisher.requestTimeout == 20)
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.uploadModes = [.status(403), .status(403), .status(403)] }
        await harness.publisher.submit(SyncFakes.source())
        var attempts: [Date] = []
        for _ in 0..<3 {
            attempts.append(harness.clock.now())
            await harness.publisher.tick()
            harness.clock.set(try #require(await harness.publisher.nextWakeup()))
        }
        #expect(gaps(attempts) == [SyncPublisher.backoff(1), SyncPublisher.backoff(2)])
        #expect(SyncPublisher.backoff(10) == 15 * 60)
        #expect(await harness.publisher.status().lastError == "Google Drive answered 403; retrying")
    }

    @Test("status carries the last successful publish and the last error")
    func statusCarriesLastPublishAndError() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let published = harness.clock.now()
        #expect(await harness.publisher.status().lastSuccessfulPublishAt == published)
        #expect(await harness.publisher.status().lastError == nil)

        await harness.google.configure { $0.uploadModes = [.status(500)] }
        harness.clock.advance(by: SyncPublisher.heartbeatInterval)
        await harness.publisher.tick()
        let status = await harness.publisher.status()
        #expect(status.lastSuccessfulPublishAt == published)
        #expect(status.lastError == "The last upload's outcome is unknown; publishing again")
    }

    @Test("an export failure withholds the publish before Google is contacted, and Settings shows it")
    func exportFailureWithholdsPublish() async throws {
        let harness = try await SyncHarness.active()
        // Two snapshots with one instance id collide.
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot("same"), SyncFakes.snapshot("same")]))
        await harness.publisher.tick()
        #expect(await harness.google.requests.isEmpty)
        #expect(await harness.publisher.status().exportMessage == "Sync export error: identity collision")
    }

    @Test("notification preferences are exported from the Mac's own settings")
    func notificationPrefsFromSettings() {
        let prefs = SyncExportSource.notificationPrefs(
            enabledKinds: CredentialStore.defaultEventNotificationKinds.subtracting([.newModel]),
            resetAlertVendors: [.claude])
        #expect(prefs.disabledKinds == [.newModel])
        #expect(prefs.resetAlertVendors == [.claude])
    }
}

@Suite("Sync clock sample (REQ-MAC-CLOCK)")
struct SyncClockTests {

    private static func provider(_ document: [String: Any], id: String) -> [String: Any]? {
        (document["providers"] as? [[String: Any]])?
            .first { $0["instanceId"] as? String == SnapshotExportIdentity.digest(id) }
    }

    @Test("the offset and its sample time come from the pre-upload metadata response's Date header")
    func sampleComesFromMetadataDateHeader() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.serverOffset = 5 }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()   // creates the file: no metadata yet, the listing's header

        await harness.google.configure { $0.metadataServerOffset = .some(90) }
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.6)]))
        await harness.publisher.tick()

        let documents = await harness.google.uploadedDocuments()
        #expect(documents.map { $0["macClockOffsetMs"] as? String } == ["5000", "90000"])
        #expect(documents[1]["macClockSampledAt"] as? String == ExportText.timestamp(harness.clock.now()))
    }

    @Test("with no Date header, the offset and its sample time are both null")
    func missingHeaderMeansNullSample() async throws {
        let harness = try await SyncHarness.active()
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        await harness.google.configure {
            $0.serverOffset = nil
            $0.metadataServerOffset = .some(nil)
        }
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.6)]))
        await harness.publisher.tick()
        let document = try #require(await harness.google.uploadedDocuments().last)
        #expect(document["macClockOffsetMs"] is NSNull)
        #expect(document["macClockSampledAt"] is NSNull)
    }

    @Test("NSSystemClockDidChangeNotification marks every retained reading untrusted until it is re-measured")
    func clockChangeNotificationDistrustsRetainedReadings() async throws {
        let harness = try await SyncHarness.active()
        let center = NotificationCenter()
        let observer = SyncClockChangeObserver(publisher: harness.publisher, center: center)
        let t0 = harness.clock.now()
        await harness.publisher.submit(SyncFakes.source([
            SyncFakes.snapshot("first", measuredAt: t0), SyncFakes.snapshot("second", measuredAt: t0),
        ]))
        await harness.publisher.tick()
        let before = try #require(await harness.google.uploadedDocuments().first)
        #expect(Self.provider(before, id: "first")?["measuredAtTrusted"] as? Bool == true)

        center.post(name: .NSSystemClockDidChange, object: nil)
        #expect(await eventually { await harness.publisher.clockDiscontinuities == 1 })

        // "first" is measured again; "second" keeps its old reading.
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.submit(SyncFakes.source([
            SyncFakes.snapshot("first", measuredAt: harness.clock.now()), SyncFakes.snapshot("second", measuredAt: t0),
        ]))
        await harness.publisher.tick()
        let after = try #require(await harness.google.uploadedDocuments().last)
        #expect(Self.provider(after, id: "first")?["measuredAtTrusted"] as? Bool == true)
        #expect(Self.provider(after, id: "second")?["measuredAtTrusted"] as? Bool == false)
        withExtendedLifetime(observer) {}
    }

    @Test("a jump of more than 5 minutes between samples marks retained readings untrusted; less does not",
          arguments: [(6 * 60.0, false), (4 * 60.0, true)])
    func offsetJumpDistrustsRetainedReadings(jump: TimeInterval, trusted: Bool) async throws {
        let harness = try await SyncHarness.active()
        let t0 = harness.clock.now()
        await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot("first", measuredAt: t0)]))
        await harness.publisher.tick()   // sample: offset 0

        await harness.google.configure { $0.metadataServerOffset = .some(jump) }
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        var changed = SyncFakes.source([SyncFakes.snapshot("first", measuredAt: t0)])
        changed.notificationPrefs = SnapshotExportNotificationPrefs(resetAlertVendors: [.claude])
        await harness.publisher.submit(changed)
        await harness.publisher.tick()
        let document = try #require(await harness.google.uploadedDocuments().last)
        #expect(Self.provider(document, id: "first")?["measuredAtTrusted"] as? Bool == trusted)

        // Measured again after the jump: trusted.
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        var remeasured = SyncFakes.source([SyncFakes.snapshot("first", measuredAt: harness.clock.now())])
        remeasured.notificationPrefs = changed.notificationPrefs
        await harness.publisher.submit(remeasured)
        await harness.publisher.tick()
        let latest = try #require(await harness.google.uploadedDocuments().last)
        #expect(Self.provider(latest, id: "first")?["measuredAtTrusted"] as? Bool == true)
    }

    @Test("a missing sample leaves the last one in place for the next comparison")
    func missingSampleKeepsLastOffset() {
        var trust = SyncClockTrust()
        let snapshot = SyncFakes.snapshot()
        let first = trust.sample(offsetMs: 0, retaining: [snapshot])
        let missing = trust.sample(offsetMs: nil, retaining: [snapshot])
        let jumped = trust.sample(offsetMs: 6 * 60 * 1000, retaining: [snapshot])
        let untrusted = trust.untrustedIDs(in: [snapshot])
        #expect(!first && !missing && jumped)
        #expect(untrusted == ["claude"])
    }
}
