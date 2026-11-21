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
        // A row already waiting on the old read still gets that read's
        // result, which `performRead` turns into nil once disabled; new rows
        // start afresh.
        sharedRead = CoalescedRead()
        state.reset()
        resetScripts()
    }

    private func resetScripts() {
        let content = webView.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: observerSource,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// The OAuth-row identity of the credit on screen: the account verified to
    /// have published it, paired with the organisation its billing query
    /// names. Read by Settings to say why the credit is drawn under no row.
    public var webIdentities: Set<String>? { isEnabled ? state.webIdentities : nil }

    private var sharedRead = CoalescedRead<ClaudeMonthlyCredit?>()

    /// Every Claude row asks for the credit in the same poll. A row that asks
    /// while a read is in flight waits for that read's result rather than
    /// taking the cached credit, so two rows can never be handed different
    /// observations (one the old account's, one the new) in one poll.
    public func read(now: Date) async -> ClaudeMonthlyCredit? {
        guard !TestHost.isActive, !Task.isCancelled, isEnabled else { return nil }
        return await sharedRead.run { await self.performRead(now: now) }
    }

    private func performRead(now: Date) async -> ClaudeMonthlyCredit? {
        _ = await readCredit(now: now)
        guard !Task.isCancelled else { return nil }
        return lastRead()
    }

    /// The credit from the last read that completed, with its identity, and
    /// without starting a read. A row whose wait for an in-flight read runs
    /// out takes this instead of dropping the line for a poll.
    public func lastRead() -> ClaudeMonthlyCredit? {
        guard !TestHost.isActive, isEnabled else { return nil }
        // Credit and identity are taken from the state at one instant, with
        // no suspension between, so they describe the same read.
        guard var credit = state.credit else { return nil }
        credit.webIdentities = state.webIdentities
        return credit
    }

    private func readCredit(now: Date) async -> ClaudeMonthlyCredit? {
        if let retryNotBefore = state.retryNotBefore, now < retryNotBefore { return state.credit }
        // A credit the page fetched on its own carries no verified account;
        // the next read verifies it rather than waiting out the five minutes.
        if !state.verificationPending, let attemptedAt = state.attemptedAt,
           now.timeIntervalSince(attemptedAt) < 300 { return state.credit }
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

    // One page evaluation reads the signed-in account, then billing, then the
    // account again. The credit is attributed to an account only when both
    // account reads agree, so a sign-in change during the read cannot pass
    // one account's credit off as another's. The account is projected to its
    // UUID (no email, name or cookie). JavaScript aborts its own fetches; the
    // native gate also handles a hung WebKit process.
    private static let refreshQuery = #"""
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    const who = async () => {
      try {
        const r = await fetch('/api/account', {credentials: 'same-origin', signal: controller.signal});
        if (r.status === 401 || r.status === 403) return {signedOut: true};
        if (!r.ok) return null;
        const p = await r.json();
        const a = (p && p.account) || p || {};
        return typeof a.uuid === 'string' ? {uuid: a.uuid} : null;
      } catch (_) { return null; }
    };
    try {
      const before = await who();
      let billing;
      try {
        const r = await fetch(query, {credentials: 'same-origin', signal: controller.signal});
        if (!r.ok) billing = {_retryAfter: r.headers.get('Retry-After') || ''};
        else {
          const p = await r.json();
          billing = {status:p.status,monthly_credit_usd:p.monthly_credit_usd,
            next_grant_at:p.next_grant_at,grant_due:p.grant_due,grants_held_reason:p.grants_held_reason};
        }
      } catch (_) { billing = {_failed: true}; }
      const after = await who();
      return JSON.stringify({before, after, billing});
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
    /// The account verified to have published `credit`: both account reads
    /// around the billing read that produced it named this account.
    private(set) var verifiedAccount: String?
    /// A credit arrived through the page's own fetch, with no account read
    /// around it; the next read verifies it without waiting out the throttle.
    private(set) var verificationPending = false

    /// The identity of the credit on screen: its verified account paired with
    /// the organisation its billing query names. Nil unless both are known.
    var webIdentities: Set<String>? {
        guard credit != nil, let verifiedAccount, let query,
              let org = Self.organization(inQuery: query) else { return nil }
        let identities = ClaudeMonthlyCreditBinding.webIdentities(accountUUID: verifiedAccount, organizationUUIDs: [org])
        return identities.isEmpty ? nil : identities
    }

    static func organization(inQuery query: String) -> String? {
        URLComponents(string: "https://claude.ai" + query)?.queryItems?
            .first { $0.name == "organization_uuid" }?.value
    }

    /// Numbers billing results in the order they were accepted. Survives a
    /// reconnect so a later observation always carries a larger number.
    private(set) var observationCounter = 0

    mutating func reset() {
        let counter = observationCounter
        self = Self()
        observationCounter = counter
    }

    /// Opening an enabled connection is inspection, not reconnection.
    mutating func openConnection(alreadyEnabled: Bool, hasPage: Bool) -> Bool {
        if !alreadyEnabled { reset() }
        return !alreadyEnabled || !hasPage
    }

    /// The page's own billing fetch. Nothing says who was signed in when it
    /// ran, so a credit it replaces is unattributed until verified.
    mutating func observe(text: String, query: String, retryAfter: String?, now: Date) {
        if self.query != query { credit = nil; verifiedAccount = nil }
        self.query = query
        attemptedAt = now
        retryNotBefore = QuotaHTTP.retryAfterDate(secondsHeader: retryAfter, now: now)
        if apply(text: text, now: now) {
            verifiedAccount = nil
            verificationPending = true
        }
    }

    /// FrugalBar's own read: `{before, after, billing}` from `refreshQuery`.
    mutating func completeRead(text: String?, query: String, generation: UUID, now: Date) {
        guard self.generation == generation, self.query == query else { return }
        let envelope = text?.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // A bare billing projection (no envelope) carries no account reads.
        let billing = envelope?["billing"] as? [String: Any] ?? (envelope?["before"] == nil ? envelope : nil)
        let billingText = envelope?["billing"] == nil && envelope?["before"] == nil
            ? text
            : billing.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0, encoding: .utf8) }
        retryNotBefore = QuotaHTTP.retryAfterDate(secondsHeader: billing?["_retryAfter"] as? String, now: now)
        let before = Self.account(envelope?["before"]), after = Self.account(envelope?["after"])
        // Both reads around the billing read named the same account.
        let consistent = before != nil && before == after ? before : nil
        if apply(text: billingText, now: now) {
            verifiedAccount = consistent
        } else if Self.contradicts(verifiedAccount, reads: [envelope?["before"], envelope?["after"]]) {
            // The billing read failed, so the credit on screen is the earlier
            // one, now marked stale. It loses its account only when a read
            // shows someone else, or no one, signed in. A read that simply
            // did not answer (a timeout, a network failure) is no evidence of
            // a change: dropping the attribution then hid the line until a
            // later read happened to succeed.
            verifiedAccount = nil
        }
        verificationPending = false
    }

    /// True when an account read names a different account than `verified`,
    /// or says no one is signed in. An unanswered read contradicts nothing.
    static func contradicts(_ verified: String?, reads: [Any?]) -> Bool {
        guard let verified else { return false }
        return reads.contains { read in
            if let object = read as? [String: Any], object["signedOut"] as? Bool == true { return true }
            guard let uuid = (read as? [String: Any])?["uuid"] as? String else { return false }
            return uuid.lowercased() != verified.lowercased()
        }
    }

    static func account(_ value: Any?) -> String? {
        guard let object = value as? [String: Any], let uuid = object["uuid"] as? String,
              UUID(uuidString: uuid) != nil else { return nil }
        return uuid
    }

    /// Applies a billing projection. True when it replaced the credit
    /// (including with "no entitlement"); false when the read failed and the
    /// previous credit was kept, marked stale.
    @discardableResult
    private mutating func apply(text: String?, now: Date) -> Bool {
        guard let data = text?.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["_retryAfter"] == nil, body["_failed"] == nil else {
            credit?.refreshFailed = true
            return false
        }
        do {
            credit = try ClaudeMonthlyCredit.decode(data, now: now)
            observationCounter += 1
            credit?.observation = observationCounter
            return true
        } catch {
            credit?.refreshFailed = true
            return false
        }
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
