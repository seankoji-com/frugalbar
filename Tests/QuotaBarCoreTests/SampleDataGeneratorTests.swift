import Foundation
import Testing
@testable import QuotaBarCore

@Suite("SampleDataGenerator")
struct SampleDataGeneratorTests {

    /// Fixed clock: the fixture must not depend on when the tests run.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(_ tag: String) throws -> QuotaHistoryStore {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return QuotaHistoryStore(databaseURL: tempDir.appendingPathComponent("sample.sqlite3"), isTestHost: true)
    }

    @Test("Sample data generates readings and activities with exhaustion and resets")
    func sampleDataGenerationTest() async throws {
        let store = try makeStore("basic")

        try await SampleDataGenerator.ensureSampleData(in: store, now: now)

        let readings = try await store.fetchReadings(since: Date.distantPast)
        #expect(!readings.isEmpty)

        let claudeReadings = readings.filter { $0.vendor == VendorIdentifier.claude.rawValue }
        #expect(!claudeReadings.isEmpty)

        let exhausted = readings.first(where: { $0.fraction == 1.0 && $0.isBlocked })
        #expect(exhausted != nil)

        let activities = try await store.fetchActivities()
        #expect(!activities.isEmpty)
        let projects = Set(activities.compactMap(\.projectPath))
        #expect(projects.count >= 2)

        let initialReadingCount = readings.count
        try await SampleDataGenerator.ensureSampleData(in: store, force: false, now: now)
        let readingsAfter = try await store.fetchReadings(since: Date.distantPast)
        #expect(readingsAfter.count == initialReadingCount)
    }

    @Test("two generations from the same clock are identical")
    func generationIsDeterministic() async throws {
        let first = try makeStore("det-a")
        let second = try makeStore("det-b")

        try await SampleDataGenerator.ensureSampleData(in: first, now: now)
        try await SampleDataGenerator.ensureSampleData(in: second, now: now)

        let firstReadings = try await first.fetchReadings(since: Date.distantPast)
        let secondReadings = try await second.fetchReadings(since: Date.distantPast)
        let firstActivities = try await first.fetchActivities()
        let secondActivities = try await second.fetchActivities()

        // `UUID()` and `Double.random` used to make both of these differ run to
        // run — including the row counts — so the fixture could not reproduce
        // anything reported against it.
        #expect(firstReadings.map(\.fraction) == secondReadings.map(\.fraction))
        #expect(firstReadings.map(\.measuredAt) == secondReadings.map(\.measuredAt))
        #expect(firstActivities.map(\.recordId).sorted() == secondActivities.map(\.recordId).sorted())
        #expect(firstActivities.map(\.totalTokens) == secondActivities.map(\.totalTokens))
    }

    @Test("the exhaustion event is where the fixture says it is, measured from the fixture start")
    func exhaustionIsOnTheDocumentedFixtureDay() async throws {
        let store = try makeStore("exhaustion")
        try await SampleDataGenerator.ensureSampleData(in: store, now: now)

        let readings = try await store.fetchReadings(since: Date.distantPast)
        let exhausted = readings.filter { $0.fraction == 1.0 && $0.isBlocked }
        #expect(!exhausted.isEmpty)

        // The generator anchors to local midnight, so compute day indices the
        // same way rather than from raw wall-clock arithmetic.
        let start = Calendar.current.startOfDay(for: now)
            .addingTimeInterval(-Double(SampleDataGenerator.daysToGenerate - 1) * 86_400)
        let days = Set(exhausted.map { Int($0.measuredAt.timeIntervalSince(start) / 86_400) })

        // Previously this was keyed on `Calendar.component(.weekday) == 4`, which
        // is Wednesday — the exhaustion window wandered to whichever calendar day
        // matched, and the comment claimed "day 3".
        #expect(days == [SampleDataGenerator.exhaustionDayIndex])
    }

    @Test("force: regenerates in place instead of appending a second fixture")
    func forceIsIdempotent() async throws {
        let store = try makeStore("force")
        try await SampleDataGenerator.ensureSampleData(in: store, now: now)

        let readingsBefore = try await store.fetchReadings(since: Date.distantPast).count
        let activitiesBefore = try await store.fetchActivities().count

        try await SampleDataGenerator.ensureSampleData(in: store, force: true, now: now)

        let readingsAfter = try await store.fetchReadings(since: Date.distantPast).count
        let activitiesAfter = try await store.fetchActivities().count

        // Activities used to double on every call, because each one got a fresh
        // UUID for `recordId` and so never collided on the dedup key.
        #expect(readingsAfter == readingsBefore)
        #expect(activitiesAfter == activitiesBefore)
    }

    @Test("concurrent generation produces one fixture, not three")
    func concurrentGenerationDoesNotMultiply() async throws {
        let concurrent = try makeStore("race")
        async let a: Void = SampleDataGenerator.ensureSampleData(in: concurrent, now: now)
        async let b: Void = SampleDataGenerator.ensureSampleData(in: concurrent, now: now)
        async let c: Void = SampleDataGenerator.ensureSampleData(in: concurrent, now: now)
        _ = try await (a, b, c)

        let single = try makeStore("race-baseline")
        try await SampleDataGenerator.ensureSampleData(in: single, now: now)

        // The History window used to start three of these at once, one per
        // `.task(id:)`, and each saw an empty store and wrote a full fixture.
        #expect(try await concurrent.fetchReadings(since: Date.distantPast).count
            == (try await single.fetchReadings(since: Date.distantPast).count))
        #expect(try await concurrent.fetchActivities().count
            == (try await single.fetchActivities().count))
    }
}
