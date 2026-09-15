import Foundation

/// Configuration for connecting to a CLIProxyAPI instance.
public struct CLIProxyConfig: Sendable, Equatable {
    public let url: URL
    public let managementKey: String
    public let label: String?

    public init(url: URL, managementKey: String, label: String? = nil) {
        self.url = url
        self.managementKey = managementKey
        self.label = label
    }
}

/// An account managed by CLIProxyAPI.
public struct CLIProxyAuthFile: Decodable, Sendable, Equatable {
    public struct IDToken: Decodable, Sendable, Equatable {
        public let chatgptAccountId: String?
        public let chatgptPlanType: String?
        public let planType: String?

        public init(chatgptAccountId: String? = nil, chatgptPlanType: String? = nil, planType: String? = nil) {
            self.chatgptAccountId = chatgptAccountId
            self.chatgptPlanType = chatgptPlanType
            self.planType = planType
        }

        enum CodingKeys: String, CodingKey {
            case chatgptAccountId = "chatgpt_account_id"
            case chatgptPlanType = "chatgpt_plan_type"
            case planType = "plan_type"
        }
    }

    public let id: String?
    public let authIndex: String
    public let provider: String
    public let email: String?
    public let disabled: Bool?
    public let idToken: IDToken?

    public init(
        id: String? = nil,
        authIndex: String,
        provider: String,
        email: String? = nil,
        disabled: Bool? = nil,
        idToken: IDToken? = nil
    ) {
        self.id = id
        self.authIndex = authIndex
        self.provider = provider
        self.email = email
        self.disabled = disabled
        self.idToken = idToken
    }

    enum CodingKeys: String, CodingKey {
        case id
        case authIndex = "auth_index"
        case provider
        case email
        case disabled
        case idToken = "id_token"
    }
}

/// Anthropic OAuth usage API response payload.
public struct ClaudeOAuthUsageResponse: Decodable, Sendable, Equatable {
    public struct Window: Decodable, Sendable, Equatable {
        public let utilization: Double
        public let resetsAt: String?

        public init(utilization: Double, resetsAt: String? = nil) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?

    public init(fiveHour: Window? = nil, sevenDay: Window? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

/// Client for discovering CLIProxyAPI hubs and querying account usage via its management API.
public enum CLIProxyClient {

    public static func base64url(string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    public static func parseResetDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: string) {
            return date
        }
        let custom = DateFormatter()
        custom.locale = Locale(identifier: "en_US_POSIX")
        custom.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
        if let date = custom.date(from: string) {
            return date
        }
        custom.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return custom.date(from: string)
    }

    public static func managementURL(path: String, base: URL) -> String {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: base, resolvingAgainstBaseURL: true)
        components?.path = "/v0/management/\(cleanPath)"
        return components?.url?.absoluteString ?? "\(base.absoluteString)/v0/management/\(cleanPath)"
    }

    static func discoverConfig(
        settingsURL: URL? = nil,
        secretsDir: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isCLIDiscoveryEnabled: Bool = CredentialStore.isCLIDiscoveryEnabled,
        isTestHost: Bool = TestHost.isActive
    ) -> CLIProxyConfig? {
        // 1. Environment variables
        if let rawUrl = environment["CLIPROXY_URL"] ?? environment["FRUGALBAR_CLIPROXY_URL"],
           let url = URL(string: rawUrl),
           let key = environment["CLIPROXY_API_KEY"] ?? environment["FRUGALBAR_CLIPROXY_KEY"],
           !key.isEmpty {
            return CLIProxyConfig(url: url, managementKey: key, label: "Environment")
        }

        // 2. Preferences / Keychain
        if let prefUrl = CredentialStore.preferences.string(forKey: "QuotaBarCLIProxyURL"),
           let url = URL(string: prefUrl) {
            let key = (try? KeychainManager.shared.get(label: "cliproxy")) ?? CredentialStore.preferences.string(forKey: "QuotaBarCLIProxyKey")
            if let key, !key.isEmpty {
                return CLIProxyConfig(url: url, managementKey: key, label: "Preferences")
            }
        }

        // 3. ~/.t3/userdata/settings.json
        guard isCLIDiscoveryEnabled else { return nil }
        if isTestHost && settingsURL == nil {
            return nil
        }

        let defaultSettingsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".t3/userdata/settings.json")
        let targetSettingsURL = settingsURL ?? defaultSettingsURL

        guard let data = try? Data(contentsOf: targetSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = json["usageLimitSources"] as? [String: Any]
        else {
            return nil
        }

        let defaultSecretsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".t3/userdata/secrets")
        let targetSecretsDir = secretsDir ?? defaultSecretsDir

