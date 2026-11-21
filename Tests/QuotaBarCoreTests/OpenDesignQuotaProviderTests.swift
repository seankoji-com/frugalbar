import Foundation
import Testing
@testable import QuotaBarCore

/// OpenDesign Go reads the current workspace, then that workspace's
/// coding-plan usage. Fixtures follow the documented contract (token-monitor
/// PR 1366); they are synthetic, not a captured account.
@Suite("OpenDesign quota provider")
struct OpenDesignQuotaProviderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A stub transport that records every request it served.
    final class Stub: OpenDesignTransport, @unchecked Sendable {
        let connected: Bool
        let answers: [String: OpenDesignResult]
        private let lock = NSLock()
        private var _calls: [(url: String, workspace: String?)] = []
        var calls: [(url: String, workspace: String?)] { lock.withLock { _calls } }

        init(connected: Bool = true, answers: [String: OpenDesignResult]) {
            self.connected = connected
            self.answers = answers
        }
        var isConnected: Bool { get async { connected } }
        func get(url: String, workspaceID: String?) async -> OpenDesignResult {
            lock.withLock { _calls.append((url, workspaceID)) }
            return answers[url] ?? .response(status: 404, data: Data())
        }
    }

    private static let current = OpenDesignQuotaProvider.apiBase + "current"
    private static let usage = OpenDesignQuotaProvider.apiBase + "ws-a/billing/coding-plan-usage"

    private func ok(_ json: String) -> OpenDesignResult { .response(status: 200, data: Data(json.utf8)) }

    private func stub(usage: String, workspace: String = #"{"workspaceId":"ws-a","workspaceName":"Studio","personalMembershipTier":"pro"}"#) -> Stub {
        Stub(answers: [Self.current: ok(workspace), Self.usage: ok(usage)])
    }

    private func read(_ stub: Stub) async throws -> QuotaSnapshot {
        try await OpenDesignQuotaProvider(transport: stub).fetchSnapshot(now: now)
    }

    @Test("Windows are chosen by duration; 5H and WK are drawn and measured zero is kept")
    func readsWindows() async throws {
        let s = stub(usage: #"""
        {"workspaceId":"ws-a","eligible":true,"tier":"pro","windows":[
          {"durationSeconds":604800,"usedCredits":"25","limitCredits":"100","resetsAt":"2027-01-17T00:00:00Z"},
          {"durationSeconds":18000,"usedCredits":0,"limitCredits":20}]}
        """#)
        let snapshot = try await read(s)
        #expect(s.calls.map(\.url) == [Self.current, Self.usage])
        #expect(s.calls.map(\.workspace) == [nil, "ws-a"])
        #expect(snapshot.status.confidence == .measured)
        #expect(snapshot.row1?.label == "5H")
        #expect(snapshot.row1?.primaryFraction == 0)
        #expect(snapshot.row2?.label == "WK")
        #expect(snapshot.row2?.primaryFraction == 0.25)
        // No monthly window was published, so none is drawn.
        #expect(snapshot.row3 == nil)
        // A window with no published reset draws no pace marker.
        #expect(snapshot.row1?.expectedPaceFraction == nil)
        #expect(snapshot.planName == "OpenDesign Go · Pro")
    }

    @Test("A published monthly window is drawn as MO")
    func monthlyWindow() async throws {
        let s = stub(usage: #"""
        {"workspaceId":"ws-a","eligible":true,"windows":[
          {"durationSeconds":2592000,"usedCredits":300,"limitCredits":1000,"resetsAt":"2027-02-01T00:00:00Z"}]}
        """#)
        let snapshot = try await read(s)
        #expect(snapshot.row3?.label == "MO")
        #expect(snapshot.row3?.primaryFraction == 0.3)
        #expect(snapshot.row1 == nil && snapshot.row2 == nil)
    }

    @Test("Malformed, ineligible or mismatched usage never renders as health")
    func rejectsBadUsage() async throws {
        let bodies = [
            "null", "{}",
            #"{"workspaceId":"ws-b","eligible":true,"windows":[{"durationSeconds":18000,"usedCredits":1,"limitCredits":2}]}"#,
            #"{"workspaceId":"ws-a","eligible":true,"windows":[]}"#,
            #"{"workspaceId":"ws-a","eligible":true,"windows":[{"durationSeconds":42,"usedCredits":1,"limitCredits":2}]}"#,
            #"{"workspaceId":"ws-a","eligible":true,"windows":[{"durationSeconds":18000,"usedCredits":1,"limitCredits":0}]}"#,
            #"{"workspaceId":"ws-a","eligible":true,"windows":[{"durationSeconds":18000,"usedCredits":"NaN","limitCredits":2}]}"#,
            #"{"workspaceId":"ws-a","eligible":true,"windows":[{"durationSeconds":18000,"usedCredits":-1,"limitCredits":2}]}"#,
            #"{"workspaceId":"ws-a","eligible":true,"windows":[{"durationSeconds":18000,"usedCredits":1,"limitCredits":2},{"durationSeconds":18000,"usedCredits":1,"limitCredits":2}]}"#,
        ]
        for body in bodies {
            let s = stub(usage: body)
            let snapshot = try await read(s)
            #expect(snapshot.status.unavailableReason == .badResponse, "\(body)")
            #expect(snapshot.row1 == nil && snapshot.row2 == nil && snapshot.row3 == nil)
            #expect(s.calls.count == 2)
        }
        let ineligible = try await read(stub(usage: #"{"workspaceId":"ws-a","eligible":false,"windows":[]}"#))
        #expect(ineligible.status.unavailableReason == .unsupported("No OpenDesign Go coding plan on this workspace"))
    }

    @Test("An invalid workspace id is refused before the usage request")
    func invalidWorkspace() async throws {
        for workspace in [#"{"workspaceId":"../x"}"#, #"{"workspaceId":""}"#, #"{"workspaceId":42}"#, "null"] {
            let s = stub(usage: "{}", workspace: workspace)
            let snapshot = try await read(s)
            #expect(snapshot.status.unavailableReason == .badResponse)
            #expect(s.calls.count == 1)
        }
    }

    @Test("HTTP failures at either request map to a reason, never a reading")
    func httpFailures() async throws {
        for (code, reason) in [(401, UnavailableReason.credentialRejected), (403, .credentialRejected),
                               (429, .rateLimited(retryAfter: nil)), (500, .badResponse), (404, .badResponse)] {
            let first = Stub(answers: [Self.current: .response(status: code, data: Data())])
            #expect(try await read(first).status.unavailableReason == reason)
            #expect(first.calls.count == 1)
            let second = Stub(answers: [Self.current: ok(#"{"workspaceId":"ws-a"}"#),
                                        Self.usage: .response(status: code, data: Data())])
            #expect(try await read(second).status.unavailableReason == reason)
            #expect(second.calls.count == 2)
        }
        let offline = Stub(answers: [Self.current: .failure(.offline)])
        #expect(try await read(offline).status.unavailableReason == .offline)
    }

    @Test("Without a connected sign-in nothing is requested")
    func notConnected() async throws {
        let s = Stub(connected: false, answers: [:])
        #expect(try await read(s).status.unavailableReason == .notConfigured)
        #expect(s.calls.isEmpty)
    }
}
