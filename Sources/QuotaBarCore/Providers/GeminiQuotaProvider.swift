import Foundation

/// Antigravity subscription quota from the Google Cloud Code API.
///
/// Reads `v1internal:retrieveUserQuotaSummary`, the same source the `agy` CLI
/// uses, from whichever of the two Cloud Code hosts publishes Gemini's windows
/// (`productionAPIHosts`). It returns the real windows the vendor meters — a
/// five-hour and a weekly bucket per model group — where `fetchAvailableModels`
/// exposes only a single `remainingFraction` per model. Using the latter showed
/// one bar and silently omitted the weekly limit, which was the binding
/// constraint.
public final class GeminiQuotaProvider: QuotaProvider, Sendable {
    public let vendorId: VendorIdentifier = .gemini
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let accessToken: String?
    private let apiBaseOverride: String?
    private let configuredAPIBase: (value: String?, invalid: Bool)

    static let productionAPIBase = "https://daily-cloudcode-pa.googleapis.com/v1internal:"

    /// The hosts to ask, in order, when no base was configured.
    ///
    /// Neither host is authoritative on its own. For some accounts the daily
    /// host's summary carries only the "Claude and GPT models" group while the
    /// plain host carries Gemini's windows too, and for others it is the
    /// reverse — the account this was diagnosed on got `200` with just
    /// `["Claude and GPT models"]` from `daily-` and both groups from the plain
    /// host. The `agy` CLI walks the same pair, and so does T3 Code's
    /// Antigravity probe, which is where this order comes from. A host whose
    /// summary yields a Gemini window ends the walk.
    static let productionAPIHosts = [
        productionAPIBase,
        "https://cloudcode-pa.googleapis.com/v1internal:"
    ]

    static func apiBase(from rawValue: String?) -> (value: String?, invalid: Bool) {
        guard let value = rawValue, !value.isEmpty else { return (nil, false) }
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              host.lowercased() == "googleapis.com" || host.lowercased().hasSuffix(".googleapis.com"),
              components.port == nil, components.user == nil,
              components.query == nil, components.fragment == nil else {
            NSLog("frugalbar: ignoring invalid FRUGALBAR_GEMINI_API_BASE; expected an https URL")
            return (nil, true)
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/:").union(.whitespacesAndNewlines))
        guard path.isEmpty || path == "v1internal" else {
            NSLog("frugalbar: ignoring invalid FRUGALBAR_GEMINI_API_BASE; expected an https URL")
            return (nil, true)
        }
        components.path = "/v1internal"
        let normalized = components
        return (normalized.url.map { $0.absoluteString + ":" }, false)
    }

    public init(accessToken: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.accessToken = accessToken
        self.apiBaseOverride = nil
        self.configuredAPIBase = Self.apiBase(from: environment["FRUGALBAR_GEMINI_API_BASE"])
    }

    init(accessToken: String?, apiBaseOverride: String?) {
        self.accessToken = accessToken
        self.apiBaseOverride = apiBaseOverride
        self.configuredAPIBase = (nil, false)
    }

    private struct CodeAssist: Decodable, Sendable {
        struct Plan: Decodable, Sendable { let planType: String? }
        struct Tier: Decodable, Sendable { let id: String?; let name: String? }
        let planInfo: Plan?
        let currentTier: Tier?
        let paidTier: Tier?
        let cloudaicompanionProject: String?
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
            /// The vendor switching a bucket off. A disabled bucket keeps its
            /// last `remainingFraction`, and drawing that would report a window
            /// nobody is being metered against. Absent means enabled.
            let disabled: Bool?
        }
        let groups: [Group]?
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        let configured = configuredAPIBase
        if apiBaseOverride == nil, configured.invalid {
            return unavailable(.unsupported("FRUGALBAR_GEMINI_API_BASE is not a valid https://*.googleapis.com URL"))
        }

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

        // A configured base is the operator's answer: one host, and its failure
        // is this provider's answer. Otherwise both production hosts are asked,
        // because either can be the one that publishes Gemini's windows.
        let bases = apiBaseOverride.map { [$0] }
            ?? configured.value.map { [$0] }
            ?? Self.productionAPIHosts

        let now = Date()
        var resolvedBase: String?
        var resolvedPlan: String?
        var resolvedGroup: QuotaSummary.Group?
        var readings: [Reading] = []
        // What the last host to answer said, when none of them published a
        // Gemini window. Kept so the row names the real reason rather than a
        // generic one.
        var lastFailure: UnavailableReason?
        // A transport failure is the engine's to map — it alone knows the
        // difference between `offline` and `timedOut` — so it is held rather
        // than turned into a reason here. It stands only while no host has
        // spoken, and a credential rejection below is the one verdict allowed
        // to overrule it.
        var transportFailure: Error?
        for base in bases {
            do {
                // Scope before reading quota. A populated project-less summary
                // can describe a different pool; its numbers cannot establish
                // that this account has allowance left.
                let (assistData, assistHTTP) = try await Self.loadCodeAssist(token: token, base: base)
                if let reason = QuotaHTTP.failureReason(for: assistHTTP.statusCode) {
                    lastFailure = reason
                    if reason == .credentialRejected {
                        transportFailure = nil
                        break
                    }
                    continue
                }
                guard let assist = try? JSONDecoder().decode(CodeAssist.self, from: assistData) else {
                    lastFailure = .badResponse
                    continue
                }
                guard let project = assist.cloudaicompanionProject?.trimmed, !project.isEmpty else {
                    lastFailure = .unsupported("Antigravity did not identify a quota project")
                    continue
                }
                let (data, http) = try await Self.quotaSummary(token: token, base: base, project: project)
                if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
                    lastFailure = reason
                    // A rejected credential is a verdict on the token, not on
                    // the host: the next host would receive the same token and
                    // answer the same way. Everything else — a route missing on
                    // this host, a 5xx, a 429 — may be this host's own trouble,
                    // so the walk continues.
                    if reason == .credentialRejected {
                        // The vendor just spoke about the credential itself, and
                        // that outranks an earlier host's transport failure:
                        // reporting `.timedOut` for a token the vendor refused
                        // sends the user to check a connection that is fine, and
                        // only `credentialRejected` is exempt from the poll floor
                        // — so a re-sign-in would not even take effect at once.
                        transportFailure = nil
                        break
                    }
                    continue
                }
                guard let summary = try? JSONDecoder().decode(QuotaSummary.self, from: data) else {
                    lastFailure = .badResponse
                    continue
                }
                guard let group = Self.geminiGroup(in: summary) else {
                    lastFailure = .unsupported("Antigravity reported no Gemini quota")
                    continue
                }
                // Counted after the disabled filter: a group whose every bucket
                // the vendor switched off is no reading, so the next host is
                // still worth asking.
                let read = (group.buckets ?? []).compactMap { Self.reading($0, now: now) }
                guard !read.isEmpty else {
                    lastFailure = .unsupported("Antigravity reported no Gemini quota")
                    continue
                }
                resolvedPlan = assist.paidTier?.name ?? assist.planInfo?.planType ?? assist.currentTier?.name
                resolvedBase = base
                resolvedGroup = group
                readings = read
                break
            } catch {
                NSLog("frugalbar: Gemini backend %@ failed: %@", base, String(describing: error))
                transportFailure = error
            }
        }

