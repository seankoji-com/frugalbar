import Foundation
import Combine
import WebKit
import AppKit

/// A separate, opt-in portal login. WebKit retains only this app's session;
/// browser cookies and credential strings never cross into Swift.
@MainActor
public final class MusePortalSession: ObservableObject {
    public static let shared = MusePortalSession(preferences: CredentialStore.preferences,
        website: TestHost.isActive ? nil : MusePortalWebKit())
    static let enabledKey = "muse.portal.enabled"
    static let teamKey = "muse.portal.teamID"
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isDisconnecting = false
    @Published public private(set) var teams: [MusePortalTeam] = []
    @Published public private(set) var message = "Sign in, then refresh the team list."
    // Session ownership lets a read finish after the sheet closes. The token
    // prevents an old read's cleanup from clearing a reconnected session's flag.
    @Published private var teamRefreshID: UUID?
    public var isReadingTeams: Bool { teamRefreshID != nil }
    @Published private var teamID = ""
    public var selectedTeamID: String {
        get { teamID }
        set {
            generation = UUID()
            teamID = isEnabled && MusePortalTeam.validID(newValue) ? newValue : ""
            if !teamID.isEmpty {
                preferences.set(teamID, forKey: Self.teamKey)
            } else {
                preferences.removeObject(forKey: Self.teamKey)
            }
        }
    }
    public var webView: WKWebView? { website?.webView }
    public func hostWebView() { if isEnabled { website?.host() } }
    private let preferences: UserDefaults
    private let website: (any MusePortalWebsite)?
    private var generation = UUID()
    private var pending: ClaudeMonthlyCreditEvaluation?
    private var retryNotBefore: Date?

    init(preferences: UserDefaults, website: (any MusePortalWebsite)?) {
        self.preferences = preferences
        self.website = website
        isEnabled = website != nil && preferences.bool(forKey: Self.enabledKey)
        let team = preferences.string(forKey: Self.teamKey) ?? ""
        teamID = isEnabled && MusePortalTeam.validID(team) ? team : ""
    }

    public func connect() {
        guard !isDisconnecting, let website else { return }
        preferences.set(true, forKey: Self.enabledKey)
        isEnabled = true
        website.open()
        objectWillChange.send()
    }

