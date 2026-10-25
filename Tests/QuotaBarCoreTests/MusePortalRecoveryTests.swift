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
        #expect(view.loads == 1) // The hidden host must not reload immediately.
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

    @Test("a visible terminated portal reloads once per view and waits for a fresh commit")
    func visibleTerminationRecoveryIsBounded() async throws {
        let view = RecoveryWebView()
        let foreign = RecoveryWebView()
        let website = MusePortalWebKit(makeWebView: { view })
        defer { website.stop() }
        website.open()
        let window = show(view)
        defer { window.close() }
        #expect(window.isVisible)
        website.open() // Merely loading sign-in must not restart navigation.
        #expect(view.loads == 1)
        view.commitPortal()
        website.webViewWebContentProcessDidTerminate(foreign)
        #expect(website.isAtPortal && view.loads == 1)
        view.terminate()
        #expect(!website.isAtPortal && view.loads == 2)
        var outcomes: [Bool] = []
        website.waitUntilPortal(id: UUID()) { outcomes.append($0) }
        var beforeCommit: String?
        website.evaluate(email: "person@example.com", plan: "Muse Code Power Usage", teamID: "42") { beforeCommit = $0 }
        #expect(beforeCommit == nil && view.evaluations == 0 && outcomes.isEmpty)
        // A read while the recovery is loading cannot start another load.
        website.open()
        #expect(view.loads == 2)
        view.commitPortal()
        #expect(outcomes == [true])
        let evaluation = ClaudeMonthlyCreditEvaluation()
        let text = await evaluation.value { complete in
            website.evaluate(email: "person@example.com", plan: "Muse Code Power Usage", teamID: "42", complete: complete)
        }
        #expect(text != nil && view.evaluations == 1)
        for _ in 0..<3 {
            view.terminate()
            #expect(!website.isAtPortal && view.loads == 2)
            // Successful commits do not replenish the automatic recovery budget.
            view.commitPortal()
        }
    }

    @Test("a newly created view gets its own single automatic recovery")
    func replacementViewGetsRecoveryBudget() {
        let first = RecoveryWebView(), second = RecoveryWebView()
        var creations = 0
        let website = MusePortalWebKit(makeWebView: {
            creations += 1
            return creations == 1 ? first : second
        })
        defer { website.stop() }
        for view in [first, second] {
            website.open()
            let window = show(view)
            view.commitPortal()
            view.terminate()
            #expect(view.loads == 2)
            view.terminate()
            #expect(view.loads == 2)
            website.stop()
            window.close()
        }
        #expect(creations == 2)
    }

    @Test("even a visible offscreen host is excluded from automatic recovery")
    func hostWindowDoesNotRecoverAutomatically() throws {
        let view = RecoveryWebView()
        let website = MusePortalWebKit(makeWebView: { view })
        defer { website.stop() }
        website.open()
        view.commitPortal()
        let host = try #require(view.window)
        host.orderFront(nil)
        #expect(host.isVisible)
        view.terminate()
        #expect(!website.isAtPortal && view.loads == 1)
    }

    @Test("termination completion can stop, replace or navigate the view without a second recovery",
          arguments: ["stop", "replace", "navigate"])
    func visibleRecoveryHonoursReentrantCompletion(action: String) throws {
        let view = RecoveryWebView(), replacement = RecoveryWebView()
        var creations = 0
        let website = MusePortalWebKit(makeWebView: {
            creations += 1
            return creations == 1 ? view : replacement
        })
        defer { website.stop() }
        website.open()
        let window = show(view)
        defer { window.close() }
        view.commitPortal()
        website.webView(view, didStartProvisionalNavigation: nil)
        var outcomes: [Bool] = []
        let oldID = UUID(), newerID = UUID()
        website.waitUntilPortal(id: oldID) { success in
            outcomes.append(success)
            if action != "navigate" { website.stop() }
            if action != "stop" {
                website.open()
                website.waitUntilPortal(id: newerID) { outcomes.append($0) }
            }
        }
        view.terminate()
        #expect(outcomes == [false])
        #expect(view.loads == (action == "navigate" ? 2 : 1))
        website.cancelPortalWait(id: oldID)
        if action == "replace" {
            #expect(website.webView === replacement && replacement.loads == 1)
            website.webViewWebContentProcessDidTerminate(view)
            #expect(replacement.loads == 1)
            replacement.commitPortal()
        } else if action == "navigate" {
            view.commitPortal()
        } else {
            #expect(website.webView == nil)
        }
        #expect(outcomes == (action == "stop" ? [false] : [false, true]))
    }

    private func show(_ view: NSView) -> NSWindow {
        view.removeFromSuperview()
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        return window
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
    var simulatedLoading = false
    override var url: URL? { simulatedURL }
    override var isLoading: Bool { simulatedLoading }

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: configuration)
    }
    required init?(coder: NSCoder) { fatalError("Not used by fixtures") }

    override func load(_ request: URLRequest) -> WKNavigation? {
        simulatedLoading = true
        if let url = request.url { requests.append(url) }
        navigationDelegate?.webView?(self, didStartProvisionalNavigation: nil)
        return nil
    }
    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? { nil }

    func commitPortal() {
        simulatedLoading = false
        simulatedURL = URL(string: "https://dev.meta.ai/")
        navigationDelegate?.webView?(self, didCommit: nil)
    }

    func terminate() {
        simulatedLoading = false
        navigationDelegate?.webViewWebContentProcessDidTerminate?(self)
    }

    override func __callAsyncJavaScript(_ functionBody: String, arguments: [String: Any]?,
        inFrame frame: WKFrameInfo?, in contentWorld: WKContentWorld,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)?) {
        evaluations += 1
        completionHandler?(#"{"email":"person@example.com","teams":[{"id":"42","name":"Fixture team"}],"subscription_quota":{"tier":"Muse Code Power Usage","window_weighted_used":200,"window_weighted_limit":1000,"window_resets_at":1800009000,"window_duration_secs":18000}}"#, nil)
    }
}
