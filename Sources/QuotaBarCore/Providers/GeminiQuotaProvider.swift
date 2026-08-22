import Foundation

/// Antigravity subscription quota via the Google Cloud Code API. The request
/// format is derived from antigravity-usage (MIT); no executable is required.
public final class GeminiQuotaProvider: QuotaProvider, Sendable {
    public let vendorId: VendorIdentifier = .gemini
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let accessToken: String?

    public init(accessToken: String? = nil) { self.accessToken = accessToken }

    private struct CodeAssist: Decodable {
        struct Project: Decodable { let id: String? }
        struct Plan: Decodable { let planType: String? }
        let cloudaicompanionProject: Project?
        let planInfo: Plan?
    }

    private struct ModelResponse: Decodable {
        struct Model: Decodable {
            struct Quota: Decodable { let remainingFraction: Double?; let resetTime: String? }
            let displayName: String?
            let label: String?
            let quotaInfo: Quota?
        }
        let models: [String: Model]?
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        var resolvedToken = accessToken
        if resolvedToken == nil || resolvedToken?.isEmpty == true {
            // Our own session first — it is the only one we can renew.
            resolvedToken = await GeminiOAuthSession.loadRefreshed()?.accessToken
        }
        if resolvedToken == nil || resolvedToken?.isEmpty == true {
            resolvedToken = await CredentialStore.antigravityAccessTokenAsync()
        }
        guard let token = resolvedToken, !token.isEmpty else {
            return unavailable(.notConfigured)
        }
        let metadata = ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
        let encoder = JSONEncoder()
        let assistBody = try encoder.encode(["metadata": metadata])
        let (assistData, assistHTTP) = try await QuotaHTTP.post(
            url: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", body: assistBody,
            headers: ["User-Agent": "antigravity"], auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(for: assistHTTP.statusCode) { return unavailable(reason) }
        guard let assist = try? JSONDecoder().decode(CodeAssist.self, from: assistData),
              let projectID = assist.cloudaicompanionProject?.id, !projectID.isEmpty
        else { return unavailable(.badResponse) }

        let modelBody = try encoder.encode(["project": projectID])
        let (modelsData, modelsHTTP) = try await QuotaHTTP.post(
            url: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels", body: modelBody,
            headers: ["User-Agent": "antigravity"], auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(for: modelsHTTP.statusCode) { return unavailable(reason) }
        guard let response = try? JSONDecoder().decode(ModelResponse.self, from: modelsData),
              let models = response.models
        else { return unavailable(.badResponse) }

        // 2.5 shares a pooled allowance with the older Gemini API rather than
        // the Antigravity subscription, so its fraction is not comparable with
        // the rest and would distort the headline reading.
        let readings = models.compactMap { id, model -> (String, Double, Date)? in
            guard id.lowercased().contains("gemini"), !id.contains("2.5"),
                  let remaining = model.quotaInfo?.remainingFraction, (0...1).contains(remaining),
                  let resetText = model.quotaInfo?.resetTime, let reset = Self.parseDate(resetText)
            else { return nil }
            return (model.displayName ?? model.label ?? id, 1 - remaining, reset)
        }
        // A structurally fine response that simply carries no per-model quota
        // is "this vendor published nothing", not a malformed payload.
        guard !readings.isEmpty else {
            return unavailable(.unsupported("Antigravity reported no model quota"))
        }

        // The binding constraint is the fullest model, not whichever one sorts
        // first alphabetically — that made the menu-bar colour an accident of
        // Google's naming.
        let ranked = readings.sorted { $0.1 > $1.1 }
        let primary = ranked[0]
        // Antigravity meters a shared pool, so most models report the identical
        // fraction and reset. Three bars of the same number read as three
        // separate allowances; collapse them to one row per distinct pool.
        var seen: Set<String> = []
        let pools = ranked.filter { seen.insert("\(Int(($0.1 * 1000).rounded()))@\($0.2.timeIntervalSince1970)").inserted }
        let rows = pools.prefix(3).map { Self.row(name: $0.0, used: $0.1, reset: $0.2) }
        // nil when Google published no plan type, rather than asserting one.
        let plan = assist.planInfo?.planType
        let urgency: Urgency = primary.1 > 0.90 ? .critical : primary.1 > 0.70 ? .warning : .none
        let percent = Int((primary.1 * 100).rounded())
        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: plan ?? displayName, renewalDate: nil),
            status: .measured(urgency), resetsAt: primary.2, lastUpdated: Date(),
            auxiliaryInfo: "Live Antigravity subscription quota", row1: rows[safe: 0],
            row2: rows[safe: 1], row3: rows[safe: 2], badgeText: "\(100 - percent)% left",
            planName: plan, cliSource: "Google OAuth"
        )
    }

