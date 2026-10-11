import Testing
import Foundation
@testable import QuotaBarCore

/// Two OpenCode Go workspaces through `QuotaManager`: they must coexist in the
/// cache and in the sorted list, and one workspace's failure or exhaustion must
/// neither overwrite nor hide its sibling's reading.
///
/// The regression this guards: before instance keying, both providers shared
/// the vendor key `opencode`, so the second fetch overwrote the first and a
/// failing workspace erased a healthy one. A test that only asserts "some
/// OpenCode reading exists" would still pass under that bug; every test here
/// counts the two entries separately.
private struct WorkspaceStubProvider: QuotaProvider {
    enum Behavior: Sendable {
        case measured(Urgency, used: Double)
        case blocked
        case throwError(ProviderError)
    }

    let workspace: OpenCodeGoWorkspace
    let behavior: Behavior

    var vendorId: VendorIdentifier { .opencode }
    var instanceID: String { workspace.instanceID }
    var displayName: String { workspace.name }
    let category: MetricCategory = .aiSubscriptions

    func fetchSnapshot() async throws -> QuotaSnapshot {
        switch behavior {
        case .throwError(let error):
            throw error
        case .measured(let urgency, let used):
            return QuotaSnapshot(
                id: instanceID, vendorId: .opencode, displayName: displayName,
                category: .aiSubscriptions,
                metric: .percentage(usedFraction: used, displayDetails: nil),
                status: .measured(urgency), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
                row1: DualBarMetrics(primaryFraction: used, label: "WK", windowLength: QuotaWindow.week)
            )
        case .blocked:
            // A subscription metric with a blocked, fraction-less bar, exactly
            // as the real provider reports a fully rate-limited workspace: no
            // percentage is invented, so `consumptionFraction` stays nil.
            return QuotaSnapshot(
                id: instanceID, vendorId: .opencode, displayName: displayName,
                category: .aiSubscriptions,
                metric: .subscription(tierName: "Go", renewalDate: nil),
                status: .measured(.critical), resetsAt: nil, lastUpdated: Date(), auxiliaryInfo: nil,
                row1: DualBarMetrics(primaryFraction: nil, label: "WK", isBlocked: true,
                                     windowLength: QuotaWindow.week)
            )
        }
    }
}

/// Holds the providers a manager is built from, so a test can remove one
/// between polls without touching the real workspace store.
private final class WorkspaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [WorkspaceStubProvider]
    init(_ value: [WorkspaceStubProvider]) { _value = value }
    var value: [WorkspaceStubProvider] {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

@Suite("OpenCode Go workspaces through QuotaManager")
struct OpenCodeGoWorkspaceQuotaTests {

    private let alpha = OpenCodeGoWorkspace(id: "alpha", name: "Go Alpha")
    private let beta = OpenCodeGoWorkspace(id: "beta", name: "Go Beta")

    private func manager(
        box: WorkspaceBox,
        order: ProviderOrdering = .custom
    ) -> QuotaManager {
        QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120,
                                     perProviderTimeout: 2, minPollInterval: 0),
            providerFactory: { box.value },
            displayPreferences: { ProviderDisplayPreferences(ordering: order) })
    }

    @Test("two workspaces are cached separately, and one failing never hides the other")
    func failureDoesNotOverwriteSibling() async {
        let box = WorkspaceBox([
            WorkspaceStubProvider(workspace: alpha, behavior: .measured(.none, used: 0.2)),
            WorkspaceStubProvider(workspace: beta, behavior: .throwError(.badResponse)),
        ])
        let m = manager(box: box)

        let results = await m.forceRefresh()

        // Two distinct entries — the bug collapsed them onto one key.
        #expect(results.count == 2)
        #expect(results[alpha.instanceID]?.status == .measured(.none))
        #expect(results[alpha.instanceID]?.consumptionFraction == 0.2)
        #expect(results[beta.instanceID]?.status == .unavailable(.badResponse))

        // The healthy reading keeps its own name and fraction; the failure did
        // not overwrite it, and it did not absorb the failure either.
        #expect(results[alpha.instanceID]?.displayName == "Go Alpha")
        #expect(results[beta.instanceID]?.displayName == "Go Beta")
        #expect(results[beta.instanceID]?.consumptionFraction == nil)

        let cached = await m.cachedSnapshots()
        #expect(cached.count == 2)
    }

    @Test("an exhausted workspace does not overwrite or hide its healthy sibling")
    func exhaustedDoesNotHideSibling() async {
        let box = WorkspaceBox([
            WorkspaceStubProvider(workspace: alpha, behavior: .measured(.none, used: 0.1)),
            WorkspaceStubProvider(workspace: beta, behavior: .blocked),
        ])
        let m = manager(box: box)

        let results = await m.forceRefresh()
        #expect(results.count == 2)
        #expect(results[alpha.instanceID]?.status == .measured(.none))
        // Blocked with no percentage: critical, and no invented figure.
        #expect(results[beta.instanceID]?.status == .measured(.critical))
        #expect(results[beta.instanceID]?.consumptionFraction == nil)

        let sorted = await m.sortedSnapshots()
        #expect(sorted.map(\.id).contains(alpha.instanceID))
        #expect(sorted.map(\.id).contains(beta.instanceID))
    }

    @Test("both workspaces appear in the sorted list, in the order they were built")
    func sortedKeepsWorkspaceOrder() async {
        let box = WorkspaceBox([
            WorkspaceStubProvider(workspace: beta, behavior: .measured(.none, used: 0.1)),
            WorkspaceStubProvider(workspace: alpha, behavior: .measured(.none, used: 0.1)),
        ])
        let m = manager(box: box, order: .custom)

        _ = await m.forceRefresh()
        let sorted = await m.sortedSnapshots()

        #expect(sorted.map(\.id) == [beta.instanceID, alpha.instanceID])
        #expect(sorted.map(\.displayName) == ["Go Beta", "Go Alpha"])
    }

    @Test("removing a workspace prunes its cache entry and leaves the other")
    func removedWorkspaceIsPruned() async {
        let box = WorkspaceBox([
            WorkspaceStubProvider(workspace: alpha, behavior: .measured(.none, used: 0.2)),
            WorkspaceStubProvider(workspace: beta, behavior: .measured(.none, used: 0.4)),
        ])
        let m = manager(box: box)

        _ = await m.forceRefresh()
        #expect(await m.cachedSnapshots().count == 2)

        // The user removes (or disables) the beta workspace.
        box.value = [WorkspaceStubProvider(workspace: alpha, behavior: .measured(.none, used: 0.2))]
        _ = await m.forceRefresh()

        let cached = await m.cachedSnapshots()
        #expect(cached[alpha.instanceID] != nil)
        #expect(cached[beta.instanceID] == nil)
    }
}