        guard let base = resolvedBase, let group = resolvedGroup, !readings.isEmpty else {
            // A host that never answered outranks the content verdict of one
            // that did, and that asymmetry is deliberate: a 200 without a Gemini
            // group says "this *host* does not publish them", and which host
            // publishes them is exactly what differs between accounts here. So
            // it cannot stand in for a host that timed out and never said
            // anything. A credential rejection is the exception, cleared above,
            // because the token is the same wherever it is presented.
            if let transportFailure { throw transportFailure }
            return unavailable(lastFailure ?? .badResponse)
        }

        // Shortest window first, so the row reads 5H then WK like every other
        // provider rather than in whatever order the API happened to send.
        let ordered = readings.sorted { $0.windowLength ?? .infinity < $1.windowLength ?? .infinity }
        let worst = ordered.map(\.used).max() ?? 0
        let urgency: Urgency = worst > 0.90 ? .critical : worst > 0.70 ? .warning : .none

        // The tier comes from the same host and account scope as the reading.
        // Its absence never costs us a measured quota.
        let plan = resolvedPlan
        let sourceHost = URL(string: base)?.host ?? base
        let sourceSuffix = Self.productionAPIHosts.contains(base) ? "" : " · Source: \(sourceHost)"

        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: plan, renewalDate: nil),
            status: .measured(urgency), resetsAt: ordered.first?.reset, lastUpdated: now,
            auxiliaryInfo: (group.description ?? "Live Antigravity subscription quota") + sourceSuffix,
            row1: ordered[safe: 0].map { $0.bar }, row2: ordered[safe: 1].map { $0.bar },
            row3: ordered[safe: 2].map { $0.bar },
            badgeText: "\(Int(((1 - worst) * 100).rounded()))% left",
            planName: plan, cliSource: "Google OAuth\(sourceSuffix)"
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

    /// Only Google's selected project scopes this account's quota. Never fall
    /// back to a project-less response after a scoped request fails.
    private static func quotaSummary(
        token: String, base: String, project: String
    ) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONEncoder().encode(["project": project])
        return try await QuotaHTTP.post(
            url: base + "retrieveUserQuotaSummary", body: body,
            headers: ["User-Agent": "antigravity"], auth: .bearer(token))
    }

    private struct Reading {
        let used: Double
        let reset: Date?
        let windowLength: TimeInterval?
        let bar: DualBarMetrics
    }

    private static func reading(_ bucket: QuotaSummary.Bucket, now: Date) -> Reading? {
        // A bucket the vendor switched off keeps whatever fraction it last
        // published; drawing it would report a window nothing is metered
        // against. T3 Code's Antigravity probe skips the same flag.
        guard bucket.disabled != true else { return nil }
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
            usedText: "\(Int((used * 100).rounded()))% used",
            resetText: reset.map { "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))" },
            resetsAt: reset, windowLength: length
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

    private static func loadCodeAssist(token: String, base: String) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONEncoder().encode(
            ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]])
        return try await QuotaHTTP.post(
            url: base + "loadCodeAssist", body: body,
            headers: ["User-Agent": "antigravity"], auth: .bearer(token))
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
        guard isUsable(session, forClientID: clientID) else { return nil }
        return session
    }

    /// Whether a stored session can be used by the currently configured
    /// client. A refresh token belongs to the client that issued it, so a
    /// session carried across a client change is dead weight — and left in
    /// place it produced a permanent "Credential rejected" that no amount of
    /// re-signing-in would clear. A session with no recorded client predates
    /// the field and counts as foreign.
    static func isUsable(_ session: GeminiOAuthSession, forClientID clientID: String?) -> Bool {
        guard let clientID, let sessionClient = session.clientID else { return false }
        return sessionClient == clientID
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
