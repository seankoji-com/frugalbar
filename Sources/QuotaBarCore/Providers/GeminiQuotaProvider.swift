import Foundation

/// Antigravity subscription quota from the Google Cloud Code API.
///
/// Reads `v1internal:retrieveUserQuotaSummary`, the same source the `agy` CLI
/// uses. It returns the real windows the vendor meters — a five-hour and a
/// weekly bucket per model group — where `fetchAvailableModels` exposes only a
/// single `remainingFraction` per model. Using the latter showed one bar and
/// silently omitted the weekly limit, which was the binding constraint.
public final class GeminiQuotaProvider: QuotaProvider, Sendable {
    public let vendorId: VendorIdentifier = .gemini
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let accessToken: String?

    public init(accessToken: String? = nil) { self.accessToken = accessToken }

    private struct CodeAssist: Decodable {
        struct Plan: Decodable { let planType: String? }
        struct Tier: Decodable { let id: String?; let name: String? }
        let planInfo: Plan?
        let currentTier: Tier?
        let paidTier: Tier?
    }

    struct QuotaSummary: Decodable, Sendable {
        struct Group: Decodable, Sendable {
            let displayName: String?
            let description: String?
            let buckets: [Bucket]?
        }
        struct Bucket: Decodable, Sendable {
            let bucketId: String?
            let displayName: String?
            /// "5h", "weekly" — the vendor naming its own window, which is what
            /// makes an honest pace marker possible.
            let window: String?
            let resetTime: String?
            let remainingFraction: Double?
        }
        let groups: [Group]?
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        var resolvedToken = accessToken
        // Ambient credential lookup is skipped under a test host. Otherwise
        // whether "no key short-circuits" passes depends on whether the
        // developer running the suite happens to be signed in to Google.
        if !TestHost.isActive {
            if resolvedToken == nil || resolvedToken?.isEmpty == true {
                // Our own session first — it is the only one we can renew.
                resolvedToken = await GeminiOAuthSession.loadRefreshed()?.accessToken
            }
            if resolvedToken == nil || resolvedToken?.isEmpty == true {
                resolvedToken = await CredentialStore.antigravityAccessTokenAsync()
            }
        }
        guard let token = resolvedToken, !token.isEmpty else {
            return unavailable(.notConfigured)
        }

        // The quota summary takes an empty body — it is scoped by the token,
        // needs no project, and so cannot fail on project resolution.
        let (data, http) = try await QuotaHTTP.post(
            url: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            body: Data("{}".utf8),
            headers: ["User-Agent": "antigravity"], auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) { return unavailable(reason) }
        guard let summary = try? JSONDecoder().decode(QuotaSummary.self, from: data) else {
            return unavailable(.badResponse)
        }
        guard let group = Self.geminiGroup(in: summary) else {
            return unavailable(.unsupported("Antigravity reported no Gemini quota"))
        }

        let now = Date()
        let readings = (group.buckets ?? []).compactMap { Self.reading($0, now: now) }
        guard !readings.isEmpty else {
            return unavailable(.unsupported("Antigravity reported no Gemini quota"))
        }

        // Shortest window first, so the row reads 5H then WK like every other
        // provider rather than in whatever order the API happened to send.
        let ordered = readings.sorted { $0.windowLength ?? .infinity < $1.windowLength ?? .infinity }
        let worst = ordered.map(\.used).max() ?? 0
        let urgency: Urgency = worst > 0.90 ? .critical : worst > 0.70 ? .warning : .none

