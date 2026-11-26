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
    private var isManaging = false
    private var navigation = UUID()
    private var pageWaiters: [ClaudeMonthlyCreditEvaluation] = []
    private var directoryCheckedAt: Date?
    private var userCheckedDirectoryAt: Date?
    private var directoryFailure: UnavailableReason?
    private var navigationFailed = false
    private var requestTail: Task<Void, Never>?
    private var backoff: (until: Date, published: Date?)?

    public var verificationGeneration: UUID { navigation }

    private init(_ service: GoWorkspaceAccount, profile: UUID) {
        self.service = service
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    public func beginManaging() {
        isManaging = true
        navigation = UUID()
        releaseWaiters()
        if directoryFailure == .credentialRejected { reloadSignIn() }
        else { open() }
    }

    public func endManaging() { isManaging = false }

    public func reloadSignIn() {
        guard !TestHost.isActive, !verificationInProgress else { return }
        webView.stopLoading()
        navigationFailed = false
        webView.load(URLRequest(url: service.dashboard))
    }

    private func open() {
        guard !TestHost.isActive, !webView.isLoading, !isAtDashboard || navigationFailed else { return }
        navigationFailed = false
        webView.load(URLRequest(url: service.dashboard))
    }

    public func resetConnection() {
        navigation = UUID()
        directoryCheckedAt = nil
        userCheckedDirectoryAt = nil
        directoryFailure = nil
        backoff = nil
        navigationFailed = false
        webView.stopLoading()
        releaseWaiters()
    }

    public func clearSignIn() async {
        // This view's data store is exclusively owned by this account flow.
        _ = webView.loadHTMLString("", baseURL: nil)
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    public func verify() async -> GoWorkspaceAccount.Verification {
        guard !TestHost.isActive, isAtDashboard, !Task.isCancelled else { return .failed(.notConfigured) }
        guard !verificationInProgress else { return .failed(.timedOut) }
        verificationInProgress = true
        defer { verificationInProgress = false }
        backoff = nil
        let generation = navigation
        let result = await service.verify(now: Date()) { url, workspace in
            await self.get(url, workspace: workspace, generation: generation, interactive: true)
        }
        return generation == navigation ? result : .failed(.notConfigured)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.navigation = UUID()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFailed = false
        releaseWaiters()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageFailed(error) }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) { pageFailed(error) }

    private func pageFailed(_ error: Error) {
        let failure = error as NSError
        guard failure.domain != NSURLErrorDomain || failure.code != URLError.cancelled.rawValue else { return }
        navigationFailed = true
        releaseWaiters()
    }

    private func releaseWaiters() {
        let waiters = pageWaiters
        pageWaiters.removeAll()
        waiters.forEach { $0.finish(nil) }
    }

    private func prepareDashboard() async -> Bool {
        if isAtDashboard && !navigationFailed { return true }
        open()
        guard webView.isLoading else { return isAtDashboard }
        let waiter = ClaudeMonthlyCreditEvaluation()
        pageWaiters.append(waiter)
        _ = await waiter.value(waitForTimeout: { try await Task.sleep(for: .seconds(4)) }) { _ in }
        pageWaiters.removeAll { $0 === waiter }
        return isAtDashboard && !navigationFailed && !Task.isCancelled
    }

    static func discoveredProviders(hidden: Set<VendorIdentifier>, force: Bool, timeout: TimeInterval)
        async -> [VendorIdentifier: [any QuotaProvider]] {
        let settings = GoWorkspaceAccountSettings.load()
        let services = GoWorkspaceAccount.allCases.filter { settings.usesAccount($0) && !hidden.contains($0.vendor) }
        return await withTaskGroup(of: (VendorIdentifier, [any QuotaProvider]).self) { group in
            for service in services {
                group.addTask {
                    let session = await session(for: service)
                    let result = await withDeadline(seconds: timeout) {
                        await session.providers(force: force)
                    }
                    switch result {
                    case .success(let providers): return (service.vendor, providers)
                    case .failure(let failure):
                        let settings = GoWorkspaceAccountSettings.load()
                        return (service.vendor, await session.quotaProviders(from: settings, failure: failure))
                    }
                }
            }
            var providers: [VendorIdentifier: [any QuotaProvider]] = [:]
            for await (vendor, workspaces) in group { providers[vendor] = workspaces }
            return providers
        }
    }

    private func providers(force: Bool) async -> [any QuotaProvider] {
        let settings = GoWorkspaceAccountSettings.load()
        guard !TestHost.isActive, settings.isLinked(service) else { return [] }
        guard !isManaging else { return quotaProviders(from: settings, failure: .timedOut) }
        let now = Date()
        let checkedAt = force ? userCheckedDirectoryAt : directoryCheckedAt
        if (force || (backoff.map { $0.until <= now } ?? true)),
           checkedAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            if force { backoff = nil }
            if await prepareDashboard() {
                let captured = navigation
                let response = await get(service.directoryURL, workspace: nil, generation: captured)
                var current = GoWorkspaceAccountSettings.load()
                guard current.isLinked(service) else { return [] }
                guard !Task.isCancelled, captured == navigation else {
                    return quotaProviders(from: current, failure: .notConfigured)
                }
                switch service.directory(from: response, now: now) {
                case .workspaces(let workspaces) where !workspaces.isEmpty:
                    directoryFailure = nil
                    if workspaces != current.workspaces(for: service) {
                        current.updateWorkspaces(workspaces, for: service)
                        current.save()
                    }
                case .workspaces: directoryFailure = .badResponse
                case .failed(let reason): directoryFailure = reason
                }
            } else {
                guard !Task.isCancelled, !isManaging else { return quotaProviders(from: settings, failure: .timedOut) }
                directoryFailure = webView.isLoading ? .timedOut : navigationFailed ? .offline : .credentialRejected
            }
            directoryCheckedAt = now
            if force { userCheckedDirectoryAt = now }
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

    func rememberReading(_ workspace: GoWorkspaceAccount.Workspace, generation: UUID, hasPlan: Bool) {
        var settings = GoWorkspaceAccountSettings.load()
        guard !Task.isCancelled, generation == navigation, settings.isLinked(service) else { return }
        if hasPlan { settings.remember(workspace, for: service) }
        else { settings.markNoPlan(workspace, for: service) }
        settings.save()
    }

    private var isAtDashboard: Bool {
        guard !webView.isLoading, let page = webView.url, page.scheme == "https",
              page.host == service.dashboard.host else { return false }
        let prefix = service == .openCode ? "/console" : "/cloud"
        let signInRoutes = ["auth", "login", "sign-in", "signin", "oauth"]
        return (page.path == prefix || page.path.hasPrefix(prefix + "/"))
            && !page.pathComponents.dropFirst(2).contains(where: signInRoutes.contains)
    }

    private func get(_ url: URL, workspace: String?, generation: UUID, interactive: Bool = false) async -> OpenDesignResult {
        let previous = requestTail
        let request = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, generation == navigation else { return OpenDesignResult.failure(.notConfigured) }
            guard interactive || !isManaging else { return OpenDesignResult.failure(.timedOut) }
            if let backoff, backoff.until > Date() { return .failure(.rateLimited(retryAfter: backoff.published)) }
            let result = await performRequest(url, workspace: workspace, generation: generation)
            if case .response(429, _, let header) = result {
                let now = Date()
                let published = QuotaHTTP.retryAfterDate(secondsHeader: header, now: now)
                backoff = (published ?? now.addingTimeInterval(30), published)
            }
            return result
        }
        requestTail = Task { _ = await request.value }
        return await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
    }

    private func performRequest(_ url: URL, workspace: String?, generation: UUID) async -> OpenDesignResult {
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
        if text == "timeout" { return .failure(.timedOut) }
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
      const result = await fetch(target, {credentials: 'include', redirect: 'manual', cache: 'no-store',
                                          headers, signal: controller.signal});
      if (result.type === 'opaqueredirect') return JSON.stringify({status: 401});
      return JSON.stringify({status: result.status, body: result.ok ? await result.text() : '',
                             retryAfter: result.headers.get('Retry-After') || ''});
    } catch (error) {
      if (error?.name === 'AbortError') return 'timeout';
      return JSON.stringify({transport: true});
    } finally { clearTimeout(timer); }
    """#
}
