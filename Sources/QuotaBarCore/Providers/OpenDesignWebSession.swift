import Foundation
import WebKit

/// An opt-in open-design.ai sign-in owned by WebKit. Workspace and usage GETs run
/// inside the signed-in page, exactly as the dashboard makes them; only the
/// status code, `Retry-After` and the JSON body cross into Swift, never a
/// cookie or credential.
@MainActor
public final class OpenDesignWebSession: NSObject, WKNavigationDelegate {
    private static let primary = OpenDesignWebSession(.primary, dataStore: .default())
    // Keep this identifier stable across app launches. The primary continues
    // to use the original default data store and keeps its existing sign-in.
    private static let secondary = OpenDesignWebSession(.secondary, dataStore: WKWebsiteDataStore(
        forIdentifier: UUID(uuidString: "F6219B30-C312-49B6-A2A3-58A29EC0D453")!))

    public static func session(for slot: OpenDesignConnection) -> OpenDesignWebSession {
        slot == .primary ? primary : secondary
    }

    private let slot: OpenDesignConnection
    public private(set) var webView: WKWebView!
    private var navigationWaiters: [ClaudeMonthlyCreditEvaluation] = []
    private var pending = false
    /// Bumped on link and disconnect. A read that started under an older
    /// generation is discarded, so a disconnect cannot be followed by quota
    /// from the request that was already in flight.
    private var generation = UUID()

    private init(_ slot: OpenDesignConnection, dataStore: WKWebsiteDataStore) {
        self.slot = slot
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
    }

    public func open() {
        if webView.url == nil, !webView.isLoading {
            webView.load(URLRequest(url: OpenDesignQuotaProvider.dashboardURL))
        }
    }

    public func linkCurrentWorkspace() async throws(OpenDesignLinkError) -> Set<String> {
        let original = OpenDesignConnections.load()
        let started = generation
        var updated = original
        var invalidated = Set([original.instanceID(for: slot)].compactMap { $0 })
        // The bare ID belongs to the legacy primary or its unconfigured row.
        if slot == .secondary, original.workspace(for: .primary) == nil {
            invalidated.insert(VendorIdentifier.opendesign.rawValue)
        }
        // An upgraded installation may still follow its current primary.
        // Take its authenticated selection before the second link so we can
        // reject duplicates and keep that same primary when both are active.
        if slot == .secondary, original.followsLegacyPrimary {
            let primary = Self.primary
            switch await primary.currentWorkspace(connection: primary.generation) {
            case .selected(let workspace): try updated.link(workspace, to: .primary)
            case .failed(let reason): throw .primarySelectionUnavailable(reason)
            }
        }
        switch await currentWorkspace(connection: started) {
        case .selected(let workspace): try updated.link(workspace, to: slot)
        case .failed(let reason): throw .selectionUnavailable(reason)
        }
        guard !Task.isCancelled, generation == started, OpenDesignConnections.load() == original else {
            throw .connectionChanged
        }
        updated.save(to: CredentialStore.preferences)
        generation = UUID()
        if slot == .secondary, original.followsLegacyPrimary { Self.primary.generation = UUID() }
        return invalidated
    }

    public func disconnect() -> String? {
        var connections = OpenDesignConnections.load()
        let oldID = connections.instanceID(for: slot)
        connections.unlink(slot)
        connections.save(to: CredentialStore.preferences)
        generation = UUID()
        webView.stopLoading()
        releaseWaiters()
        // WebKit owns the sign-in. Signing out uses OpenDesign's own flow in
        // the connection sheet; FrugalBar never enumerates its cookies.
        return oldID
    }

    func pollGeneration(workspaceID: String?) -> UUID? {
        let connections = OpenDesignConnections.load()
        guard connections.isConnected(slot), connections.workspace(for: slot)?.workspaceId == workspaceID else {
            return nil
        }
        return generation
    }

    private func currentWorkspace(connection: UUID) async -> OpenDesignQuotaProvider.WorkspaceSelection {
        let result = await get(url: OpenDesignQuotaProvider.apiBase + "current", workspaceID: nil,
                               connection: connection)
        return OpenDesignQuotaProvider.workspaceSelection(from: result, now: Date())
    }

    private var isOnOpenDesign: Bool {
        webView.url?.scheme == "https" && webView.url?.host == "open-design.ai" && !webView.isLoading
    }

    /// A relaunched app has no page yet: load the dashboard and give it a few
    /// seconds of the provider's budget before the first GET.
    private func pageReady() async -> Bool {
        if isOnOpenDesign { return true }
        if !webView.isLoading, webView.url == nil || webView.url?.host != "open-design.ai" {
            webView.load(URLRequest(url: OpenDesignQuotaProvider.dashboardURL))
        }
        let waiter = ClaudeMonthlyCreditEvaluation()
        navigationWaiters.append(waiter)
        _ = await waiter.value(waitForTimeout: { try await Task.sleep(for: .seconds(6)) }) { _ in }
        // Whatever ended the wait (load, failure, timeout, cancellation),
        // this waiter is done and must not accumulate across polls.
        navigationWaiters.removeAll { $0 === waiter }
        return isOnOpenDesign
    }

    private func releaseWaiters() {
        let waiters = navigationWaiters
        navigationWaiters = []
        waiters.forEach { $0.finish(nil) }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { releaseWaiters() }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        releaseWaiters()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        releaseWaiters()
    }

    func get(url: String, workspaceID: String?, connection: UUID) async -> OpenDesignResult {
        guard !TestHost.isActive, generation == connection, !Task.isCancelled else { return .failure(.notConfigured) }
        guard !pending else { return .failure(.timedOut) }
        pending = true
        defer { pending = false }
        guard await pageReady() else {
            return generation == connection ? .failure(.timedOut) : .failure(.notConfigured)
        }
        guard generation == connection, !Task.isCancelled else { return .failure(.notConfigured) }
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
        // Disconnected (or reconnected) while the request was in flight.
        guard generation == connection, !Task.isCancelled else { return .failure(.notConfigured) }
        return Self.result(fromProjection: text)
    }

    /// Decodes the page's `{status, body, retryAfter}` projection.
    nonisolated static func result(fromProjection text: String?) -> OpenDesignResult {
        guard let text, let data = text.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.timedOut)
        }
        if body["transport"] != nil { return .failure(.offline) }
        guard let status = body["status"] as? Int, status > 0 else { return .failure(.badResponse) }
        let payload = (body["body"] as? String).flatMap { $0.data(using: .utf8) } ?? Data()
        let retryAfter = (body["retryAfter"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .response(status: status, data: payload, retryAfter: retryAfter)
    }

    /// Only `amr-api.open-design.ai` workspace URLs are requested; anything else
    /// is refused in the page before a request is made.
    private static let request = #"""
    const u = new URL(url);
    if (location.origin !== 'https://open-design.ai' ||
        u.origin !== 'https://amr-api.open-design.ai' || !u.pathname.startsWith('/api/v1/workspaces/')) {
      return JSON.stringify({status: 0});
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
      const headers = {Accept: 'application/json'};
      if (typeof workspace === 'string') headers['X-Vela-Workspace-Id'] = workspace;
      const r = await fetch(u.href, {credentials: 'include', redirect: 'error', cache: 'no-store', headers, signal: controller.signal});
      const body = r.ok ? await r.text() : '';
      return JSON.stringify({status: r.status, body, retryAfter: r.headers.get('Retry-After') || ''});
    } catch (_) {
      return JSON.stringify({transport: true});
    } finally { clearTimeout(timer); }
    """#
}