        // The plan is decoration, so it is fetched best-effort: losing it must
        // not cost us a reading we already hold.
        let plan = await Self.plan(token: token)

        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: plan ?? displayName, renewalDate: nil),
            status: .measured(urgency), resetsAt: ordered.first?.reset, lastUpdated: now,
            auxiliaryInfo: group.description ?? "Live Antigravity subscription quota",
            row1: ordered[safe: 0].map { $0.bar }, row2: ordered[safe: 1].map { $0.bar },
            row3: ordered[safe: 2].map { $0.bar },
            badgeText: "\(Int(((1 - worst) * 100).rounded()))% left",
            planName: plan, cliSource: "Google OAuth"
        )
    }

    /// The group metering Gemini itself. The response also carries a "Claude
    /// and GPT models" group — a genuinely separate Antigravity allowance that
    /// would be a lie to average into a row labelled Gemini.
    static func geminiGroup(in summary: QuotaSummary) -> QuotaSummary.Group? {
        summary.groups?.first { group in
            if group.buckets?.contains(where: { $0.bucketId?.hasPrefix("gemini") == true }) == true {
                return true
            }
            return group.displayName?.lowercased().contains("gemini") == true
        }
    }

    private struct Reading {
        let used: Double
        let reset: Date?
        let windowLength: TimeInterval?
        let bar: DualBarMetrics
    }

    private static func reading(_ bucket: QuotaSummary.Bucket, now: Date) -> Reading? {
        guard let remaining = bucket.remainingFraction, (0...1).contains(remaining) else { return nil }
        let used = 1 - remaining
        let reset = bucket.resetTime.flatMap(parseDate)
        let length = windowLength(for: bucket.window)
        let bar = DualBarMetrics(
            primaryFraction: used,
            expectedPaceFraction: length.flatMap {
                DualBarMetrics.proRataPace(resetsAt: reset, windowLength: $0, now: now)
            },
            label: label(for: bucket.window),
            statusColor: "#3b82f6",
            usedText: "\(Int((used * 100).rounded()))% used",
            resetText: reset.map { "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))" }
        )
        return Reading(used: used, reset: reset, windowLength: length, bar: bar)
    }

    /// Window lengths come from the vendor's own name for the bucket, so the
    /// pace marker is never placed against a length we assumed.
    static func windowLength(for window: String?) -> TimeInterval? {
        switch window?.lowercased() {
        case "5h":     QuotaWindow.fiveHours
        case "weekly": QuotaWindow.week
        default:       nil
        }
    }

    static func label(for window: String?) -> String {
        switch window?.lowercased() {
        case "5h":      "5H"
        case "weekly":  "WK"
        case "monthly": "MO"
        case .some(let other): other.uppercased()
        case .none:     "AG"
        }
    }

    private static func plan(token: String) async -> String? {
        let body = try? JSONEncoder().encode(
            ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]])
        guard let body,
              let (data, http) = try? await QuotaHTTP.post(
                  url: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", body: body,
                  headers: ["User-Agent": "antigravity"], auth: .bearer(token)),
              (200...299).contains(http.statusCode),
              let assist = try? JSONDecoder().decode(CodeAssist.self, from: data)
        else { return nil }
        // Two tiers live in this response and only one is the subscription.
        // `currentTier` is the Code Assist licence — "free-tier" for almost any
        // personal account — so showing it told a paying subscriber they were
        // on the free tier. `paidTier` is what the account actually pays for.
        return assist.paidTier?.name ?? assist.planInfo?.planType ?? assist.currentTier?.name
    }

    private static func parseDate(_ text: String) -> Date? {
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

public struct GeminiOAuthSession: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiry: Date
    /// Which OAuth client minted this session. A refresh token belongs to the
    /// client that issued it, so a session carried over from a previous client
    /// is dead weight — without this, switching clients left users staring at
    /// "Credential rejected" with a stored session that could never work.
    /// Optional so sessions written before this field decode rather than throw;
    /// nil is treated as "not this client".
    public let clientID: String?

    static let keychainLabel = "gemini.oauth.session"
    static let clientIDKeychainLabel = "gemini.oauth.client_id"
    static let clientSecretKeychainLabel = "gemini.oauth.client_secret"
    static let clientSecretEnvVar = "FRUGALBAR_GEMINI_CLIENT_SECRET"

    /// The OAuth client FrugalBar signs in as. Supplied by the operator, not
    /// shipped.
    ///
    /// `cloudcode-pa.googleapis.com` is a private API allowlisted to Google's
    /// own first-party projects. A client you create cannot call it: enabling
    /// the service is refused even to a project Owner, and it is not listed
    /// among a project's *available* services at all. So reading Antigravity
    /// quota requires presenting a first-party client — in practice the one the
    /// `antigravity-usage` CLI publishes in its `OAUTH_CONFIG`.
    ///
    /// Those values are deliberately absent from this repository. They are
    /// another product's credentials, GitHub's push protection rejects them,
    /// and committing them would bake one vendor's identity into the source.
    /// Set them once in Settings → Keys → Gemini, or via
    /// `FRUGALBAR_GEMINI_CLIENT_ID` / `FRUGALBAR_GEMINI_CLIENT_SECRET`.
    static let clientIDEnvVar = "FRUGALBAR_GEMINI_CLIENT_ID"


    static var clientID: String? {
        if let stored = try? KeychainManager.shared.get(label: clientIDKeychainLabel),
           !stored.isEmpty {
            return stored
        }
        let fromEnvironment = ProcessInfo.processInfo.environment[clientIDEnvVar]
        return (fromEnvironment?.isEmpty ?? true) ? nil : fromEnvironment
    }

    /// Google requires `client_secret` on the token exchange for this client
    /// type; omitting it failed every sign-in with "client_secret is missing"
    /// before the user ever saw a token.
    ///
    static var clientSecret: String? {
        if let stored = try? KeychainManager.shared.get(label: clientSecretKeychainLabel),
           !stored.isEmpty {
            return stored
        }
        let fromEnvironment = ProcessInfo.processInfo.environment[clientSecretEnvVar]
        return (fromEnvironment?.isEmpty ?? true) ? nil : fromEnvironment
    }

    /// Both halves are needed to sign in or refresh.
    static var isClientConfigured: Bool { clientID != nil && clientSecret != nil }

    /// Renew this far ahead of expiry so a request never leaves with a token
    /// that dies mid-flight.
    private static let renewalMargin: TimeInterval = 120

    static func load() -> GeminiOAuthSession? {
        guard let text = try? KeychainManager.shared.get(label: keychainLabel),
              let data = text.data(using: .utf8),
              let session = try? JSONDecoder().decode(GeminiOAuthSession.self, from: data)
        else { return nil }
        // Sessions from another client are discarded rather than sent to be
        // rejected: the honest state is "sign in again", not "bad credential".
        guard session.clientID == clientID else { return nil }
        return session
    }

    static func save(_ session: GeminiOAuthSession) throws {
        let encoded = try JSONEncoder().encode(session)
        try KeychainManager.shared.set(key: String(decoding: encoded, as: UTF8.self),
                                       label: keychainLabel)
    }

    /// The stored session, renewed first if its access token is spent.
    ///
    /// Google's access tokens last an hour. Without this the app read a live
    /// quota once and then reported "credential rejected" until the user
    /// noticed and signed in by hand.
    static func loadRefreshed() async -> GeminiOAuthSession? {
        guard let session = load() else { return nil }
        if session.expiry.timeIntervalSinceNow > renewalMargin { return session }
        guard !session.refreshToken.isEmpty else { return nil }
        guard let renewed = try? await requestToken(
            fields: [
                "refresh_token": session.refreshToken,
                "grant_type": "refresh_token",
            ],
            existingRefreshToken: session.refreshToken
        ) else { return nil }
        try? save(renewed)
        return renewed
    }

    /// Posts a form-encoded grant to Google's token endpoint.
    ///
    /// A refresh response omits `refresh_token`, so the caller passes the one
    /// it already holds; dropping it would strand the user at the next expiry.
    static func requestToken(fields: [String: String],
                             existingRefreshToken: String?) async throws -> GeminiOAuthSession {
        // Fail with a reason the user can act on, rather than letting Google
        // answer "client_secret is missing" and surfacing that as an
        // unexplained "sign-in did not complete".
        guard let secret = clientSecret, let id = clientID else { throw ProviderError.notConfigured }

        var form = URLComponents()
        form.queryItems = fields
            .merging(["client_secret": secret, "client_id": id]) { current, _ in current }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let encoded = form.percentEncodedQuery?.data(using: .utf8) else {
            throw ProviderError.badResponse
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded

        let (data, response) = try await QuotaHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        // Google explains itself here — `invalid_client`, `redirect_uri_mismatch`,
        // `invalid_grant` — and this used to be thrown away as a bare
        // `badResponse`, which reached the user as "sign-in did not complete"
        // and cost three rounds of guessing. Only the two error fields are
        // surfaced; the body of a *successful* response is never touched.
        guard (200...299).contains(http.statusCode) else {
            throw GeminiOAuthError(from: data, statusCode: http.statusCode)
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.access_token.isEmpty
        else { throw ProviderError.badResponse }

        return GeminiOAuthSession(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? existingRefreshToken ?? "",
            expiry: Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600)),
            clientID: clientID
        )
    }

    struct ErrorResponse: Decodable {
        let error: String?
        let error_description: String?
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// What Google said when it refused a token request.
///
/// Carries only the `error` / `error_description` pair from a non-2xx
/// response. Those name the misconfiguration — a wrong secret, an
/// unregistered redirect, a spent code — and none of them is a credential.
public struct GeminiOAuthError: Error, Sendable, Equatable {
    public let code: String
    public let detail: String

    init(from data: Data, statusCode: Int) {
        let decoded = try? JSONDecoder().decode(GeminiOAuthSession.ErrorResponse.self, from: data)
        self.code = decoded?.error ?? "http_\(statusCode)"
        self.detail = decoded?.error_description ?? ""
    }

    public init(code: String, detail: String) {
        self.code = code
        self.detail = detail
    }

    public var summary: String {
        detail.isEmpty ? code : "\(code) — \(detail)"
    }
}
