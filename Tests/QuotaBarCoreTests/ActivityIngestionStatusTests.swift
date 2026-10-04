import Testing
import Foundation
@testable import QuotaBarCore

/// The activity table is empty until the first full ingestion has walked every
/// CLI transcript, and partly filled while it runs. Anything that displays it
/// has to be able to tell that from "nothing happened".
@Suite("Activity ingestion status")
struct ActivityIngestionStatusTests {

    private struct Boom: Error {}

    private struct StubAdapter: ActivityAdapter {
        let sourceIdentifier: String
        var records: [ActivityRecord] = []
        var fails = false

        func collectActivities(watermarks: [String: ActivityWatermark]) async throws -> ActivityIngestResult {
            if fails { throw Boom() }
            return ActivityIngestResult(records: records, watermarks: [])
        }
    }

    private func record(_ source: String, _ id: String) -> ActivityRecord {
        ActivityRecord(
            source: source, recordId: id, sessionId: "s",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000), totalTokens: 5)
    }

    private func makeDatabase() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("h.sqlite3"))
    }

    private func store(_ url: URL) -> QuotaHistoryStore {
        QuotaHistoryStore(databaseURL: url, isTestHost: true)
    }

    @Test("before any pass the table cannot be trusted, and nothing is running")
    func beforeAnyPass() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = ActivityIngestionEngine(store: store(url), adapters: [StubAdapter(sourceIdentifier: "a")])
        let status = await engine.status()
        #expect(status == .init(hasCompletedFullPass: false, lastPassFailed: false, isRunning: false))
    }

    @Test("a pass in which every adapter succeeds completes the first pass, and a restart remembers it")
    func completesAndPersists() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = ActivityIngestionEngine(
            store: store(url),
            adapters: [StubAdapter(sourceIdentifier: "a", records: [record("a", "1")]), StubAdapter(sourceIdentifier: "b")])
        _ = try await engine.ingestAll()
        #expect(await engine.status().hasCompletedFullPass)
        #expect(await engine.status().lastPassFailed == false)

        // A new engine over the same file: a relaunch.
        let relaunched = ActivityIngestionEngine(store: store(url), adapters: [StubAdapter(sourceIdentifier: "a")])
        #expect(await relaunched.status().hasCompletedFullPass)
    }

    /// The defect this guards: a source that cannot be read leaves its tokens
    /// out of every total, and the pass looks like it finished.
    @Test("a pass with one failing adapter is not a completed pass, but keeps the others' records")
    func failingAdapter() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(url)
        let engine = ActivityIngestionEngine(
            store: s,
            adapters: [StubAdapter(sourceIdentifier: "a", records: [record("a", "1")]), StubAdapter(sourceIdentifier: "b", fails: true)])
        await #expect(throws: Boom.self) { try await engine.ingestAll() }
        let status = await engine.status()
        #expect(status.hasCompletedFullPass == false)
        #expect(status.lastPassFailed)
        #expect(try await s.fetchActivities().count == 1)
    }

    @Test("a later clean pass completes it, and a later failure is flagged without un-completing it")
    func failureAfterSuccess() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(url)

        let broken = ActivityIngestionEngine(store: s, adapters: [StubAdapter(sourceIdentifier: "a", fails: true)])
        _ = try? await broken.ingestAll()
        #expect(await broken.status().hasCompletedFullPass == false)

        let clean = ActivityIngestionEngine(store: s, adapters: [StubAdapter(sourceIdentifier: "a")])
        _ = try await clean.ingestAll()
        #expect(await clean.status() == .init(hasCompletedFullPass: true, lastPassFailed: false, isRunning: false))

        let failing = ActivityIngestionEngine(store: s, adapters: [StubAdapter(sourceIdentifier: "a", fails: true)])
        _ = try? await failing.ingestAll()
        let status = await failing.status()
        #expect(status.hasCompletedFullPass)      // the first pass did finish
        #expect(status.lastPassFailed)            // but data is missing now
    }

    @Test("wiping the data wipes the claim, so an empty database never says it is complete")
    func removeAllClearsIt() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(url)
        let engine = ActivityIngestionEngine(store: s, adapters: [StubAdapter(sourceIdentifier: "a")])
        _ = try await engine.ingestAll()
        #expect(await engine.status().hasCompletedFullPass)
        try await s.removeAll()
        #expect(await engine.status().hasCompletedFullPass == false)
    }

    @Test("the store reports when the first full pass finished")
    func storeAccessors() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(url)
        #expect(try await s.activityFullPassCompletedAt() == nil)
        let when = Date(timeIntervalSince1970: 1_800_000_123)
        try await s.markActivityFullPassCompleted(at: when)
        #expect(try await s.activityFullPassCompletedAt() == when)
    }
}