    public func disconnect() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        preferences.removeObject(forKey: Self.enabledKey)
        isEnabled = false
        generation = UUID()
        pending?.finish(nil)
        pending = nil
        teamRefreshID = nil
        website?.stop()
        teams = []
        selectedTeamID = ""
        retryNotBefore = nil
        message = "Sign in, then refresh the team list."
        await website?.clear()
        isDisconnecting = false
    }

    public func refreshTeams() async {
        guard isEnabled, !isDisconnecting, !isReadingTeams else { return }
        let refreshID = UUID()
        teamRefreshID = refreshID
        defer { if teamRefreshID == refreshID { teamRefreshID = nil } }
        _ = await evaluate(email: "", plan: "", teamID: "", now: Date())
    }

    func read(email: String, plan: String, now: Date) async -> MusePortalRead {
        guard isEnabled else { return .unavailable(MuseQuotaProvider.missingUsageMessage) }
        guard MusePortalTeam.validID(selectedTeamID) else {
            return .unavailable("Muse omitted its usage window. Choose a team in Settings → API Keys → Muse portal quota.")
        }
        let teamID = selectedTeamID
        switch await evaluate(email: email, plan: plan, teamID: teamID, now: now) {
        case .payload(let payload): return payload.read(email: email, plan: plan, teamID: teamID, now: now)
        case .failure(let reason): return .failure(reason)
        }
    }

    private enum Evaluation {
        case payload(MusePortalPayload)
        case failure(UnavailableReason)
    }

    private func evaluate(email: String, plan: String, teamID: String, now: Date) async -> Evaluation {
        guard !Task.isCancelled, isEnabled, !isDisconnecting, let website else { return .failure(.timedOut) }
        if let retryNotBefore, now < retryNotBefore { return .failure(.rateLimited(retryAfter: retryNotBefore)) }
        guard pending == nil else {
            return .failure(.unsupported("A Muse portal read is already in progress. Refresh shortly."))
        }
        let current = generation
        // Navigation gets two seconds of the provider's budget. A restored
        // login must commit before its same-origin GETs can run.
        let navigation = ClaudeMonthlyCreditEvaluation()
        pending = navigation
        defer { if pending === navigation { pending = nil } }
        website.open()
        let navigationID = UUID()
        let ready = await navigation.value(waitForTimeout: { try await Task.sleep(for: .seconds(2)) }) { complete in
            website.waitUntilPortal(id: navigationID) { complete($0 ? "ready" : nil) }
        }
        website.cancelPortalWait(id: navigationID)
        guard !Task.isCancelled, isEnabled, current == generation else { return .failure(.timedOut) }
        guard ready != nil else {
            return .failure(.timedOut)
        }
        // Reuse the bounded WebKit callback gate (timeout and cancellation).
        let evaluation = ClaudeMonthlyCreditEvaluation()
        pending = evaluation
        defer { if pending === evaluation { pending = nil } }
        let text = await evaluation.value { complete in
            website.evaluate(email: email, plan: plan, teamID: teamID, complete: complete)
        }
        guard !Task.isCancelled, isEnabled, current == generation else { return .failure(.timedOut) }
        guard let text, let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MusePortalPayload.self, from: data) else {
            message = "Could not read the portal. Refresh teams to try again."
            return .failure(.badResponse)
        }
        retryNotBefore = QuotaHTTP.retryAfterDate(secondsHeader: payload.retryAfter, now: now)
        // Only a published membership list can replace the previous list.
        if let listed = payload.teams { teams = listed }
        message = payload.failure == "timedOut"
            ? "The Muse portal request timed out. Refresh to try again."
            : payload.failure == "offline"
            ? "Could not reach the Muse portal. Check your connection and refresh."
            : payload.failure == "read"
            ? "Could not read the portal response. Refresh to try again."
            : payload.failure == "http" && (payload.httpStatus == 401 || payload.httpStatus == 403)
                && retryNotBefore == nil
            ? "Sign in again to the Muse portal in Settings → API Keys → Muse portal quota."
            : payload.failure == "http"
            ? "The Muse portal request failed. Retry after the portal's cooldown, if supplied."
            : payload.failure == nil
            ? "Select the team that holds your Muse subscription. The account and plan must match your CLI login."
            : "Could not read a matching portal quota. Check your sign-in, team and plan."
        return .payload(payload)
    }

    // Only fixed, read-only same-origin queries. No credentials cross the
    // bridge; JSON is projected before returning to Swift. A fresh identity
    // and membership check precede every quota read, including after logout.
    static let query = #"""
    if (location.origin !== 'https://dev.meta.ai') return null;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    const result = {};
    async function get(path) {
      let r;
      try {
        r = await fetch(path, {method:'GET', credentials:'same-origin',
          redirect:'error', signal:controller.signal});
      } catch (error) {
        result.failure = error?.name === 'AbortError' ? 'timedOut' : 'offline';
        throw error;
      }
      if (!r.ok) {
        result.failure = 'http'; result.httpStatus = r.status;
        result.retryAfter = r.headers.get('Retry-After');
        throw new Error('http');
      }
      return await r.json();
    }
    try {
      const me = await get('/api/auth/me');
      result.email = typeof me.email === 'string' ? me.email : null;
      if (teamID && (!email || result.email?.trim().toLowerCase() !== email.trim().toLowerCase())) {
        result.failure = 'account'; return JSON.stringify(result);
      }
      const listed = await get('/api/portal/teams');
      if (!Array.isArray(listed.teams)) throw new Error('teams');
      result.teams = listed.teams.flatMap(t => {
        const id = typeof t.team_id === 'string' ? t.team_id :
          Number.isSafeInteger(t.team_id) ? String(t.team_id) : '';
        if (!/^[0-9]{1,64}$/.test(id)) return [];
        return [{id, name:typeof t.team_name === 'string' ? t.team_name.slice(0,120) : id}];
      });
      if (!teamID) return JSON.stringify(result);
      if (!result.teams.some(t => t.id === teamID)) {
        result.failure = 'team'; return JSON.stringify(result);
      }
      const q = (await get('/api/portal/teams/' + teamID + '/subscription-quota')).subscription_quota;
      if (!q || typeof q.tier !== 'string' || !plan || q.tier.trim() !== plan.trim()) {
        result.failure = 'tier'; return JSON.stringify(result);
      }
      result.subscription_quota = {tier:q.tier,
        window_weighted_used:q.window_weighted_used, window_weighted_limit:q.window_weighted_limit,
        window_resets_at:q.window_resets_at, window_duration_secs:q.window_duration_secs,
        weekly_weighted_used:q.weekly_weighted_used, weekly_weighted_limit:q.weekly_weighted_limit,
        weekly_resets_at:q.weekly_resets_at};
    } catch (error) {
      result.failure = result.failure || (error?.name === 'AbortError' ? 'timedOut' : 'read');
    }
    finally { clearTimeout(timer); }
    return JSON.stringify(result);
    """#
}

/// Keeps lifecycle tests away from real WebKit storage and network requests.
@MainActor
protocol MusePortalWebsite: AnyObject {
    var webView: WKWebView? { get }
    var isAtPortal: Bool { get }
    func open()
    func host()
    func waitUntilPortal(id: UUID, complete: @escaping @MainActor @Sendable (Bool) -> Void)
    func cancelPortalWait(id: UUID)
    func stop()
    func clear() async
    func evaluate(email: String, plan: String, teamID: String,
                  complete: @escaping @MainActor @Sendable (String?) -> Void)
}

@MainActor
final class MusePortalWebKit: NSObject, MusePortalWebsite, WKNavigationDelegate {
    // Embed the legacy production WebKit identity, frugalbar, to preserve the
    // default/Claude store too. Wrappers must match. Never clear that store.
    static let storeIdentifier = UUID(uuidString: "4AC3D48D-BC2D-419C-A916-2C94D3712B58")!
    private(set) var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var committedURL: URL?
    private var navigationComplete: (id: UUID, complete: @MainActor @Sendable (Bool) -> Void)?
    var isAtPortal: Bool {
        committedURL?.scheme == "https" && committedURL?.host == "dev.meta.ai"
    }

    func open() {
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier)
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: configuration)
            view.navigationDelegate = self
            webView = view
            host()
        }
        if !isAtPortal, webView?.isLoading == false {
            webView?.load(URLRequest(url: URL(string: "https://dev.meta.ai/")!))
        }
    }

    // Keep the page attached to an app-owned window while the settings sheet
    // is closed. This window is never ordered on screen or made key.
    func host() {
        guard let webView else { return }
        if hostWindow == nil {
            hostWindow = NSWindow(contentRect: webView.frame, styleMask: [], backing: .buffered, defer: false)
            hostWindow?.isReleasedWhenClosed = false
        }
        webView.removeFromSuperview()
        hostWindow?.contentView?.addSubview(webView)
        webView.frame = hostWindow?.contentView?.bounds ?? webView.frame
        webView.autoresizingMask = [.width, .height]
    }

    func waitUntilPortal(id: UUID, complete: @escaping @MainActor @Sendable (Bool) -> Void) {
        if isAtPortal { complete(true) } else { navigationComplete = (id, complete) }
    }

    func cancelPortalWait(id: UUID) {
        // A disconnected read can finish after a new session starts waiting.
        // Remove only its callback, leaving the user's navigation running.
        if navigationComplete?.id == id { navigationComplete = nil }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        committedURL = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        committedURL = webView.url
        if isAtPortal { navigationComplete?.complete(true); navigationComplete = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        navigationComplete?.complete(false)
        navigationComplete = nil
    }

    func stop() {
        navigationComplete?.complete(false)
        navigationComplete = nil
        committedURL = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        // Unload the signed-in page even if SwiftUI still holds the old view.
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
        hostWindow?.close()
        hostWindow = nil
    }

    func clear() async {
        let store = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func evaluate(email: String, plan: String, teamID: String,
                  complete: @escaping @MainActor @Sendable (String?) -> Void) {
        guard let webView, isAtPortal else { complete(nil); return }
        webView.callAsyncJavaScript(MusePortalSession.query,
            arguments: ["email": email, "plan": plan, "teamID": teamID], in: nil, in: .page) { result in
            let text: String?
            if case .success(let value) = result { text = value as? String } else { text = nil }
            Task { @MainActor in complete(text) }
        }
    }
}

public struct MusePortalTeam: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

enum MusePortalRead: Sendable {
    case usage(MuseQuotaProvider.SubscriptionUsage)
    case unavailable(String)
    case failure(UnavailableReason)
}

/// Only the allowlisted projection of portal GETs, never a full page body.
struct MusePortalPayload: Decodable, Sendable {
    let email: String?
    let teams: [MusePortalTeam]?
    let subscription_quota: Quota?
    let failure: String?
    let httpStatus: Int?
    let retryAfter: String?

    struct Quota: Decodable, Sendable {
        let tier: String?
        let window_weighted_used: MuseQuotaProvider.MuseNumber?
        let window_weighted_limit: MuseQuotaProvider.MuseNumber?
        let window_resets_at: MuseQuotaProvider.MuseTimestamp?
        let window_duration_secs: MuseQuotaProvider.MuseNumber?
        let weekly_weighted_used: MuseQuotaProvider.MuseNumber?
        let weekly_weighted_limit: MuseQuotaProvider.MuseNumber?
        let weekly_resets_at: MuseQuotaProvider.MuseTimestamp?
    }

    func read(email expectedEmail: String, plan: String, teamID: String, now: Date) -> MusePortalRead {
        if failure == "timedOut" { return .failure(.timedOut) }
        if failure == "offline" { return .failure(.offline) }
        if failure == "read" { return .failure(.badResponse) }
        if failure == "http" {
            let retry = QuotaHTTP.retryAfterDate(secondsHeader: retryAfter, now: now)
            if retry != nil || httpStatus == 429 { return .failure(.rateLimited(retryAfter: retry)) }
            if httpStatus == 401 || httpStatus == 403 {
                return .unavailable("Sign in again to the Muse portal in Settings → API Keys → Muse portal quota.")
            }
            return .failure(httpStatus.flatMap { QuotaHTTP.failureReason(for: $0, retryAfter: nil, now: now) } ?? .badResponse)
        }
        guard failure == nil, !expectedEmail.trimmed.isEmpty,
              email?.trimmed.lowercased() == expectedEmail.trimmed.lowercased(),
              MusePortalTeam.validID(teamID), teams?.contains(where: { $0.id == teamID }) == true,
              !plan.trimmed.isEmpty, let quota = subscription_quota, quota.tier?.trimmed == plan.trimmed else {
            return .unavailable("Muse omitted its usage window. Check that the portal account, selected team and plan match your CLI login.")
        }
        func percent(_ used: MuseQuotaProvider.MuseNumber?, _ limit: MuseQuotaProvider.MuseNumber?,
                     _ reset: MuseQuotaProvider.MuseTimestamp?) -> MuseQuotaProvider.MuseNumber? {
            guard let used = used?.value, used >= 0, let limit = limit?.value, limit > 0,
                  let reset = reset?.date, reset > now else { return nil }
            let value = used / limit * 100
            // The row formats a whole percentage as Int. Reject an
            // unrepresentable figure rather than trapping in presentation.
            return value.isFinite && value < Double(Int.max) / 2 ? .init(value: value) : nil
        }
        // Idle, expired and unknown windows stay absent. In particular an old
        // used count is never converted to zero merely because its reset passed.
        let windowPercent = percent(quota.window_weighted_used, quota.window_weighted_limit, quota.window_resets_at)
        let weeklyPercent = percent(quota.weekly_weighted_used, quota.weekly_weighted_limit, quota.weekly_resets_at)
        guard windowPercent != nil || weeklyPercent != nil else {
            return .unavailable("Muse portal reported no current usage window.")
        }
        let minutes = quota.window_duration_secs?.value.flatMap { $0 > 0 ? $0 / 60 : nil }
        return .usage(.init(
            window: windowPercent.map { .init(used_percent: $0,
                window_duration_mins: minutes.map { .init(value: $0) }, resets_at: quota.window_resets_at) },
            weekly: weeklyPercent.map { .init(used_percent: $0, resets_at: quota.weekly_resets_at) }, tier: nil))
    }
}
