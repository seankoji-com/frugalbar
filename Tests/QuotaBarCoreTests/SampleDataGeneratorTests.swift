import Foundation
import Testing
@testable import QuotaBarCore

@Suite("SampleDataGenerator")
struct SampleDataGeneratorTests {

    @Test("Sample data generates readings and activities with exhaustion and resets")
    func sampleDataGenerationTest() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-gen-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("sample.sqlite3")
        let store = QuotaHistoryStore(databaseURL: dbURL, isTestHost: true)

        try await SampleDataGenerator.ensureSampleData(in: store)

        let readings = try await store.fetchReadings(since: Date.distantPast)
        #expect(!readings.isEmpty)

        // Check for presence of Claude readings
        let claudeReadings = readings.filter { $0.vendor == VendorIdentifier.claude.rawValue }
        #expect(!claudeReadings.isEmpty)

        // Check for exhaustion event in readings
        let exhausted = readings.first(where: { $0.fraction == 1.0 && $0.isBlocked })
        #expect(exhausted != nil)

        // Check for activities generated
        let activities = try await store.fetchActivities()
        #expect(!activities.isEmpty)
        let projects = Set(activities.compactMap(\.projectPath))
        #expect(projects.count >= 2)

        let initialReadingCount = readings.count
        // Second call without force should be idempotent
        try await SampleDataGenerator.ensureSampleData(in: store, force: false)
        let readingsAfter = try await store.fetchReadings(since: Date.distantPast)
        #expect(readingsAfter.count == initialReadingCount)
    }
}
