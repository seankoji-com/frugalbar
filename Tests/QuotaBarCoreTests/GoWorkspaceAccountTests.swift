import Foundation
import Testing
@testable import QuotaBarCore

@Suite("Go account workspace verification")
struct GoWorkspaceAccountTests {
    private let now = Date(timeIntervalSince1970: 1_798_000_000)

    private struct Request: Equatable {
        let url: String
        let workspace: String?
    }

    private func ok(_ payload: String) -> OpenDesignResult {
        .response(status: 200, data: Data(payload.utf8))
    }

    @Test("One OpenCode Console session lists and checks all five workspaces")
    func listsFiveOpenCodeWorkspaces() async throws {
        // Directory and header contract from CodexBar a26ca57. Meter shape
        // from onWatch cdc38b5. All values and account IDs are synthetic.
        let ids = ["org_a", "wrk_b", "org_c", "org_d", "org_e"]
        let names = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"]
        let directory = zip(ids, names).map { #"{"id":"\#($0.0)","name":"\#($0.1)"}"# }.joined(separator: ",")
        let amounts = [10, 25, 35, 50, 90]
        var calls: [Request] = []
        let result = await GoWorkspaceAccount.openCode.verify(now: now) { url, workspace in
            calls.append(Request(url: url.absoluteString, workspace: workspace))
            guard let workspace else { return ok("[\(directory)]") }
            guard let index = ids.firstIndex(of: workspace) else { return .failure(.badResponse) }
            return ok(#"{"access":{"endsAt":"2026-12-15T09:00:00Z","meters":{"month":{"limitMicroCents":"100","usedMicroCents":"\#(amounts[index])"}}}}"#)
        }

        guard case .workspaces(let readings) = result else {
            Issue.record("Expected a workspace report"); return
        }
        #expect(readings.map(\.workspace.name) == names)
        #expect(calls == [Request(url: "https://opencode.ai/console/api/orgs", workspace: nil)]
                + ids.map { Request(url: "https://opencode.ai/console/api/go/status", workspace: $0) })
        let windows = readings.compactMap { reading -> GoWorkspaceAccount.Window? in
            if case .measured(let windows) = reading.usage { return windows.first }
            return nil
        }
        #expect(windows.map(\.fraction) == [0.1, 0.25, 0.35, 0.5, 0.9])
        #expect(windows.allSatisfy { $0.label == "MO" && $0.resetsAt != nil })
    }

    @Test("OpenDesign checks both workspace URLs and rejects a reply for the other workspace", arguments: [false, true])
    func verifiesOpenDesignIdentity(mismatched: Bool) async {
        // Directory contract from OpenDesign 6a74a15. Usage contract from the
        // existing provider fixtures. These are not live account responses.
        var calls: [Request] = []
        let result = await GoWorkspaceAccount.openDesign.verify(now: now) { url, workspace in
            calls.append(Request(url: url.absoluteString, workspace: workspace))
            if workspace == nil {
                return ok(#"{"items":[{"workspaceId":"ws-a","workspaceName":"Studio"},{"workspaceId":"ws-b","workspaceName":"Team"}]}"#)
            }
            let id = mismatched ? "ws-a" : workspace
            let used = workspace == "ws-a" ? 5 : 7
            return ok(#"{"workspaceId":"\#(id ?? "")","eligible":true,"windows":[{"durationSeconds":18000,"usedCredits":\#(used),"limitCredits":10}]}"#)
        }

        guard case .workspaces(let readings) = result else {
            Issue.record("Expected a workspace report"); return
        }
        #expect(calls == [
            Request(url: "https://amr-api.open-design.ai/api/v1/workspaces", workspace: nil),
            Request(url: "https://amr-api.open-design.ai/api/v1/workspaces/ws-a/billing/coding-plan-usage", workspace: "ws-a"),
            Request(url: "https://amr-api.open-design.ai/api/v1/workspaces/ws-b/billing/coding-plan-usage", workspace: "ws-b"),
        ])
        #expect(readings.first?.usage == .measured([.init(label: "5H", fraction: 0.5, resetsAt: nil, isBlocked: false)]))
        let second: GoWorkspaceAccount.Usage = mismatched ? .failed(.badResponse)
            : .measured([.init(label: "5H", fraction: 0.7, resetsAt: nil, isBlocked: false)])
        #expect(readings.last?.usage == second)
    }

    @Test("Console distinguishes no plan, missing access, and invalid meter limits")
    func rejectsUnusableConsoleUsage() async {
        let directory = #"[{"id":"org_none"},{"id":"org_missing"},{"id":"org_zero"}]"#
        let result = await GoWorkspaceAccount.openCode.verify(now: now) { _, workspace in
            switch workspace {
            case nil: ok(directory)
            case "org_none": ok(#"{"access":null}"#)
            case "org_missing": ok("{}")
            default: ok(#"{"access":{"meters":{"fiveHour":{"limitMicroCents":"0","usedMicroCents":"0"}}}}"#)
            }
        }
        guard case .workspaces(let readings) = result else {
            Issue.record("Expected a workspace report"); return
        }
        #expect(readings.map(\.usage) == [.noPlan, .failed(.badResponse), .failed(.badResponse)])
    }

    @Test("Console keeps complete and explicitly blocked windows when amount fields are omitted")
    func preservesPartialConsoleUsage() async {
        let result = await GoWorkspaceAccount.openCode.verify(now: now) { _, workspace in
            switch workspace {
            case nil: ok(#"[{"id":"org_partial"},{"id":"org_without_meters"}]"#)
            case "org_partial": ok(#"{"access":{"meters":{"fiveHour":{"limitMicroCents":"100"},"week":{"limitMicroCents":"100","usedMicroCents":20},"month":{"status":"rate-limited"}}}}"#)
            default: ok(#"{"access":{}}"#)
            }
        }
        guard case .workspaces(let readings) = result, case .measured(let windows)? = readings.first?.usage else {
            Issue.record("Expected partial usage to preserve published windows"); return
        }
        #expect(windows.map(\.label) == ["WK", "MO"])
        #expect(windows.map(\.fraction) == [0.2, nil])
        #expect(windows.map(\.isBlocked) == [false, true])
        #expect(readings.last?.usage == .failed(.unsupported("OpenCode reported no usage window")))
    }

    @Test("OpenDesign allows same-origin signed-in landing pages and rejects sign-in routes")
    func acceptsOpenDesignDashboardVariants() {
        let service = GoWorkspaceAccount.openDesign
        #expect(service.canReadAccount(from: URL(string: "https://open-design.ai/studio/home")!))
        #expect(service.canReadAccount(from: URL(string: "https://open-design.ai/cloud/dashboard")!))
        #expect(!service.canReadAccount(from: URL(string: "https://open-design.ai/cloud/login")!))
        #expect(!service.canReadAccount(from: URL(string: "https://open-design.ai:8443/studio/home")!))
        #expect(!service.canReadAccount(from: URL(string: "https://example.com/studio/home")!))
    }

    @Test("Malformed or duplicate workspace IDs fail the directory before any usage request")
    func refusesPartialDirectory() async {
        for directory in [
            #"[{"id":"org_a"},{"id":"org_a"}]"#,
            #"[{"id":"org_a"},{"id":"org_/../b"}]"#,
        ] {
            var count = 0
            let result = await GoWorkspaceAccount.openCode.verify(now: now) { _, _ in
                count += 1
                return ok(directory)
            }
            #expect(result == .failed(.badResponse))
            #expect(count == 1)
        }
    }

    @Test("A vendor throttle stops the remaining reads without reporting success")
    func stopsOnThrottle() async {
        var count = 0
        let result = await GoWorkspaceAccount.openCode.verify(now: now) { _, workspace in
            count += 1
            if workspace == nil { return ok(#"[{"id":"org_a"},{"id":"org_b"}]"#) }
            return .response(status: 429, data: Data(), retryAfter: "60")
        }
        guard case .workspaces(let readings) = result else {
            Issue.record("Expected a workspace report"); return
        }
        let failure = GoWorkspaceAccount.Usage.failed(.rateLimited(retryAfter: now.addingTimeInterval(60)))
        #expect(readings.map(\.usage) == [failure, failure])
        #expect(count == 2)
    }

    @Test("Five OpenCode and two matching OpenDesign readings retire the legacy connections together")
    func migratesBothServicesTogether() {
        let requirements = GoWorkspaceAccountSettings.LegacyRequirements(
            openCodeCount: 5, openDesignCount: 2, openDesignIDs: ["design-a", "design-b"])
        var settings = GoWorkspaceAccountSettings()
        let incomplete = settings.connect(.openCode, verification: readings(["org_a", "org_b", "org_c", "org_d"]),
                                          requirements: requirements)
        #expect(!incomplete)
        let openCode = settings.connect(.openCode, verification: readings(["org_a", "org_b", "org_c", "org_d", "org_e"]),
                                        requirements: requirements)
        #expect(openCode)
        #expect(settings.isLinked(.openCode))
        #expect(!settings.usesAccount(.openCode))
        #expect(!settings.usesAccount(.openDesign))
        let wrongAccount = settings.connect(.openDesign, verification: readings(["design-a", "other-account"]),
                                            requirements: requirements)
        #expect(!wrongAccount)
        let openDesign = settings.connect(.openDesign, verification: readings(["design-a", "design-b"]),
                                          requirements: requirements)
        #expect(openDesign)
        #expect(settings.usesAccount(.openCode) && settings.usesAccount(.openDesign))
        #expect(settings.workspaces(for: .openCode).count == 5)
        #expect(settings.workspaces(for: .openDesign).count == 2)
    }

    @Test("Connecting just one service works on a clean setup and disconnect cannot revive old keys")
    func disconnectKeepsLegacyRetired() {
        let requirements = GoWorkspaceAccountSettings.LegacyRequirements(openCodeCount: 0, openDesignCount: 0,
                                                                        openDesignIDs: [])
        var settings = GoWorkspaceAccountSettings()
        let connected = settings.connect(.openCode, verification: readings(["org_a"]), requirements: requirements)
        #expect(connected)
        #expect(settings.usesAccount(.openCode))
        #expect(!settings.usesAccount(.openDesign))
        let workspace = GoWorkspaceAccount.Workspace(id: "org_b", name: "New workspace")
        settings.updateWorkspaces([workspace], for: .openCode)
        #expect(settings.workspaces(for: .openCode) == [workspace])
        #expect(settings.knownWorkspaces(for: .openCode).map(\.id) == ["org_a"])
        settings.remember(workspace, for: .openCode)
        #expect(settings.activeHistoryIDs(for: .openCode) == [GoWorkspaceAccount.openCode.seriesID(for: workspace)])
        settings.markNoPlan(workspace, for: .openCode)
        #expect(settings.activeHistoryIDs(for: .openCode).isEmpty)
        settings.disconnect(.openCode)
        #expect(settings.usesAccount(.openCode))
        #expect(!settings.isLinked(.openCode))
        #expect(settings.workspaces(for: .openCode).isEmpty)
        #expect(settings.knownWorkspaces(for: .openCode).map(\.id) == ["org_a", "org_b"])
    }

    @Test("An older unpinned OpenDesign login needs a matching measured series before cutover")
    func unpinnedOpenDesignMustMatchPriorSeries() {
        let workspace = GoWorkspaceAccount.Workspace(id: "design-a", name: "Studio")
        var requirements = GoWorkspaceAccountSettings.LegacyRequirements(openCodeCount: 0, openDesignCount: 1,
                                                                          openDesignIDs: [])
        requirements.needsOpenDesignPrimaryReading = true
        var settings = GoWorkspaceAccountSettings()
        let unverified = settings.connect(.openDesign, verification: readings(["design-a"]), requirements: requirements)
        #expect(!unverified)
        requirements.needsOpenDesignPrimaryReading = false
        requirements.openDesignPrimarySeries = GoWorkspaceAccount.openDesign.seriesID(for: workspace)
        let mismatch = settings.connect(.openDesign, verification: readings(["design-b"]), requirements: requirements)
        #expect(!mismatch)
        let matched = settings.connect(.openDesign, verification: readings(["design-a"]), requirements: requirements)
        #expect(matched)
        #expect(settings.usesAccount(.openDesign))
    }

    @Test("Explicit replacement recovers an unreadable legacy connection without skipping another service")
    func explicitReplacementRecoversMigration() {
        var requirements = GoWorkspaceAccountSettings.LegacyRequirements(
            openCodeCount: 5, openDesignCount: 1, openDesignIDs: [])
        requirements.needsOpenDesignPrimaryReading = true
        var settings = GoWorkspaceAccountSettings()
        let automatic = settings.connect(.openDesign, verification: readings(["design-a"]), requirements: requirements)
        #expect(!automatic)
        #expect(!settings.isLinked(.openDesign))
        let optedIn = settings.connect(.openDesign, verification: readings(["design-a"]), requirements: requirements,
                                        replaceEarlierConnections: true)
        #expect(optedIn)
        #expect(settings.isLinked(.openDesign))
        #expect(!settings.usesAccount(.openDesign))
        let other = settings.connect(.openCode, verification: readings(["org_a", "org_b", "org_c", "org_d", "org_e"]),
                                       requirements: requirements)
        #expect(other)
        #expect(settings.usesAccount(.openDesign) && settings.usesAccount(.openCode))
    }

    @Test("A verified planless workspace stays in the directory and cannot satisfy migration coverage")
    func retainsPlanlessWorkspaceWithoutCountingIt() {
        let requirements = GoWorkspaceAccountSettings.LegacyRequirements(
            openCodeCount: 0, openDesignCount: 1, openDesignIDs: ["earlier"])
        let earlier = GoWorkspaceAccount.Workspace(id: "earlier", name: "Previous workspace")
        let current = GoWorkspaceAccount.Workspace(id: "current", name: "Current workspace")
        let result = GoWorkspaceAccount.Verification.workspaces([
            .init(workspace: earlier, usage: .noPlan),
            .init(workspace: current, usage: .measured([.init(label: "5H", fraction: 0.2, resetsAt: nil, isBlocked: false)])),
        ])
        var settings = GoWorkspaceAccountSettings()
        let automatic = settings.connect(.openDesign, verification: result, requirements: requirements)
        #expect(!automatic)
        #expect(!settings.isLinked(.openDesign))
        let explicit = settings.connect(.openDesign, verification: result, requirements: requirements,
                                         replaceEarlierConnections: true)
        #expect(explicit)
        #expect(settings.workspaces(for: .openDesign) == [earlier, current])
        #expect(settings.workspacesWithPlan(for: .openDesign) == [current])
        #expect(settings.knownWorkspaces(for: .openDesign) == [current])
    }

    @Test("An omitted workspace keeps its no-plan status until a new reading", arguments: [true, false])
    func retainsNoPlanWhenWorkspaceReappears(omittedDuringVerification: Bool) {
        let service = GoWorkspaceAccount.openCode
        let requirements = GoWorkspaceAccountSettings.LegacyRequirements(
            openCodeCount: 0, openDesignCount: 0, openDesignIDs: [])
        let paid = GoWorkspaceAccount.Workspace(id: "org_paid", name: "Paid")
        let free = GoWorkspaceAccount.Workspace(id: "org_free", name: "Free")
        let usage = GoWorkspaceAccount.Usage.measured([
            .init(label: "5H", fraction: 0.2, resetsAt: nil, isBlocked: false),
        ])
        let paidReading = GoWorkspaceAccount.Reading(workspace: paid, usage: usage)
        var settings = GoWorkspaceAccountSettings()
        let connected = settings.connect(service, verification: .workspaces([
            paidReading, .init(workspace: free, usage: .noPlan),
        ]), requirements: requirements)
        #expect(connected)
        if omittedDuringVerification {
            let verified = settings.connect(service, verification: .workspaces([paidReading]), requirements: requirements)
            #expect(verified)
        } else {
            settings.updateWorkspaces([paid], for: service)
        }
        #expect(settings.workspaces(for: service) == [paid])

        settings.updateWorkspaces([paid, free], for: service)
        #expect(settings.workspacesWithPlan(for: service) == [paid])
        #expect(settings.activeHistoryIDs(for: service) == [service.seriesID(for: paid)])

        settings.remember(free, for: service)
        #expect(settings.workspacesWithPlan(for: service) == [paid, free])
        #expect(settings.activeHistoryIDs(for: service) == [service.seriesID(for: paid), service.seriesID(for: free)])
    }

    @Test("Polling replaces legacy rows at cutover and drops the account rows on disconnect")
    func pollingUsesOnlyOneSource() async {
        let discovery = DiscoveredSource()
        let manager = QuotaManager(
            cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, minPollInterval: 0),
            providerFactory: { [FixtureProvider(instanceID: "opencode-go:legacy")] },
            goAccountDiscovery: { _, _, _ in await discovery.providers() })
        let before = await manager.forceRefresh()
        #expect(Set(before.keys) == ["opencode-go:legacy"])

        await discovery.setWorkspaces([
            FixtureProvider(instanceID: "opencode-go:account"),
            FixtureProvider(instanceID: "opencode-go:free", reason: GoWorkspaceAccountQuotaProvider.noPlan),
        ])
        let linked = await manager.forceRefresh()
        #expect(Set(linked.keys) == ["opencode-go:account"])

        await discovery.setWorkspaces([])
        let disconnected = await manager.forceRefresh()
        #expect(disconnected.isEmpty)
    }

    private actor DiscoveredSource {
        private var workspaces: [FixtureProvider]?
        func setWorkspaces(_ workspaces: [FixtureProvider]) { self.workspaces = workspaces }
        func providers() -> [VendorIdentifier: [any QuotaProvider]] {
            workspaces.map { [.opencode: $0] } ?? [:]
        }
    }

    private struct FixtureProvider: QuotaProvider {
        let instanceID: String
        var reason: UnavailableReason = .badResponse
        let vendorId: VendorIdentifier = .opencode
        let displayName = "Workspace"
        let category: MetricCategory = .aiSubscriptions
        func fetchSnapshot() async throws -> QuotaSnapshot { unavailable(reason) }
    }

    private func readings(_ ids: [String]) -> GoWorkspaceAccount.Verification {
        .workspaces(ids.map { id in
            .init(workspace: .init(id: id, name: id),
                  usage: .measured([.init(label: "5H", fraction: 0.3, resetsAt: nil, isBlocked: false)]))
        })
    }
}
