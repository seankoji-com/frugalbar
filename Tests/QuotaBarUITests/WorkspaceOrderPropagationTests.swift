import Testing
import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

/// The OpenCode Go workspace order end to end: arranged the way Settings
/// arranges it (an arrow press and a drag, each written through the store),
/// read back the way the next launch reads it, and then followed by every
/// surface that lists workspaces — the Settings list itself, the popover's
/// rows, History's picker and cards, and the desktop widget's tiles — under
/// both the automatic and the custom provider order.
///
/// It uses a randomised suite of its own, never the shared preference file.
@Suite("Workspace order across surfaces")
struct WorkspaceOrderPropagationTests {

    private let alpha = OpenCodeGoWorkspace(id: "alpha", name: "Go Alpha")
    private let beta = OpenCodeGoWorkspace(id: "beta", name: "Go Beta")
    private let gamma = OpenCodeGoWorkspace(id: "gamma", name: "Go Gamma")
    private let now = Date(timeIntervalSince1970: 1_791_848_000)

    private func snapshot(_ id: String, vendor: VendorIdentifier, resetsInDays days: Double) -> QuotaSnapshot {
        let reset = now.addingTimeInterval(days * 86_400)
        return QuotaSnapshot(
            id: id, vendorId: vendor, displayName: id, category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.3, displayDetails: nil),
            status: .measured(.none), resetsAt: reset, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.3, label: "MO", resetsAt: reset, windowLength: 30 * 86_400))
    }

    @Test("an order set in Settings survives a relaunch and is the order every surface draws")
    func orderReachesEverySurface() throws {
        let suiteName = "frugalbar.tests.workspace-propagation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Settings: Gamma's up arrow once, then Alpha dragged to the end.
        OpenCodeGoWorkspaceStore.set([alpha, beta, gamma], in: defaults)
        OpenCodeGoWorkspaceStore.set(
            OpenCodeGoWorkspaceStore.moved(OpenCodeGoWorkspaceStore.all(in: defaults), id: gamma.id, by: -1),
            in: defaults)
        OpenCodeGoWorkspaceStore.set(
            OpenCodeGoWorkspaceStore.moved(OpenCodeGoWorkspaceStore.all(in: defaults), fromOffsets: [0], toOffset: 3),
            in: defaults)

        // The next launch.
        let relaunched = OpenCodeGoWorkspaceStore.resolved(in: try #require(UserDefaults(suiteName: suiteName)))
        let expected = [gamma, beta, alpha].map(\.instanceID)
        #expect(relaunched.map(\.instanceID) == expected, "the Settings list")

        // Providers are built in the resolved order; that build order is the
        // manager's instance order. Alpha's month turns over first, which the
        // old sort let pull it to the top.
        let snapshots = [
            snapshot("claude", vendor: .claude, resetsInDays: 10),
            snapshot(alpha.instanceID, vendor: .opencode, resetsInDays: 1),
            snapshot(beta.instanceID, vendor: .opencode, resetsInDays: 20),
            snapshot(gamma.instanceID, vendor: .opencode, resetsInDays: 25),
        ]
        let instanceOrder = ["claude"] + relaunched.map(\.instanceID)

        for preferences in [
            ProviderDisplayPreferences(ordering: .automatic),
            ProviderDisplayPreferences(ordering: .custom, order: [.opencode, .claude]),
            ProviderDisplayPreferences(ordering: .custom, order: [.claude, .opencode]),
        ] {
            let rows = QuotaManager.arrange(snapshots, preferences: preferences, instanceOrder: instanceOrder)
            let workspaceRows = rows.map(\.id).filter { $0 != "claude" }
            #expect(workspaceRows == expected, "popover rows, \(preferences.ordering)")
            if preferences.ordering == .custom {
                // The user's provider list, verbatim.
                let vendors = rows.map(\.vendorId).reduce(into: [VendorIdentifier]()) { out, v in
                    if out.last != v { out.append(v) }
                }
                #expect(vendors == preferences.order, "custom order is verbatim")
            }

            let tiles = OverviewPresentation.tiles(snapshots: rows, filters: WidgetFilters())
            #expect(tiles.map(\.id).filter { $0 != "claude" } == expected, "widget tiles, \(preferences.ordering)")

            let subjects = HistoryOverviewPresentation.subjects(
                order: preferences.order, hidden: preferences.hidden, workspaces: relaunched)
            #expect(subjects.filter { $0.vendor == .opencode }.map(\.id) == expected, "History picker")
        }

        // Identity never moved with the rows.
        #expect(Set(relaunched.map(\.credentialLabel)) == Set([alpha, beta, gamma].map(\.credentialLabel)))
    }
}