        for (sourceId, value) in sources {
            guard let sourceDict = value as? [String: Any],
                  sourceDict["kind"] as? String == "cliproxy",
                  sourceDict["enabled"] as? Bool != false,
                  let urlString = sourceDict["url"] as? String,
                  let url = URL(string: urlString)
            else { continue }

            let label = sourceDict["label"] as? String
            var managementKey = (sourceDict["managementKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let redactedMarker = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
            if managementKey == nil || managementKey == redactedMarker || managementKey?.isEmpty == true {
                let secretFileName = "usage-limit-source-\(base64url(string: sourceId)).bin"
                let secretFile = targetSecretsDir.appendingPathComponent(secretFileName)
                if let secretData = try? Data(contentsOf: secretFile),
                   let secretText = String(data: secretData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !secretText.isEmpty {
                    managementKey = secretText
                }
            }

            if let key = managementKey, !key.isEmpty, key != redactedMarker {
                return CLIProxyConfig(url: url, managementKey: key, label: label ?? "CLI Proxy")
            }
        }

        return nil
    }

    private struct AuthFilesWrapper: Decodable {
        let files: [CLIProxyAuthFile]
    }

    public static func decodeAuthFiles(from data: Data) throws -> [CLIProxyAuthFile] {
        if let wrapper = try? JSONDecoder().decode(AuthFilesWrapper.self, from: data) {
            return wrapper.files
        }
        return try JSONDecoder().decode([CLIProxyAuthFile].self, from: data)
    }

    private struct APICallWrapper: Decodable {
        let statusCode: Int
        let body: String

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case body
        }
    }

    public static func decodeClaudeUsage(from data: Data) throws -> ClaudeOAuthUsageResponse {
        if let wrapper = try? JSONDecoder().decode(APICallWrapper.self, from: data) {
            if let reason = QuotaHTTP.failureReason(for: wrapper.statusCode) {
                throw ProviderError(reason)
            }
            guard let innerData = wrapper.body.data(using: .utf8) else {
                throw ProviderError.badResponse
            }
            return try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: innerData)
        }
        return try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
    }

    public static func fetchClaudeUsage(config: CLIProxyConfig) async throws -> (ClaudeOAuthUsageResponse, CLIProxyAuthFile) {
        let authFilesURL = managementURL(path: "auth-files", base: config.url)
        let (authData, authResponse) = try await QuotaHTTP.get(
            url: authFilesURL,
            headers: ["Accept": "application/json"],
            auth: .bearer(config.managementKey)
        )
        if let reason = QuotaHTTP.failureReason(for: authResponse.statusCode) {
            throw ProviderError(reason)
        }

        let files = try decodeAuthFiles(from: authData)
        guard let claudeAccount = files.first(where: {
            ($0.disabled != true) && $0.provider.lowercased() == "claude"
        }) else {
            throw ProviderError(.notConfigured)
        }

        let apiCallURL = managementURL(path: "api-call", base: config.url)
        let payload: [String: Any] = [
            "auth_index": claudeAccount.authIndex,
            "method": "GET",
            "url": "https://api.anthropic.com/api/oauth/usage",
            "header": [
                "Authorization": "Bearer $TOKEN$",
                "anthropic-beta": "oauth-2025-04-20"
            ]
        ]
        let requestBody = try JSONSerialization.data(withJSONObject: payload)
        let (apiCallData, apiCallResponse) = try await QuotaHTTP.post(
            url: apiCallURL,
            body: requestBody,
            headers: ["Content-Type": "application/json"],
            auth: .bearer(config.managementKey)
        )
        if let reason = QuotaHTTP.failureReason(for: apiCallResponse.statusCode) {
            throw ProviderError(reason)
        }

        let usage = try decodeClaudeUsage(from: apiCallData)
        return (usage, claudeAccount)
    }

    public static func decodeCodexUsage(from data: Data) throws -> OpenAIQuotaProvider.Response {
        if let wrapper = try? JSONDecoder().decode(APICallWrapper.self, from: data) {
            if let reason = QuotaHTTP.failureReason(for: wrapper.statusCode) {
                throw ProviderError(reason)
            }
            guard let innerData = wrapper.body.data(using: .utf8) else {
                throw ProviderError.badResponse
            }
            return try JSONDecoder().decode(OpenAIQuotaProvider.Response.self, from: innerData)
        }
        return try JSONDecoder().decode(OpenAIQuotaProvider.Response.self, from: data)
    }

    public static func fetchCodexUsage(config: CLIProxyConfig) async throws -> (OpenAIQuotaProvider.Response, CLIProxyAuthFile) {
        let authFilesURL = managementURL(path: "auth-files", base: config.url)
        let (authData, authResponse) = try await QuotaHTTP.get(
            url: authFilesURL,
            headers: ["Accept": "application/json"],
            auth: .bearer(config.managementKey)
        )
        if let reason = QuotaHTTP.failureReason(for: authResponse.statusCode) {
            throw ProviderError(reason)
        }

        let files = try decodeAuthFiles(from: authData)
        guard let codexAccount = files.first(where: {
            ($0.disabled != true) && ($0.provider.lowercased() == "codex" || $0.provider.lowercased() == "openai")
        }) else {
            throw ProviderError(.notConfigured)
        }

        let apiCallURL = managementURL(path: "api-call", base: config.url)
        var headers: [String: String] = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "OpenAI-Beta": "codex-1",
            "Originator": "Codex Desktop",
        ]
        if let accountId = codexAccount.idToken?.chatgptAccountId {
            headers["Chatgpt-Account-Id"] = accountId
        }

        let payload: [String: Any] = [
            "auth_index": codexAccount.authIndex,
            "method": "GET",
            "url": "https://chatgpt.com/backend-api/wham/usage",
            "header": headers,
        ]
        let requestBody = try JSONSerialization.data(withJSONObject: payload)
        let (apiCallData, apiCallResponse) = try await QuotaHTTP.post(
            url: apiCallURL,
            body: requestBody,
            headers: ["Content-Type": "application/json"],
            auth: .bearer(config.managementKey)
        )
        if let reason = QuotaHTTP.failureReason(for: apiCallResponse.statusCode) {
            throw ProviderError(reason)
        }

        let usage = try decodeCodexUsage(from: apiCallData)
        return (usage, codexAccount)
    }
}
