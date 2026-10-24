import AppKit
import Testing
import WebKit
@testable import QuotaBarCore

@Suite("Muse portal WebContent recovery")
@MainActor
struct MusePortalRecoveryTests {
    @Test("termination invalidates a committed portal and the next read reloads before evaluating")
    func terminatedPortalReloadsBeforeNextRead() async throws {
        let suite = "MusePortalRecoveryTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let view = RecoveryWebView()
        let website = MusePortalWebKit(makeWebView: { view })
        defer { website.stop() }
        let session = MusePortalSession(preferences: preferences, website: website)
        session.connect()
        session.selectedTeamID = "42"
        #expect(view.loads == 1)
        view.commitPortal()
        #expect(website.isAtPortal)

        // Deliver the platform callback to the production navigation delegate.
        // Leave view.url at the old portal, exactly as a dead process can do.
        view.navigationDelegate?.webViewWebContentProcessDidTerminate?(view)
        #expect(!website.isAtPortal)
        #expect(session.isEnabled && session.selectedTeamID == "42")
        #expect(preferences.bool(forKey: MusePortalSession.enabledKey))
        #expect(preferences.string(forKey: MusePortalSession.teamKey) == "42")

        let read = Task { await session.read(email: "person@example.com", plan: "Muse Code Power Usage",
                                            now: Date(timeIntervalSince1970: 1_800_000_000)) }
        // Bounded yields let the read register its waiter without a wall-clock assertion.
        for _ in 0..<100 where view.loads < 2 { await Task.yield() }
        #expect(view.loads == 2)
        #expect(view.evaluations == 0)
        #expect(!website.isAtPortal)
        view.commitPortal()
        guard case .usage = await read.value else { Issue.record("Fresh commit did not resume the read"); return }
        #expect(view.evaluations == 1)
        #expect(view.requests.map(\.absoluteString) == ["https://dev.meta.ai/", "https://dev.meta.ai/"])
    }

    @Test("termination releases its waiter without clearing a reentrant newer waiter or accepting foreign views")
    func terminationWaiterIsolation() throws {
        let view = RecoveryWebView()
        let foreign = RecoveryWebView()
        let website = MusePortalWebKit(makeWebView: { view })
        defer { website.stop() }
        website.open()
        view.commitPortal()
        (website as any WKNavigationDelegate).webViewWebContentProcessDidTerminate?(foreign)
        #expect(website.isAtPortal)

        website.webView(view, didStartProvisionalNavigation: nil)
        let oldID = UUID(), newerID = UUID()
        var outcomes: [Bool] = []
        weak var retained: ClaudeMonthlyCreditEvaluation?
        do {
            let evaluation = ClaudeMonthlyCreditEvaluation()
            retained = evaluation
            website.waitUntilPortal(id: oldID) { success in
                evaluation.finish(nil)
                outcomes.append(success)
                website.waitUntilPortal(id: newerID) { outcomes.append($0) }
            }
        }
        (website as any WKNavigationDelegate).webViewWebContentProcessDidTerminate?(foreign)
        #expect(retained != nil && outcomes.isEmpty)
        view.navigationDelegate?.webViewWebContentProcessDidTerminate?(view)
        #expect(retained == nil)
        #expect(outcomes == [false])
        website.cancelPortalWait(id: oldID)
        // A foreign/stale view's callbacks cannot finish the newer waiter.
        foreign.simulatedURL = URL(string: "https://dev.meta.ai/")
        website.webView(foreign, didCommit: nil)
        #expect(outcomes == [false])
        view.commitPortal()
        #expect(outcomes == [false, true])
        view.navigationDelegate?.webViewWebContentProcessDidTerminate?(view)
        #expect(outcomes == [false, true])
    }
}

/// No load or script reaches WebKit. The real seam still owns origin tracking,
/// navigation callbacks, waiter tokens and the session's read gate.
@MainActor
private final class RecoveryWebView: WKWebView {
    var simulatedURL: URL?
    var requests: [URL] = []
    var loads: Int { requests.count }
    var evaluations = 0
    override var url: URL? { simulatedURL }
    override var isLoading: Bool { false }

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: configuration)
    }
    required init?(coder: NSCoder) { fatalError("Not used by fixtures") }

    override func load(_ request: URLRequest) -> WKNavigation? {
        if let url = request.url { requests.append(url) }
        navigationDelegate?.webView?(self, didStartProvisionalNavigation: nil)
        return nil
    }
    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? { nil }

    func commitPortal() {
        simulatedURL = URL(string: "https://dev.meta.ai/")
        navigationDelegate?.webView?(self, didCommit: nil)
    }

    override func __callAsyncJavaScript(_ functionBody: String, arguments: [String: Any]?,
        inFrame frame: WKFrameInfo?, in contentWorld: WKContentWorld,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)?) {
        evaluations += 1
        completionHandler?(#"{"email":"person@example.com","teams":[{"id":"42","name":"Fixture team"}],"subscription_quota":{"tier":"Muse Code Power Usage","window_weighted_used":200,"window_weighted_limit":1000,"window_resets_at":1800009000,"window_duration_secs":18000}}"#, nil)
    }
}
