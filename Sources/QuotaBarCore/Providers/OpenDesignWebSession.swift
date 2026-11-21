import Foundation
import WebKit

/// An opt-in open-design.ai sign-in owned by WebKit. The two usage GETs run
/// inside the signed-in page, exactly as the dashboard makes them; only the
/// status code and the JSON body cross into Swift, never a cookie or header.
@MainActor
public final class OpenDesignWebSession: NSObject, WKNavigationDelegate {
    public static let shared = OpenDesignWebSession()
    static let enabledKey = "opendesign.webSession.enabled"
    public private(set) var webView: WKWebView!
    private var navigationWaiters: [ClaudeMonthlyCreditEvaluation] = []
    private var pending = false

    public var isEnabled: Bool { CredentialStore.preferences.bool(forKey: Self.enabledKey) }

    private override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
    }

    public func connect() {
        CredentialStore.preferences.set(true, forKey: Self.enabledKey)
        if webView.url == nil { webView.load(URLRequest(url: OpenDesignQuotaProvider.dashboardURL)) }
    }

    public func disconnect() {
        CredentialStore.preferences.set(false, forKey: Self.enabledKey)
        webView.stopLoading()
        // WebKit owns the sign-in. Signing out uses OpenDesign's own flow in
        // the connection sheet; FrugalBar never enumerates its cookies.
    }

    private var isOnOpenDesign: Bool {
        webView.url?.scheme == "https" && webView.url?.host == "open-design.ai" && !webView.isLoading
    }

    /// A relaunched app has no page yet: load the dashboard and give it a few
    /// seconds of the provider's budget before the first GET.
    private func pageReady() async -> Bool {
        if isOnOpenDesign { return true }
        if webView.url == nil || webView.url?.host != "open-design.ai" {
            webView.load(URLRequest(url: OpenDesignQuotaProvider.dashboardURL))
        }
        let waiter = ClaudeMonthlyCreditEvaluation()
        navigationWaiters.append(waiter)
        _ = await waiter.value(waitForTimeout: { try await Task.sleep(for: .seconds(6)) }) { _ in }
        return isOnOpenDesign
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let waiters = navigationWaiters
        navigationWaiters = []
        waiters.forEach { $0.finish("ready") }
    }

    func get(url: String, workspaceID: String?) async -> OpenDesignResult {
        guard !TestHost.isActive, isEnabled, !Task.isCancelled else { return .failure(.notConfigured) }
        guard !pending else { return .failure(.timedOut) }
        pending = true
        defer { pending = false }
        guard await pageReady() else { return .failure(.timedOut) }
        let evaluation = ClaudeMonthlyCreditEvaluation()
        let text = await evaluation.value(waitForTimeout: { try await Task.sleep(for: .seconds(10)) }) { complete in
            var arguments: [String: Any] = ["url": url]
            if let workspaceID { arguments["workspace"] = workspaceID }
            self.webView.callAsyncJavaScript(Self.request, arguments: arguments, in: nil, in: .page) { result in
                let text: String?
                if case .success(let value) = result { text = value as? String } else { text = nil }
                Task { @MainActor in complete(text) }
            }
        }
        guard let text, let data = text.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.timedOut)
        }
        if body["transport"] != nil { return .failure(.offline) }
        guard let status = body["status"] as? Int else { return .failure(.badResponse) }
        let payload = (body["body"] as? String).flatMap { $0.data(using: .utf8) } ?? Data()
        return .response(status: status, data: payload)
    }

    /// Only `amr-api.open-design.ai` workspace URLs are requested; anything else
    /// is refused in the page before a request is made.
    private static let request = #"""
    const u = new URL(url);
    if (u.origin !== 'https://amr-api.open-design.ai' || !u.pathname.startsWith('/api/v1/workspaces/')) {
      return JSON.stringify({status: 0});
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
      const headers = {Accept: 'application/json'};
      if (typeof workspace === 'string') headers['X-Vela-Workspace-Id'] = workspace;
      const r = await fetch(u.href, {credentials: 'include', redirect: 'error', headers, signal: controller.signal});
      const body = r.ok ? await r.text() : '';
      return JSON.stringify({status: r.status, body});
    } catch (_) {
      return JSON.stringify({transport: true});
    } finally { clearTimeout(timer); }
    """#
}
