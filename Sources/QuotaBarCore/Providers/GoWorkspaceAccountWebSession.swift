import Foundation
import WebKit

/// A read-only account check using a WebKit profile separate from the profiles
/// that currently supply quota. Cookies and authorization stay in WebKit.
@MainActor
public final class GoWorkspaceAccountWebSession: NSObject, WKNavigationDelegate {
    private static let openCode = GoWorkspaceAccountWebSession(
        .openCode, profile: UUID(uuidString: "DFA35702-D934-4379-B622-59A880942662")!)
    private static let openDesign = GoWorkspaceAccountWebSession(
        .openDesign, profile: UUID(uuidString: "A2DA91BA-466E-4B54-B210-2BCACF622106")!)

    public static func session(for service: GoWorkspaceAccount) -> GoWorkspaceAccountWebSession {
        service == .openCode ? openCode : openDesign
    }

    public let webView: WKWebView
    private let service: GoWorkspaceAccount
    private var verificationInProgress = false
    private var navigation = UUID()
    private var pageWaiters: [ClaudeMonthlyCreditEvaluation] = []
    private var directoryCheckedAt: Date?
    private var directoryFailure: UnavailableReason?

    private init(_ service: GoWorkspaceAccount, profile: UUID) {
        self.service = service
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    public func open() {
        guard !TestHost.isActive, webView.url == nil, !webView.isLoading else { return }
        webView.load(URLRequest(url: service.dashboard))
    }

    public func resetConnection() {
        navigation = UUID()
        directoryCheckedAt = nil
        directoryFailure = nil
    }

    public func verify() async -> GoWorkspaceAccount.Verification {
        guard !TestHost.isActive, isAtDashboard, !Task.isCancelled else { return .failed(.notConfigured) }
        guard !verificationInProgress else { return .failed(.timedOut) }
        verificationInProgress = true
        defer { verificationInProgress = false }
        let generation = navigation
        let result = await service.verify(now: Date()) { url, workspace in
            await self.get(url, workspace: workspace, generation: generation)
        }
        return generation == navigation ? result : .failed(.notConfigured)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.navigation = UUID()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { releaseWaiters() }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { releaseWaiters() }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) { releaseWaiters() }

    private func releaseWaiters() {
        let waiters = pageWaiters
        pageWaiters.removeAll()
        waiters.forEach { $0.finish(nil) }
    }

    private func prepareDashboard() async -> Bool {
        if isAtDashboard { return true }
        open()
        guard webView.isLoading else { return isAtDashboard }
        let waiter = ClaudeMonthlyCreditEvaluation()
        pageWaiters.append(waiter)
        _ = await waiter.value(waitForTimeout: { try await Task.sleep(for: .seconds(4)) }) { _ in }
        pageWaiters.removeAll { $0 === waiter }
        return isAtDashboard && !Task.isCancelled
    }

    static func discoveredProviders(hidden: Set<VendorIdentifier>, force: Bool)
        async -> [VendorIdentifier: [any QuotaProvider]] {
        let settings = GoWorkspaceAccountSettings.load()
        let services = GoWorkspaceAccount.allCases.filter { settings.usesAccount($0) && !hidden.contains($0.vendor) }
        return await withTaskGroup(of: (VendorIdentifier, [any QuotaProvider]).self) { group in
            for service in services {
                group.addTask { (service.vendor, await session(for: service).providers(force: force)) }
            }
            var providers: [VendorIdentifier: [any QuotaProvider]] = [:]
            for await (vendor, workspaces) in group { providers[vendor] = workspaces }
            return providers
        }
    }

    private func providers(force: Bool) async -> [any QuotaProvider] {
        guard !TestHost.isActive, GoWorkspaceAccountSettings.load().isLinked(service) else { return [] }
        let now = Date()
        let vendorBackoff: Bool = if case .rateLimited(let retryAfter)? = directoryFailure {
            !force && (retryAfter.map { $0 > now } ?? false)
        } else { false }
        if !vendorBackoff, directoryCheckedAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            if await prepareDashboard() {
                let captured = navigation
                let response = await get(service.directoryURL, workspace: nil, generation: captured)
                var current = GoWorkspaceAccountSettings.load()
                guard current.isLinked(service) else { return [] }
                guard !Task.isCancelled, captured == navigation else {
                    return quotaProviders(from: current, failure: .notConfigured)
                }
                switch service.directory(from: response, now: now) {
                case .workspaces(let workspaces):
                    directoryFailure = nil
                    if workspaces != current.workspaces(for: service) {
                        current.updateWorkspaces(workspaces, for: service)
                        current.save()
                    }
                case .failed(let reason): directoryFailure = reason
                }
            } else {
                directoryFailure = .notConfigured
            }
            directoryCheckedAt = now
        }
        return quotaProviders(from: GoWorkspaceAccountSettings.load(), failure: directoryFailure)
    }

    private func quotaProviders(from settings: GoWorkspaceAccountSettings, failure: UnavailableReason?) -> [any QuotaProvider] {
        settings.workspaces(for: service).map { workspace in
            GoWorkspaceAccountQuotaProvider(service: service, workspace: workspace, navigation: navigation,
                                            directoryFailure: failure)
        }
    }

    func readWorkspace(_ workspace: GoWorkspaceAccount.Workspace, generation: UUID) async -> OpenDesignResult {
        guard GoWorkspaceAccountSettings.load().isLinked(service) else { return .failure(.notConfigured) }
        return await get(service.usageURL(for: workspace), workspace: workspace.id, generation: generation)
    }

    private var isAtDashboard: Bool {
        !webView.isLoading && webView.url?.scheme == "https" && webView.url?.host == service.dashboard.host
    }

    private func get(_ url: URL, workspace: String?, generation: UUID) async -> OpenDesignResult {
        guard generation == navigation, isAtDashboard, !Task.isCancelled,
              let dashboardHost = service.dashboard.host, let apiHost = service.directoryURL.host else {
            return .failure(.notConfigured)
        }
        var arguments: [String: Any] = [
            "url": url.absoluteString,
            "pageOrigin": "https://" + dashboardHost,
            "apiOrigin": "https://" + apiHost,
            "workspaceHeader": service.workspaceHeader,
        ]
        if let workspace { arguments["workspace"] = workspace }
        let evaluation = ClaudeMonthlyCreditEvaluation()
        let text = await evaluation.value(waitForTimeout: { try await Task.sleep(for: .seconds(10)) }) { complete in
            self.webView.callAsyncJavaScript(Self.request, arguments: arguments, in: nil, in: .defaultClient) { result in
                let payload: String?
                if case .success(let value) = result { payload = value as? String } else { payload = nil }
                Task { @MainActor in complete(payload) }
            }
        }
        guard generation == navigation, !Task.isCancelled else { return .failure(.notConfigured) }
        return OpenDesignWebSession.result(fromProjection: text)
    }

    private static let request = #"""
    const target = new URL(url);
    if (location.origin !== pageOrigin || target.origin !== apiOrigin) return JSON.stringify({status: 0});
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
      const headers = {Accept: 'application/json'};
      if (typeof workspace === 'string') headers[workspaceHeader] = workspace;
      const result = await fetch(target, {credentials: 'include', redirect: 'error', cache: 'no-store',
                                          headers, signal: controller.signal});
      return JSON.stringify({status: result.status, body: result.ok ? await result.text() : '',
                             retryAfter: result.headers.get('Retry-After') || ''});
    } catch (_) {
      return JSON.stringify({transport: true});
    } finally { clearTimeout(timer); }
    """#
}
