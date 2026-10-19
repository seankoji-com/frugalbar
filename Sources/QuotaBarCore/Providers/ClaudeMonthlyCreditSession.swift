import Foundation
import WebKit

/// An opt-in Claude web session owned by WebKit. No cookie/token extraction,
/// credential copying, or organisation-link mutation. The billing component
/// selects the active organisation and publishes its own GET query; we observe
/// only that response, then refresh the same query at most every five minutes.
@MainActor
public final class ClaudeMonthlyCreditSession: NSObject, WKScriptMessageHandler {
    public static let shared = ClaudeMonthlyCreditSession()
    private static let preferenceKey = "claude.monthlyCredit.webSessionEnabled"
    public private(set) var webView: WKWebView!
    private var state = ClaudeMonthlyCreditSessionState()
    private var pendingRead: ClaudeMonthlyCreditEvaluation?
    public var connectionGeneration: String? { isEnabled ? state.generation.uuidString : nil }
    public var isEnabled: Bool { CredentialStore.preferences.bool(forKey: Self.preferenceKey) }

    private override init() {
        super.init()
        let content = WKUserContentController()
        // The web page performs its normal authenticated request. Only the
        // monthly entitlement fields cross into Swift, never headers/cookies.
        content.addUserScript(WKUserScript(source: observerSource,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(self, name: "monthlyCredit")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
    }

    public func connect() {
        let connectionWasEnabled = isEnabled
        CredentialStore.preferences.set(true, forKey: Self.preferenceKey)
        let shouldLoad = state.openConnection(alreadyEnabled: connectionWasEnabled, hasPage: webView.url != nil)
        if !connectionWasEnabled { resetScripts() }
        if shouldLoad {
            webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/billing")!))
        }
    }

    public func disconnect() {
        CredentialStore.preferences.set(false, forKey: Self.preferenceKey)
        webView.stopLoading()
        reset()
        // WebKit owns the session data. Signing out in the connection window
        // uses Claude's own logout flow; we never enumerate its cookies.
    }

    private var observerSource: String {
        Self.observer.replacingOccurrences(of: "__SESSION_GENERATION__", with: state.generation.uuidString)
    }

    private func reset() {
        pendingRead?.finish(nil)
        pendingRead = nil
        state.reset()
        resetScripts()
    }

    private func resetScripts() {
        let content = webView.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: observerSource,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    public func read(now: Date) async -> ClaudeMonthlyCredit? {
        guard !TestHost.isActive, !Task.isCancelled, isEnabled else { return nil }
        if let retryNotBefore = state.retryNotBefore, now < retryNotBefore { return state.credit }
        if let attemptedAt = state.attemptedAt, now.timeIntervalSince(attemptedAt) < 300 { return state.credit }
        guard pendingRead == nil else { return state.credit }
        state.attemptedAt = now
        guard let query = state.query else {
            if webView.url == nil {
                webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/billing")!))
            }
            return state.credit
        }
        guard webView.url?.scheme == "https", webView.url?.host == "claude.ai" else {
            state.credit?.refreshFailed = true
            return state.credit
        }
        let generation = state.generation
        let evaluation = ClaudeMonthlyCreditEvaluation()
        pendingRead = evaluation
        defer { if pendingRead === evaluation { pendingRead = nil } }
        let text = await evaluation.value { complete in
            self.webView.callAsyncJavaScript(Self.refreshQuery,
                arguments: ["query": query], in: nil, in: .page) { result in
                    let text: String?
                    if case .success(let value) = result { text = value as? String }
                    else { text = nil }
                    // Only the Sendable projection crosses to the actor, not
                    // WebKit's Result<Any, Error> on older SDK annotations.
                    Task { @MainActor in complete(text) }
                }
        }
        guard !Task.isCancelled, isEnabled else { return nil }
        state.completeRead(text: text, query: query, generation: generation, now: now)
        guard state.generation == generation else { return nil }
        return state.credit
    }

    // Bound both the network request and the native callback wait. JavaScript
    // aborts its own fetch; the native gate also handles a hung WebKit process.
    private static let refreshQuery = #"""
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    try {
      const r = await fetch(query, {credentials: 'same-origin', signal: controller.signal});
      if (!r.ok) return JSON.stringify({_retryAfter:r.headers.get('Retry-After')});
      const p = await r.json();
      return JSON.stringify({status:p.status,monthly_credit_usd:p.monthly_credit_usd,
        next_grant_at:p.next_grant_at,grant_due:p.grant_due,grants_held_reason:p.grants_held_reason});
    } finally { clearTimeout(timer); }
    """#

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard isEnabled, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "claude.ai",
              let body = message.body as? [String: String],
              body["generation"] == state.generation.uuidString,
              let path = body["query"], let url = URL(string: "https://claude.ai" + path),
              url.host == "claude.ai", url.path == "/api/quirky-lollipop/link-state",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "include_candidates" && $0.value == "false" }) == true,
              let text = body["payload"] else { return }
        state.observe(text: text, query: path, retryAfter: body["retryAfter"], now: Date())
    }

    private static let observer = #"""
    (() => {
      const generation = "__SESSION_GENERATION__";
      const original = window.fetch;
      window.fetch = async function(...args) {
        const response = await original.apply(this, args);
        try {
          const u = new URL(response.url);
          if (u.origin === 'https://claude.ai' && u.pathname === '/api/quirky-lollipop/link-state'
              && u.searchParams.get('include_candidates') === 'false') {
            if (response.ok) {
              const p = await response.clone().json();
              const payload = JSON.stringify({status: p.status, monthly_credit_usd: p.monthly_credit_usd,
                next_grant_at: p.next_grant_at, grant_due: p.grant_due, grants_held_reason: p.grants_held_reason});
              window.webkit.messageHandlers.monthlyCredit.postMessage({generation, query: u.pathname + u.search, payload});
            } else {
              window.webkit.messageHandlers.monthlyCredit.postMessage({generation, query: u.pathname + u.search, payload: '{"_failed":true}', retryAfter: response.headers.get('Retry-After') || ''});
            }
          }
        } catch (_) {}
        return response;
      };
    })();
    """#
}

/// The entitlement has its own freshness and connection lifetime. A quota
/// failure cannot make an old billing completion current after reconnection.
struct ClaudeMonthlyCreditSessionState {
    private(set) var generation = UUID()
    var query: String?
    var credit: ClaudeMonthlyCredit?
    var attemptedAt: Date?
    var retryNotBefore: Date?

    mutating func reset() { self = Self() }

    /// Opening an enabled connection is inspection, not reconnection.
    mutating func openConnection(alreadyEnabled: Bool, hasPage: Bool) -> Bool {
        if !alreadyEnabled { reset() }
        return !alreadyEnabled || !hasPage
    }

    mutating func observe(text: String, query: String, retryAfter: String?, now: Date) {
        if self.query != query { credit = nil }
        self.query = query
        attemptedAt = now
        retryNotBefore = QuotaHTTP.retryAfterDate(secondsHeader: retryAfter, now: now)
        apply(text: text, now: now)
    }

    mutating func completeRead(text: String?, query: String, generation: UUID, now: Date) {
        guard self.generation == generation, self.query == query else { return }
        let data = text?.data(using: .utf8)
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        retryNotBefore = QuotaHTTP.retryAfterDate(secondsHeader: body?["_retryAfter"] as? String, now: now)
        apply(text: text, now: now)
    }

    private mutating func apply(text: String?, now: Date) {
        guard let data = text?.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["_retryAfter"] == nil, body["_failed"] == nil else {
            credit?.refreshFailed = true
            return
        }
        do { credit = try ClaudeMonthlyCredit.decode(data, now: now) }
        catch { credit?.refreshFailed = true }
    }
}

/// First completion wins, including cancellation and timeout. WebKit can call
/// back after either; it must never resume a continuation twice or hold the
/// provider in flight forever. Tests inject the timeout without a real clock.
@MainActor
final class ClaudeMonthlyCreditEvaluation {
    private var continuation: CheckedContinuation<String?, Never>?
    private var resolved = false

    func finish(_ text: String?) {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: text)
        continuation = nil
    }

    func value(
        waitForTimeout: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) },
        start: @MainActor @Sendable (@escaping @MainActor @Sendable (String?) -> Void) -> Void
    ) async -> String? {
        await withTaskCancellationHandler {
            guard !Task.isCancelled, !resolved else { return nil }
            let timeout = Task {
                do { try await waitForTimeout(); self.finish(nil) }
                catch { /* A completed read cancels its timer. */ }
            }
            defer { timeout.cancel() }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                start { self.finish($0) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }
}
