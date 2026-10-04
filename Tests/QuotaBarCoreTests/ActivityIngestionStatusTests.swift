import Testing
import Foundation
@testable import QuotaBarCore

/// The activity table is empty until a pass has read every CLI transcript,
/// stale after a restart until the next pass has caught up, and missing
/// whatever an adapter could not read. Anything that displays it has to be
/// able to tell those from "nothing happened".
@Suite("Activity ingestion status")
struct ActivityIngestionStatusTests {

    private struct Boom: Error {}

    private struct StubAdapter: ActivityAdapter {
        let sourceIdentifier: String
        var records: [ActivityRecord] = []
        var fails = false
        var skipped = 0

        func collectActivities(watermarks: [String: ActivityWatermark]) async throws -> ActivityIngestResult {
            if fails { throw Boom() }
            return ActivityIngestResult(records: records, watermarks: [], skipped: skipped)
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct GatedAdapter: ActivityAdapter {
        let sourceIdentifier = "gated"
        let gate: Gate
        func collectActivities(watermarks: [String: ActivityWatermark]) async throws -> ActivityIngestResult {
            await gate.wait()
            return ActivityIngestResult()
        }
    }

    private typealias Status = ActivityIngestionEngine.Status

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

    @Test("before any pass nothing can be vouched for, and nothing is running")
    func beforeAnyPass() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = ActivityIngestionEngine(store: store(url), adapters: [StubAdapter(sourceIdentifier: "a")])
        #expect(await engine.status() == Status(hasCompletedCleanPass: false, lastPassIncomplete: false, isRunning: false))
    }

    @Test("a pass in which every adapter reads everything completes it")
    func cleanPass() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = ActivityIngestionEngine(
            store: store(url),
            adapters: [StubAdapter(sourceIdentifier: "a", records: [record("a", "1")]), StubAdapter(sourceIdentifier: "b")])
        _ = try await engine.ingestAll()
        #expect(await engine.status() == Status(hasCompletedCleanPass: true, lastPassIncomplete: false, isRunning: false))
    }

    /// The defect this guards: after a restart the database still holds the
    /// last run's data, but everything the tools wrote while the app was
    /// closed is missing until this run's first pass catches up. A flag
    /// remembered from the earlier run would call that table complete.
    @Test("a relaunched engine has completed nothing, whatever the database holds")
    func relaunchStartsAgain() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = ActivityIngestionEngine(
            store: store(url), adapters: [StubAdapter(sourceIdentifier: "a", records: [record("a", "1")])])
        _ = try await first.ingestAll()
        #expect(await first.status().hasCompletedCleanPass)

        let relaunched = ActivityIngestionEngine(store: store(url), adapters: [StubAdapter(sourceIdentifier: "a")])
        #expect(try await store(url).fetchActivities().count == 1)    // the data is there...
        #expect(await relaunched.status() == Status(hasCompletedCleanPass: false, lastPassIncomplete: false, isRunning: false))
        _ = try await relaunched.ingestAll()
        #expect(await relaunched.status().hasCompletedCleanPass)      // ...and this run has caught up
    }

    /// A source that cannot be read leaves its tokens out of every total, and
    /// the pass must not look like it finished.
    @Test("a pass with one failing adapter is not complete, but keeps the others' records")
    func failingAdapter() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(url)
        let engine = ActivityIngestionEngine(
            store: s,
            adapters: [StubAdapter(sourceIdentifier: "a", records: [record("a", "1")]), StubAdapter(sourceIdentifier: "b", fails: true)])
        await #expect(throws: Boom.self) { try await engine.ingestAll() }
        #expect(await engine.status() == Status(hasCompletedCleanPass: false, lastPassIncomplete: true, isRunning: false))
        #expect(try await s.fetchActivities().count == 1)
    }

    /// An adapter that read what it could but skipped an input it could not
    /// open does not throw, so this is the case a status built only on
    /// exceptions gets wrong.
    @Test("a pass in which an adapter skipped an unreadable input is incomplete, without throwing")
    func skippedInput() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(url)
        let engine = ActivityIngestionEngine(
            store: s,
            adapters: [StubAdapter(sourceIdentifier: "a", records: [record("a", "1")], skipped: 2)])
        #expect(try await engine.ingestAll() == 1)       // no throw, records kept
        #expect(await engine.status() == Status(hasCompletedCleanPass: false, lastPassIncomplete: true, isRunning: false))
        #expect(try await s.fetchActivities().count == 1)
    }

    @Test("a pass that fails after a clean one in the same run is flagged, and a clean one clears it")
    func sameEngineAcrossPasses() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        actor Switch { var fail = false; func set(_ v: Bool) { fail = v } }
        struct Flaky: ActivityAdapter {
            let sourceIdentifier = "flaky"
            let control: Switch
            func collectActivities(watermarks: [String: ActivityWatermark]) async throws -> ActivityIngestResult {
                if await control.fail { throw Boom() }
                return ActivityIngestResult()
            }
        }
        let control = Switch()
        let engine = ActivityIngestionEngine(store: store(url), adapters: [Flaky(control: control)])

        _ = try await engine.ingestAll()
        #expect(await engine.status() == Status(hasCompletedCleanPass: true, lastPassIncomplete: false, isRunning: false))

        await control.set(true)
        _ = try? await engine.ingestAll()
        // This run did complete a pass once; what matters now is that the latest could not.
        #expect(await engine.status() == Status(hasCompletedCleanPass: true, lastPassIncomplete: true, isRunning: false))

        await control.set(false)
        _ = try await engine.ingestAll()
        #expect(await engine.status() == Status(hasCompletedCleanPass: true, lastPassIncomplete: false, isRunning: false))
    }

    @Test("a pass in flight is reported as running, and a second call during it changes nothing")
    func running() async throws {
        let (dir, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        let engine = ActivityIngestionEngine(store: store(url), adapters: [GatedAdapter(gate: gate)])
        let pass = Task { try await engine.ingestAll() }
        for _ in 0..<300 {
            if await engine.status().isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await engine.status() == Status(hasCompletedCleanPass: false, lastPassIncomplete: false, isRunning: true))
        #expect(try await engine.ingestAll() == 0)        // no-op while one is in flight
        #expect(await engine.status().hasCompletedCleanPass == false)
        await gate.release()
        _ = try await pass.value
        #expect(await engine.status() == Status(hasCompletedCleanPass: true, lastPassIncomplete: false, isRunning: false))
    }
}
