import Testing
import Foundation
@testable import QuotaBarCore

/// Reading history across OpenCode Go workspaces: the rows keep a workspace's
/// identity, a pre-workspace install's rows migrate to the legacy workspace
/// without re-entry, and a vendor-scoped query still finds every instance.
@Suite("OpenCode Go workspace history")
struct OpenCodeGoHistoryTests {

    private func makeIsolatedStore() -> (QuotaHistoryStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarGoTests-\(UUID().uuidString)", isDirectory: true)
        let dbURL = tempDir.appendingPathComponent("test-history.sqlite3")
        return (QuotaHistoryStore(databaseURL: dbURL, isTestHost: true), dbURL)
    }

    private func snapshot(
        id: String, displayName: String, fraction: Double, at date: Date
    ) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(
            id: id,
            vendorId: .opencode,
            displayName: displayName,
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Go", renewalDate: nil),
            status: .measured(.none),
            resetsAt: nil,
            lastUpdated: date,
            auxiliaryInfo: nil
        )
        snapshot.row1 = DualBarMetrics(
            primaryFraction: fraction, label: "WK", windowLength: QuotaWindow.week)
        return snapshot
    }

    private let legacyKey = OpenCodeGoWorkspaceStore.instanceID(for: OpenCodeGoWorkspaceStore.legacy)

    @Test("a pre-workspace `opencode` reading migrates to the legacy workspace key")
    func legacyRowsMigrateToLegacyWorkspace() async throws {
        let (store, dbURL) = makeIsolatedStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // The pre-workspace app filed readings under the bare vendor key.
        try await store.record(
            [snapshot(id: VendorIdentifier.opencode.rawValue, displayName: "OpenCode",
                      fraction: 0.3, at: now)],
            now: now)

        // Reopening the same file runs the additive data migration.
        let reopened = QuotaHistoryStore(databaseURL: dbURL, isTestHost: true)
        let migrated = try await reopened.fetchReadings(instanceID: legacyKey)
        #expect(migrated.count == 1)
        #expect(migrated.first?.vendor == legacyKey)
        #expect(migrated.first?.fraction == 0.3)

        // A vendor-scoped query still sees it.
        let byVendor = try await reopened.fetchReadings(vendor: .opencode)
        #expect(byVendor.contains { $0.vendor == legacyKey })
    }

    @Test("two workspaces record separate series under one vendor")
    func workspacesRecordSeparateSeries() async throws {
        let (store, _) = makeIsolatedStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = OpenCodeGoWorkspace(id: "alpha", name: "Alpha")
        let b = OpenCodeGoWorkspace(id: "beta", name: "Beta")

        try await store.record([snapshot(id: a.instanceID, displayName: "Alpha", fraction: 0.2, at: now)], now: now)
        try await store.record([snapshot(id: b.instanceID, displayName: "Beta", fraction: 0.7, at: now)], now: now)

        let aRows = try await store.fetchReadings(instanceID: a.instanceID)
        let bRows = try await store.fetchReadings(instanceID: b.instanceID)
        #expect(aRows.count == 1)
        #expect(aRows.first?.fraction == 0.2)
        #expect(bRows.count == 1)
        #expect(bRows.first?.fraction == 0.7)

        // One vendor-scoped query sees both, including a workspace that is not
        // in the current preference list (the prefix match, not a stored-key list).
        let byVendor = try await store.fetchReadings(vendor: .opencode)
        #expect(Set(byVendor.map(\.vendor)) == [a.instanceID, b.instanceID])
    }

    @Test("a same-instant reading for two workspaces does not collide")
    func sameInstantTwoWorkspacesDoNotCollide() async throws {
        let (store, _) = makeIsolatedStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = OpenCodeGoWorkspace(id: "alpha", name: "Alpha")
        let b = OpenCodeGoWorkspace(id: "beta", name: "Beta")

        // Identical timestamp and bar label: only the instance key keeps these
        // apart on the (vendor, bar_label, measured_at) primary key.
        try await store.record([
            snapshot(id: a.instanceID, displayName: "Alpha", fraction: 0.15, at: now),
            snapshot(id: b.instanceID, displayName: "Beta", fraction: 0.85, at: now),
        ], now: now)

        let rows = try await store.fetchReadings(vendor: .opencode)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.fraction)) == [0.15, 0.85])
    }
}
