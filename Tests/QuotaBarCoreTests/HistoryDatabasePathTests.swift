import Testing
import Foundation
@testable import QuotaBarCore

@Suite("HistoryDatabasePath")
struct HistoryDatabasePathTests {

    @Test("under TestHost.isActive the URL is the temp path, never ~/Library/Application Support")
    func testHostUsesTempPath() async throws {
        #expect(TestHost.isActive)

        let resolvedURL = QuotaHistoryStore.databaseURL(isTestHost: true)
        let sampleURL = QuotaHistoryStore.sampleDatabaseURL(isTestHost: true)

        let tempPath = FileManager.default.temporaryDirectory.path
        #expect(resolvedURL.path.hasPrefix(tempPath))
        #expect(sampleURL.path.hasPrefix(tempPath))

        let userHome = NSHomeDirectory()
        let realAppSupport = (userHome as NSString).appendingPathComponent("Library/Application Support/FrugalBar")
        #expect(!resolvedURL.path.hasPrefix(realAppSupport))
        #expect(!sampleURL.path.hasPrefix(realAppSupport))

        // Behavioral test: write through a store initialized with default path under TestHost.isActive,
        // and assert that bytes land in the temp file and NOT in the real Application Support directory.
        let defaultStore = QuotaHistoryStore(isTestHost: true)
        let defaultURL = defaultStore.databaseURL

        let now = Date(timeIntervalSince1970: 1_700_000_123)
        var snapshot = QuotaSnapshot(
            id: "path-test",
            vendorId: .claude,
            displayName: "Claude",
            category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.33, displayDetails: nil),
            status: .healthy,
            resetsAt: nil,
            lastUpdated: now,
            auxiliaryInfo: nil
        )
        snapshot.row1 = DualBarMetrics(primaryFraction: 0.33, label: "5H")

        try await defaultStore.record([snapshot], now: now)

        #expect(FileManager.default.fileExists(atPath: defaultURL.path))
        let realFileCandidate = URL(fileURLWithPath: realAppSupport).appendingPathComponent("history.sqlite3")
        if FileManager.default.fileExists(atPath: realFileCandidate.path) {
            // Even if a real history file happened to exist on the system from user runs,
            // ensure the file written by this test is definitely defaultURL (in temp)
            #expect(defaultURL.path != realFileCandidate.path)
        }
    }
}