    private static func row(name: String, used: Double, reset: Date) -> DualBarMetrics {
        DualBarMetrics(primaryFraction: used, label: "AG", statusColor: "#3b82f6",
                       usedText: "\(name): \(Int((used * 100).rounded()))% used",
                       resetText: "Resets \(RelativeDateTimeFormatter().localizedString(for: reset, relativeTo: Date()))")
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

    static let keychainLabel = "gemini.oauth.session"
    static let clientIDKeychainLabel = "gemini.oauth.client_id"
    static let clientSecretKeychainLabel = "gemini.oauth.client_secret"
    static let clientSecretEnvVar = "FRUGALBAR_GEMINI_CLIENT_SECRET"

    /// Shared by the login flow and the refresh path so a token can only ever
    /// be renewed by the client that minted it.
    ///
    /// Overridable from Settings so a new Google client can be pointed at
    /// without a rebuild — the default is FrugalBar's own.
    static let defaultClientID = "598649530021-n2bb3flau0ff6mt7v316kimt57rolkan.apps.googleusercontent.com"

    static var clientID: String {
        guard let stored = try? KeychainManager.shared.get(label: clientIDKeychainLabel),
              !stored.isEmpty
        else { return defaultClientID }
        return stored
    }

    /// Google requires `client_secret` on the token exchange for this client
    /// type; omitting it fails every sign-in with "client_secret is missing"
    /// before the user ever sees a token. It is deliberately *not* compiled in:
    /// this repository is public, so the secret comes from the Keychain (via
    /// Settings) or the environment, and is absent from the source tree.
    static var clientSecret: String? {
        if let stored = try? KeychainManager.shared.get(label: clientSecretKeychainLabel),
           !stored.isEmpty {
            return stored
        }
        let fromEnvironment = ProcessInfo.processInfo.environment[clientSecretEnvVar]
        return (fromEnvironment?.isEmpty ?? true) ? nil : fromEnvironment
    }

    /// Renew this far ahead of expiry so a request never leaves with a token
    /// that dies mid-flight.
    private static let renewalMargin: TimeInterval = 120

    static func load() -> GeminiOAuthSession? {
        guard let text = try? KeychainManager.shared.get(label: keychainLabel),
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(GeminiOAuthSession.self, from: data)
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
                "client_id": clientID,
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
        // Fail here, with a reason the user can act on, rather than letting
        // Google answer "client_secret is missing" and surfacing that as an
        // unexplained "sign-in did not complete".
        guard let secret = clientSecret else { throw ProviderError.notConfigured }

        var form = URLComponents()
        form.queryItems = fields.merging(["client_secret": secret]) { current, _ in current }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let encoded = form.percentEncodedQuery?.data(using: .utf8) else {
            throw ProviderError.badResponse
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded

        let (data, response) = try await QuotaHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.access_token.isEmpty
        else { throw ProviderError.badResponse }

        return GeminiOAuthSession(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? existingRefreshToken ?? "",
            expiry: Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600))
        )
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
