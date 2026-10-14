import Testing
import Foundation
@testable import QuotaBarCore

/// The user's OpenCode Go workspace order: moving rows, keeping it across a
/// relaunch, and honouring it wherever snapshots are listed.
///
/// The regression this guards: the automatic sort ranked every workspace on
/// its own deadline, so whichever subscription's month turned over first was
/// drawn first and the Preferences arrows appeared to do nothing.
@Suite("OpenCode Go workspace order")
struct OpenCodeGoWorkspaceOrderTests {

    private let alpha = OpenCodeGoWorkspace(id: "alpha", name: "Go Alpha")
    private let beta = OpenCodeGoWorkspace(id: "beta", name: "Go Beta")
    private let gamma = OpenCodeGoWorkspace(id: "gamma", name: "Go Gamma")
    private let now = Date(timeIntervalSince1970: 1_791_848_000)

    // MARK: - Moving

    @Test("an arrow move swaps one place and never changes identity")
    func arrowMove() {
        let list = [alpha, beta, gamma]
        let moved = OpenCodeGoWorkspaceStore.moved(list, id: gamma.id, by: -1)
        #expect(moved.map(\.id) == ["alpha", "gamma", "beta"])
        // Identity is untouched: same ids, instance keys and Keychain labels.
        #expect(Set(moved.map(\.instanceID)) == Set(list.map(\.instanceID)))
        #expect(Set(moved.map(\.credentialLabel)) == Set(list.map(\.credentialLabel)))
        // Past either end, or an unknown id, is a no-op.
        #expect(OpenCodeGoWorkspaceStore.moved(list, id: alpha.id, by: -1) == list)
        #expect(OpenCodeGoWorkspaceStore.moved(list, id: gamma.id, by: 1) == list)
        #expect(OpenCodeGoWorkspaceStore.moved(list, id: "nope", by: 1) == list)
    }

