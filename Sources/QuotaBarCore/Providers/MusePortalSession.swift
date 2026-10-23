import Foundation
import Combine
import WebKit

/// A separate, opt-in portal login. WebKit owns an ephemeral session; no
/// browser cookies are imported, extracted, or persisted as credentials.
@MainActor
public final class MusePortalSession: ObservableObject {
    public static let shared = MusePortalSession()
    @Published public private(set) var isEnabled = false
    @Published public private(set) var teams: [MusePortalTeam] = []
    @Published public private(set) var message = "Sign in, then refresh the team list."
    /// The team read is owned by the session, not by the sheet that starts it:
    /// the sheet can be dismissed mid-read, and a view-held flag would then be
    /// left set, or cleared on a view that no longer exists.
    @Published public private(set) var isReadingTeams = false
    @Published public var selectedTeamID = "" {
        didSet { generation = UUID() }
    }
    public private(set) var webView: WKWebView?
    private var generation = UUID()
    private var pending: ClaudeMonthlyCreditEvaluation?
    private var retryNotBefore: Date?

    private init() {}

    public func connect() {
        guard !TestHost.isActive else { return }
        isEnabled = true
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view
        view.load(URLRequest(url: URL(string: "https://dev.meta.ai/")!))
    }

    public func disconnect() {
        isEnabled = false
        generation = UUID()
        pending?.finish(nil)
        pending = nil
        webView?.stopLoading()
        webView = nil
        teams = []
        selectedTeamID = ""
        retryNotBefore = nil
        message = "Sign in, then refresh the team list."
    }

    public func refreshTeams() async {
        // Released on every exit path, cancellation included, because it is
        // the session's flag rather than a view's.
        guard !isReadingTeams else { return }
        isReadingTeams = true
        defer { isReadingTeams = false }
        _ = await evaluate(email: "", plan: "", teamID: "", now: Date())
    }

    func read(email: String, plan: String, now: Date) async -> MusePortalRead {
        guard isEnabled else { return .unavailable(MuseQuotaProvider.missingUsageMessage) }
        guard MusePortalTeam.validID(selectedTeamID) else {
            return .unavailable("Muse omitted its usage window. Choose a team in Settings → API Keys → Muse portal quota.")
        }
        let teamID = selectedTeamID
        guard let payload = await evaluate(email: email, plan: plan, teamID: teamID, now: now) else {
            return .unavailable("Muse omitted its usage window. Sign in again or refresh the Muse portal connection.")
        }
        return payload.read(email: email, plan: plan, teamID: teamID, now: now)
    }

    private func evaluate(email: String, plan: String, teamID: String, now: Date) async -> MusePortalPayload? {
        guard !TestHost.isActive, !Task.isCancelled, isEnabled, pending == nil,
              retryNotBefore.map({ now >= $0 }) ?? true,
              let webView, webView.url?.scheme == "https", webView.url?.host == "dev.meta.ai" else { return nil }
        let current = generation
        // Reuse the bounded WebKit callback gate (timeout and cancellation).
        let evaluation = ClaudeMonthlyCreditEvaluation()
        pending = evaluation
        defer { if pending === evaluation { pending = nil } }
        let text = await evaluation.value { complete in
            webView.callAsyncJavaScript(Self.query,
                arguments: ["email": email, "plan": plan, "teamID": teamID], in: nil, in: .page) { result in
                let text: String?
                if case .success(let value) = result { text = value as? String } else { text = nil }
                Task { @MainActor in complete(text) }
            }
        }
        guard !Task.isCancelled, isEnabled, current == generation else { return nil }
        guard let text, let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MusePortalPayload.self, from: data) else {
            message = "Could not read the portal. Sign in and refresh teams."
            return nil
        }
        retryNotBefore = QuotaHTTP.retryAfterDate(secondsHeader: payload.retryAfter, now: now)
        // A failed or partial read is not evidence that the membership
        // changed. Only the `GET /api/portal/teams` step produces this list,
        // so an absent one leaves the previous selection intact instead of
        // emptying the picker and stranding `selectedTeamID` outside it.
        if let listed = payload.teams { teams = listed }
        message = payload.failure == nil
            ? "Select the team that holds your Muse subscription. The account and plan must match your CLI login."
            : "Could not read a matching portal quota. Check your sign-in, team and plan."
        return payload
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
      const r = await fetch(path, {method:'GET', credentials:'same-origin',
        redirect:'error', signal:controller.signal});
      if (!r.ok) {
        result.failure = 'http'; result.retryAfter = r.headers.get('Retry-After');
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
    } catch (_) { result.failure = result.failure || 'read'; }
    finally { clearTimeout(timer); }
    return JSON.stringify(result);
    """#
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
}

/// Only the allowlisted projection of portal GETs, never a full page body.
struct MusePortalPayload: Decodable, Sendable {
    let email: String?
    let teams: [MusePortalTeam]?
    let subscription_quota: Quota?
    let failure: String?
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
