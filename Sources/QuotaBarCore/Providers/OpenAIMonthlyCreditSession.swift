import Foundation
import WebKit

/// What one billing-session pass produced. `didRead` separates a valid reading
/// that found no current grant (clear the row) from a pass that never observed
/// the page (keep the last known grant).
public struct OpenAIMonthlyCreditRead: Sendable, Equatable {
    public let credit: OpenAIMonthlyCredit?
    public let didRead: Bool

    public init(credit: OpenAIMonthlyCredit?, didRead: Bool) {
        self.credit = credit
        self.didRead = didRead
    }
}

/// An opt-in signed-in view of the OpenAI Platform billing page. The page
/// chooses the active organization and makes its own credit-grants request;
/// this session observes only that JSON response, then reloads the page at
/// most every five minutes. It never reads headers, cookies or a session
/// token, and it never writes anything to the account.
@MainActor
public final class OpenAIMonthlyCreditSession: NSObject, WKScriptMessageHandler {
    public static let shared = OpenAIMonthlyCreditSession()
    private static let preferenceKey = "openai.monthlyCredit.webSessionEnabled"
    static let billingURL = URL(string:
        "https://platform.openai.com/settings/organization/billing/credit-grants")!
    public private(set) var webView: WKWebView!
    private var state = OpenAIMonthlyCreditSessionState()
    private var pendingRead: ClaudeMonthlyCreditEvaluation?
    private var pendingCompletion: (@MainActor @Sendable (String?) -> Void)?
    public var connectionGeneration: String? { isEnabled ? state.generation.uuidString : nil }
    public var isEnabled: Bool { CredentialStore.preferences.bool(forKey: Self.preferenceKey) }

