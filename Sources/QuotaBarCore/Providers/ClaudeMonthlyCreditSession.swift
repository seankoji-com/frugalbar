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
    private var query: String?
    private var credit: ClaudeMonthlyCredit?
    private var attemptedAt: Date?
    private var isReading = false
    private var retryNotBefore: Date?
    public var isEnabled: Bool { CredentialStore.preferences.bool(forKey: Self.preferenceKey) }

    private override init() {
        super.init()
        let content = WKUserContentController()
        // The web page performs its normal authenticated request. Only the
        // monthly entitlement fields cross into Swift, never headers/cookies.
        content.addUserScript(WKUserScript(source: Self.observer,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(self, name: "monthlyCredit")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
    }

    public func connect() {
        CredentialStore.preferences.set(true, forKey: Self.preferenceKey)
        query = nil
        credit = nil
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/billing")!))
    }

    public func disconnect() {
        CredentialStore.preferences.set(false, forKey: Self.preferenceKey)
        webView.stopLoading()
        query = nil
        credit = nil
        attemptedAt = nil
        retryNotBefore = nil
        // WebKit owns the session data. Signing out in the connection window
        // uses Claude's own logout flow; we never enumerate its cookies.
    }

    public func read(now: Date) async -> ClaudeMonthlyCredit? {
        guard !TestHost.isActive, isEnabled else { return nil }
        if let retryNotBefore, now < retryNotBefore { return nil }
        if let attemptedAt, now.timeIntervalSince(attemptedAt) < 300 { return credit }
        guard !isReading else { return credit }
        attemptedAt = now
        guard let query else {
            if webView.url == nil {
                webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/billing")!))
            }
            return credit
        }
        guard webView.url?.scheme == "https", webView.url?.host == "claude.ai" else {
            credit = nil
            return nil
        }
        isReading = true
        defer { isReading = false }
        let text: String? = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(
                "const r = await fetch(query, {credentials: 'same-origin'}); if (!r.ok) return JSON.stringify({_retryAfter:r.headers.get('Retry-After')}); const p = await r.json(); return JSON.stringify({status:p.status,monthly_credit_usd:p.monthly_credit_usd,next_grant_at:p.next_grant_at,grant_due:p.grant_due,grants_held_reason:p.grants_held_reason});",
                arguments: ["query": query], in: nil, in: .page) { result in
                    if case .success(let value) = result { continuation.resume(returning: value as? String) }
                    else { continuation.resume(returning: nil) }
                }
        }
        guard isEnabled, self.query == query else { return nil }
        if let text, let data = text.data(using: .utf8) {
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                retryNotBefore = QuotaHTTP.retryAfterDate(secondsHeader: body["_retryAfter"] as? String, now: now)
            }
            credit = try? ClaudeMonthlyCredit.decode(data, now: now)
        } else { credit = nil }
        return credit
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard isEnabled, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "claude.ai",
              let body = message.body as? [String: String],
              let path = body["query"], let url = URL(string: "https://claude.ai" + path),
              url.host == "claude.ai", url.path == "/api/quirky-lollipop/link-state",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "include_candidates" && $0.value == "false" }) == true,
              let text = body["payload"], let data = text.data(using: .utf8) else { return }
        query = path
        let now = Date()
        attemptedAt = now
        retryNotBefore = QuotaHTTP.retryAfterDate(secondsHeader: body["retryAfter"], now: now)
        credit = try? ClaudeMonthlyCredit.decode(data, now: now)
    }

    private static let observer = #"""
    (() => {
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
              window.webkit.messageHandlers.monthlyCredit.postMessage({query: u.pathname + u.search, payload});
            } else {
              window.webkit.messageHandlers.monthlyCredit.postMessage({query: u.pathname + u.search, payload: '{}', retryAfter: response.headers.get('Retry-After') || ''});
            }
          }
        } catch (_) {}
        return response;
      };
    })();
    """#
}