    @Test("a drag lands before the row at the destination, as List.onMove means it")
    func dragMove() {
        let list = [alpha, beta, gamma]
        // Drag the first row to the end.
        #expect(OpenCodeGoWorkspaceStore.moved(list, fromOffsets: [0], toOffset: 3).map(\.id)
                == ["beta", "gamma", "alpha"])
        // Drag the last row to the top.
        #expect(OpenCodeGoWorkspaceStore.moved(list, fromOffsets: [2], toOffset: 0).map(\.id)
                == ["gamma", "alpha", "beta"])
        // Dropping a row onto its own slot changes nothing.
        #expect(OpenCodeGoWorkspaceStore.moved(list, fromOffsets: [1], toOffset: 1) == list)
        #expect(OpenCodeGoWorkspaceStore.moved(list, fromOffsets: [1], toOffset: 2) == list)
        // Two rows dragged together keep their relative order.
        #expect(OpenCodeGoWorkspaceStore.moved(list, fromOffsets: [0, 1], toOffset: 3).map(\.id)
                == ["gamma", "alpha", "beta"])
        // Out-of-range offsets are ignored rather than trapping.
        #expect(OpenCodeGoWorkspaceStore.moved(list, fromOffsets: [7], toOffset: 0) == list)
    }

    // MARK: - Persistence

    @Test("the order survives a relaunch, in a suite of its own")
    func orderRoundTrips() throws {
        let suiteName = "frugalbar.tests.workspace-order.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        OpenCodeGoWorkspaceStore.set([alpha, beta, gamma], in: defaults)
        // Gamma to the top: two clicks of its up arrow.
        for _ in 0..<2 {
            let reordered = OpenCodeGoWorkspaceStore.moved(
                OpenCodeGoWorkspaceStore.all(in: defaults), id: gamma.id, by: -1)
            OpenCodeGoWorkspaceStore.set(reordered, in: defaults)
        }

        // A fresh handle on the same suite is what the next launch reads.
        let relaunched = try #require(UserDefaults(suiteName: suiteName))
        let read = OpenCodeGoWorkspaceStore.resolved(in: relaunched)
        #expect(read.map(\.id) == ["gamma", "alpha", "beta"])
        #expect(read.map(\.name) == ["Go Gamma", "Go Alpha", "Go Beta"])
        #expect(read.map(\.instanceID) == [gamma.instanceID, alpha.instanceID, beta.instanceID])
        #expect(read.map(\.credentialLabel) == [gamma.credentialLabel, alpha.credentialLabel, beta.credentialLabel])
    }

    @Test("a stored key is placed by the user's workspace order")
    func positionOfInstanceKey() {
        let list = [beta, alpha]
        #expect(OpenCodeGoWorkspaceStore.position(ofInstanceKey: beta.instanceID, in: list) == 0)
        #expect(OpenCodeGoWorkspaceStore.position(ofInstanceKey: alpha.instanceID, in: list) == 1)
        #expect(OpenCodeGoWorkspaceStore.position(ofInstanceKey: "claude", in: list) == nil)
    }

    // MARK: - Applied to snapshots

    private func snapshot(
        _ id: String, vendor: VendorIdentifier, used: Double = 0.2, resetsIn days: Double?
    ) -> QuotaSnapshot {
        let reset = days.map { now.addingTimeInterval($0 * 86_400) }
        return QuotaSnapshot(
            id: id, vendorId: vendor, displayName: id, category: .aiSubscriptions,
            metric: .percentage(usedFraction: used, displayDetails: nil),
            status: .measured(.none), resetsAt: reset, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: used, label: "MO", resetsAt: reset,
                                 windowLength: reset == nil ? nil : 30 * 86_400))
    }

    @Test("automatic order keeps workspaces together, in the user's order, whatever their deadlines")
    func automaticKeepsWorkspaceOrder() {
        // The user put beta first. Alpha's month turns over sooner, which used
        // to pull it above beta.
        let snapshots = [
            snapshot(alpha.instanceID, vendor: .opencode, resetsIn: 2),
            snapshot(beta.instanceID, vendor: .opencode, resetsIn: 20),
            snapshot("claude", vendor: .claude, resetsIn: 5),
        ]
        let arranged = QuotaManager.arrange(
            snapshots, preferences: ProviderDisplayPreferences(ordering: .automatic),
            instanceOrder: ["claude", beta.instanceID, alpha.instanceID])

        #expect(arranged.map(\.id) == [beta.instanceID, alpha.instanceID, "claude"])
    }

    @Test("the workspace block is placed by its soonest deadline, and single vendors still sort by theirs")
    func automaticPlacesBlockByBestInstance() {
        let snapshots = [
            snapshot("claude", vendor: .claude, resetsIn: 5),
            snapshot("openai", vendor: .openai, resetsIn: 1),
            snapshot(alpha.instanceID, vendor: .opencode, resetsIn: 3),
            snapshot(beta.instanceID, vendor: .opencode, resetsIn: 9),
            snapshot("deepseek", vendor: .deepseek, resetsIn: nil),
        ]
        let arranged = QuotaManager.arrange(
            snapshots, preferences: ProviderDisplayPreferences(ordering: .automatic),
            instanceOrder: [beta.instanceID, alpha.instanceID])

        // OpenAI (1d), then the workspaces (best is 3d) in the user's order,
        // then Claude (5d), then the vendor with no window.
        #expect(arranged.map(\.id) == ["openai", beta.instanceID, alpha.instanceID, "claude", "deepseek"])
    }

    @Test("a spent workspace stays in its block rather than dropping to the end")
    func spentWorkspaceStaysInBlock() {
        let snapshots = [
            snapshot(alpha.instanceID, vendor: .opencode, used: 1.0, resetsIn: 2),
            snapshot(beta.instanceID, vendor: .opencode, resetsIn: 20),
            snapshot("claude", vendor: .claude, resetsIn: 30),
        ]
        let arranged = QuotaManager.arrange(
            snapshots, preferences: ProviderDisplayPreferences(ordering: .automatic),
            instanceOrder: [alpha.instanceID, beta.instanceID])
        #expect(arranged.map(\.id) == [alpha.instanceID, beta.instanceID, "claude"])
    }

    @Test("custom order is the user's list verbatim, workspaces included")
    func customIsVerbatim() {
        let snapshots = [
            snapshot("claude", vendor: .claude, resetsIn: 1),
            snapshot(alpha.instanceID, vendor: .opencode, resetsIn: 2),
            snapshot(beta.instanceID, vendor: .opencode, resetsIn: 20),
        ]
        var order = ProviderDisplayPreferences.defaultOrder
        order.removeAll { $0 == .opencode }
        order.insert(.opencode, at: 0)
        let arranged = QuotaManager.arrange(
            snapshots, preferences: ProviderDisplayPreferences(ordering: .custom, order: order),
            instanceOrder: [beta.instanceID, alpha.instanceID])
        #expect(arranged.map(\.id) == [beta.instanceID, alpha.instanceID, "claude"])
    }

    @Test("a hidden vendor's workspaces are dropped on read")
    func hiddenDropsWorkspaces() {
        let snapshots = [
            snapshot(alpha.instanceID, vendor: .opencode, resetsIn: 2),
            snapshot("claude", vendor: .claude, resetsIn: 5),
        ]
        let arranged = QuotaManager.arrange(
            snapshots, preferences: ProviderDisplayPreferences(hidden: [.opencode]),
            instanceOrder: [alpha.instanceID])
        #expect(arranged.map(\.id) == ["claude"])
    }

    @Test("through QuotaManager, the build order is the order drawn under the automatic sort")
    func managerHonoursBuildOrder() async {
        let order = [beta, alpha]
        let now = self.now
        let providers: [any QuotaProvider] = order.map { workspace in
            OrderStubProvider(
                workspace: workspace,
                resetsAt: now.addingTimeInterval(workspace.id == "alpha" ? 86_400 : 20 * 86_400))
        }
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120,
                                     perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { providers },
            displayPreferences: { ProviderDisplayPreferences(ordering: .automatic) })

        _ = await manager.forceRefresh()
        #expect(await manager.sortedSnapshots().map(\.id) == [beta.instanceID, alpha.instanceID])
    }
}

private struct OrderStubProvider: QuotaProvider {
    let workspace: OpenCodeGoWorkspace
    let resetsAt: Date
    var vendorId: VendorIdentifier { .opencode }
    var instanceID: String { workspace.instanceID }
    var displayName: String { workspace.name }
    let category: MetricCategory = .aiSubscriptions

    func fetchSnapshot() async throws -> QuotaSnapshot {
        QuotaSnapshot(
            id: instanceID, vendorId: .opencode, displayName: displayName, category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.3, displayDetails: nil),
            status: .measured(.none), resetsAt: resetsAt, lastUpdated: resetsAt, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.3, label: "MO", resetsAt: resetsAt, windowLength: 30 * 86_400))
    }
}