    private override init() {
        super.init()
        let content = WKUserContentController()
        // The page performs its normal authenticated request. Only the
        // credit-grant figures cross into Swift, never headers or cookies.
        content.addUserScript(WKUserScript(source: observerSource,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(self, name: "openAIMonthlyCredit")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
    }

    public func connect() {
        let connectionWasEnabled = isEnabled
        CredentialStore.preferences.set(true, forKey: Self.preferenceKey)
        let shouldLoad = state.openConnection(alreadyEnabled: connectionWasEnabled,
            hasPage: webView.url != nil)
        if !connectionWasEnabled { resetScripts() }
        if shouldLoad { loadBillingPage() }
    }

    public func disconnect() {
        CredentialStore.preferences.set(false, forKey: Self.preferenceKey)
        webView.stopLoading()
        reset()
        // WebKit owns the session data. Signing out on the Platform page uses
        // OpenAI's own logout flow; we never enumerate its cookies.
    }

    private var observerSource: String {
        Self.observer.replacingOccurrences(of: "__SESSION_GENERATION__", with: state.generation.uuidString)
    }

    private func loadBillingPage() {
        webView.load(URLRequest(url: Self.billingURL))
    }

    private func reset() {
        pendingCompletion?(nil)
        pendingCompletion = nil
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

    public func read(now: Date, expectedPeriodEnd: Date? = nil) async -> OpenAIMonthlyCreditRead {
        guard !TestHost.isActive, !Task.isCancelled, isEnabled else {
            return OpenAIMonthlyCreditRead(credit: nil, didRead: false)
        }
        state.setExpectedPeriodEnd(expectedPeriodEnd)
        // A page observation is a reading with its own time. Reuse it for the
        // same five minutes the platform connection uses, so a 120 s quota
        // loop does not reload a billing page every cycle.
        if let attemptedAt = state.attemptedAt, now.timeIntervalSince(attemptedAt) < 300 {
            return OpenAIMonthlyCreditRead(credit: state.credit, didRead: state.hasObserved)
        }
        guard pendingRead == nil else {
            return OpenAIMonthlyCreditRead(credit: state.credit, didRead: state.hasObserved)
        }
        // The first observation is the page's own request. Never reload over a
        // sign-in the user is still completing; only a page that has already
        // answered once is refreshed on a schedule.
        guard state.hasObserved else {
            if webView.url == nil { loadBillingPage() }
            return OpenAIMonthlyCreditRead(credit: state.credit, didRead: false)
        }
        if webView.url == nil {
            loadBillingPage()
            return OpenAIMonthlyCreditRead(credit: state.credit, didRead: true)
        }
        // Never reload over a sign-in the user is completing on another host.
        guard webView.url?.scheme == "https", webView.url?.host == "platform.openai.com" else {
            state.markRefreshFailed()
            return OpenAIMonthlyCreditRead(credit: state.credit, didRead: true)
        }
        let generation = state.generation
        let evaluation = ClaudeMonthlyCreditEvaluation()
        pendingRead = evaluation
        defer { if pendingRead === evaluation { pendingRead = nil } }
        let payload = await evaluation.value { complete in
            self.pendingCompletion = complete
            self.webView.reload()
        }
        defer { pendingCompletion = nil }
        guard !Task.isCancelled, isEnabled, state.generation == generation else {
            return OpenAIMonthlyCreditRead(credit: nil, didRead: false)
        }
        let didRead = payload != nil || state.hasObserved
        state.completeRead(payload: payload, now: now)
        guard state.generation == generation else {
            return OpenAIMonthlyCreditRead(credit: nil, didRead: false)
        }
        return OpenAIMonthlyCreditRead(credit: state.credit, didRead: didRead)
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard isEnabled, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "platform.openai.com",
              let body = message.body as? [String: String],
              body["generation"] == state.generation.uuidString,
              let payload = body["payload"] else { return }
        state.observe(payload: payload, now: Date())
        pendingCompletion?(payload)
        pendingCompletion = nil
    }

    /// The page's request shape is private and can change. Match the endpoint
    /// by its billing/credit path and project only the published grant
    /// figures, so nothing else from the billing payload is retained.
    private static let observer = #"""
    (() => {
      const generation = "__SESSION_GENERATION__";
      const send = (payload) => {
        try {
          window.webkit.messageHandlers.openAIMonthlyCredit.postMessage({generation, payload});
        } catch (_) {}
      };
      const project = (p) => {
        if (!p || typeof p !== 'object') return null;
        const grants = p.grants && Array.isArray(p.grants.data) ? p.grants.data
          : Array.isArray(p.grants) ? p.grants : [];
        if (p.object !== 'credit_summary' && grants.length === 0) return null;
        const keep = (g) => ({
          grant_amount: g.grant_amount ?? g.amount ?? g.granted_amount,
          used_amount: g.used_amount ?? g.used,
          remaining_amount: g.remaining_amount ?? g.remaining ?? g.available_amount ?? g.available,
          effective_at: g.effective_at ?? g.effective ?? g.starts_at ?? g.start_at,
          expires_at: g.expires_at ?? g.expires ?? g.expiration ?? g.end_at,
          grant_type: g.grant_type, source: g.source, description: g.description,
          name: g.name, type: g.type
        });
        return JSON.stringify({grants: (grants || []).map(keep)});
      };
      const looksLikeCredit = (url) => /credit/i.test(url) && /billing|grant/i.test(url);
      const originalFetch = window.fetch;
      window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        try {
          const url = response.url || (args[0] && args[0].url) || String(args[0] || '');
          if (looksLikeCredit(url)) {
            const type = response.headers.get('content-type') || '';
            if (type.includes('json')) {
              const payload = project(await response.clone().json());
              if (payload) send(payload);
            }
          }
        } catch (_) {}
        return response;
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        this.addEventListener('load', () => {
          try {
            const responseURL = this.responseURL || String(url);
            if (!looksLikeCredit(responseURL)) return;
            const type = this.getResponseHeader('content-type') || '';
            if (!type.includes('json')) return;
            const payload = project(JSON.parse(this.responseText));
            if (payload) send(payload);
          } catch (_) {}
        });
        return open.call(this, method, url, ...rest);
      };
    })();
    """#
}

/// The credit-grant read has its own freshness and connection lifetime. A
/// quota failure cannot make an old grant current after reconnection.
struct OpenAIMonthlyCreditSessionState {
    private(set) var generation = UUID()
    var credit: OpenAIMonthlyCredit?
    var attemptedAt: Date?
    var hasObserved = false
    var expectedPeriodEnd: Date?
    var lastPayload: String?

    mutating func reset() { self = Self() }

    /// Opening an enabled connection is inspection, not reconnection.
    mutating func openConnection(alreadyEnabled: Bool, hasPage: Bool) -> Bool {
        if !alreadyEnabled { reset() }
        return !alreadyEnabled || !hasPage
    }

    mutating func markRefreshFailed() {
        credit?.refreshFailed = true
    }

    /// The subscription cycle end arrives shortly after the page's first
    /// observation. Re-decode the last payload when it changes so a grant seen
    /// before the date is not lost until the next reload.
    mutating func setExpectedPeriodEnd(_ value: Date?) {
        // A failed subscription lookup is not evidence that the cycle end
        // changed. Keep the last known date so a transient metadata failure
        // cannot turn an unlabelled, already-measured grant into "no grant".
        guard let value else { return }
        guard expectedPeriodEnd != value else { return }
        expectedPeriodEnd = value
        if let lastPayload { apply(payload: lastPayload, now: Date()) }
    }

    mutating func observe(payload: String, now: Date) {
        hasObserved = true
        attemptedAt = now
        lastPayload = payload
        apply(payload: payload, now: now)
    }

    mutating func completeRead(payload: String?, now: Date) {
        attemptedAt = now
        guard let payload else {
            markRefreshFailed()
            return
        }
        lastPayload = payload
        apply(payload: payload, now: now)
    }

    private mutating func apply(payload: String, now: Date) {
        guard let data = payload.data(using: .utf8) else {
            markRefreshFailed()
            return
        }
        do {
            // A valid summary with no current monthly grant means the grant is
            // gone or expired: clear the row rather than keep a figure the
            // vendor no longer publishes.
            credit = try OpenAIMonthlyCredit.decode(data, now: now,
                expectedPeriodEnd: expectedPeriodEnd)
        } catch {
            markRefreshFailed()
        }
    }
}
