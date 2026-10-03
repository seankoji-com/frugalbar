import Foundation

/// Reads the models each subscription's own account can select right now.
///
/// Every list here is the one the vendor's own CLI reads to build its model
/// picker, fetched with the credential FrugalBar already uses for that
/// vendor's quota — never a public catalog. Each was checked against the live
/// API with a real account on 3 Oct 2026 unless its note says otherwise.
///
/// A nil result means the list could not be read (no credential, offline,
/// rejected, an unexpected shape); the watcher then changes nothing. Parsers
/// are separate from fetchers so the decisions — which entries count as
/// selectable — are tested without the network.
///
/// Not listed:
/// - Command Code serves no model list: its CLI decides access from a table
///   compiled into the client, so a model "appears" only when the CLI ships.
/// - OpenRouter is pay-as-you-go, not a subscription, and lists ~460 models
///   from every lab; its new listings are the catalog news this feature
///   deliberately leaves out.
public enum AccountModelLister {

    /// The vendors with an account-scoped model list FrugalBar can read.
    public static let supportedVendors: [VendorIdentifier] = [
        .claude, .openai, .gemini, .copilot, .opencode, .kiro, .grok, .devpass, .clinepass,
    ]

    /// The product the user picks the model in, for "now available in …".
    public static func productName(_ vendor: VendorIdentifier) -> String {
        switch vendor {
        case .openai:   "Codex"
        case .opencode: "OpenCode Go"
        default:        vendor.displayName
        }
    }

    /// The production lister. Never touches the network under a test host.
    public static func live(_ vendor: VendorIdentifier) async -> [AccountModel]? {
        guard !TestHost.isActive else { return nil }
        switch vendor {
        case .claude:    return await claude()
        case .openai:    return await codex()
        case .gemini:    return await gemini()
        case .copilot:   return await copilot()
        case .opencode:  return await openCodeGo()
        case .kiro:      return await kiro()
        case .grok:      return await grok()
        case .devpass:   return await devPass()
        case .clinepass: return await clinePass()
        default:         return nil
        }
    }

    // MARK: - Shared

    /// A GET whose body is returned only for a 2xx.
    private static func get(_ url: String, headers: [String: String] = [:], auth: QuotaHTTP.Auth) async -> Data? {
        var allHeaders = ["Accept": "application/json"]
        allHeaders.merge(headers) { _, new in new }
        guard let (data, http) = try? await QuotaHTTP.get(url: url, headers: allHeaders, auth: auth),
              QuotaHTTP.failureReason(for: http.statusCode) == nil
        else { return nil }
        return data
    }

    private static func post(_ url: String, body: Data, headers: [String: String], auth: QuotaHTTP.Auth = .none) async -> Data? {
        guard let (data, http) = try? await QuotaHTTP.post(url: url, body: body, headers: headers, auth: auth),
              QuotaHTTP.failureReason(for: http.statusCode) == nil
        else { return nil }
        return data
    }

    private static func key(_ vendor: VendorIdentifier) async -> String? {
        let key = await CredentialStore.apiKeyAsync(for: vendor)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    /// `{"data": [{"id", "name"?}]}` — the OpenAI-style list several vendors
    /// serve.
    private struct IdList: Decodable {
        struct Entry: Decodable {
            let id: String?
            let name: String?
            let display_name: String?
            let deactivated_at: String?
        }
        let data: [Entry]
    }

    static func parseIdList(_ data: Data) -> [AccountModel]? {
        guard let list = try? JSONDecoder().decode(IdList.self, from: data) else { return nil }
        return list.data.compactMap { entry in
            guard let id = entry.id, !id.isEmpty, entry.deactivated_at == nil else { return nil }
            return AccountModel(id: id, name: entry.display_name ?? entry.name)
        }
    }

    // MARK: - Claude

    /// Claude Code's own bootstrap call: `model_access` lists every model with
    /// whether this account is `entitled` to it.
    ///
    /// Read from the Claude Code 2.1.286 binary; not exercised live (the
    /// OAuth token sits in the Keychain), so any failure here is a nil list.
    static let claudeBootstrapURL = "https://api.anthropic.com/api/claude_cli/bootstrap"

    private struct ClaudeBootstrap: Decodable {
        struct Access: Decodable {
            let api_name: String?
            let entitled: Bool?
        }
        struct Option: Decodable {
            let model: String?
            let name: String?
        }
        let model_access: [Access]?
        let additional_model_options: [Option]?
    }

    static func parseClaudeBootstrap(_ data: Data) -> [AccountModel]? {
        guard let boot = try? JSONDecoder().decode(ClaudeBootstrap.self, from: data),
              let access = boot.model_access
        else { return nil }
        let names = Dictionary(
            (boot.additional_model_options ?? []).compactMap { option in
                option.model.flatMap { model in option.name.map { (model, $0) } }
            },
            uniquingKeysWith: { first, _ in first })
        return access.compactMap { entry in
            guard entry.entitled == true, let id = entry.api_name, !id.isEmpty else { return nil }
            return AccountModel(id: id, name: names[id])
        }
    }

    private static func claude() async -> [AccountModel]? {
        guard let token = await key(.claude),
              let data = await get(claudeBootstrapURL,
                                   headers: ["anthropic-beta": "oauth-2025-04-20"], auth: .bearer(token))
        else { return nil }
        return parseClaudeBootstrap(data)
    }

    // MARK: - Codex

    /// Codex's picker: `GET chatgpt.com/backend-api/codex/models`. The list is
    /// gated on `client_version` — an old version gets fewer models — so the
    /// version sent is the latest released Codex CLI, read from npm. A model
    /// that appears is then one the current Codex release can select, not one
    /// that merely became visible because a version number moved.
    static let codexModelsURL = "https://chatgpt.com/backend-api/codex/models"
    static let codexReleaseURL = "https://registry.npmjs.org/@openai/codex/latest"

    private struct CodexModels: Decodable {
        struct Model: Decodable {
            let slug: String?
            let display_name: String?
            let visibility: String?
        }
        let models: [Model]
    }

    /// Only `visibility == "list"` models are in the picker; hidden ones
    /// (`gpt-reserve`, `codex-auto-review`) are internal.
    static func parseCodexModels(_ data: Data) -> [AccountModel]? {
        guard let list = try? JSONDecoder().decode(CodexModels.self, from: data) else { return nil }
        return list.models.compactMap { model in
            guard model.visibility == "list", let slug = model.slug, !slug.isEmpty else { return nil }
            return AccountModel(id: slug, name: model.display_name)
        }
    }

    private struct NPMRelease: Decodable { let version: String }

    /// The version the CLI's own cache recorded, when npm cannot be reached.
    private struct CodexCache: Decodable { let client_version: String? }

    private static func codexClientVersion() async -> String? {
        if let data = await get(codexReleaseURL, auth: .none),
           let release = try? JSONDecoder().decode(NPMRelease.self, from: data),
           !release.version.isEmpty {
            return release.version
        }
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: cache) else { return nil }
        return (try? JSONDecoder().decode(CodexCache.self, from: data))?.client_version
    }

    private static func codex() async -> [AccountModel]? {
        guard let token = await key(.openai),
              let version = await codexClientVersion(),
              var components = URLComponents(string: codexModelsURL)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "client_version", value: version)]
        guard let url = components.url?.absoluteString,
              let data = await get(url, auth: .bearer(token))
        else { return nil }
        return parseCodexModels(data)
    }

    // MARK: - Gemini

    /// Antigravity's `fetchAvailableModels`, a map keyed by model id, for the
    /// Code Assist project `loadCodeAssist` names.
    ///
    /// Not exercised live (both local tokens had expired). Internal ids the
    /// picker never offers — tab completion, chat routing, review, image and
    /// query helpers — are dropped, per the published community client.
    private struct GeminiModels: Decodable {
        struct Model: Decodable { let displayName: String? }
        let models: [String: Model]
    }

    private struct CodeAssistProject: Decodable { let cloudaicompanionProject: String? }

    static func parseGeminiModels(_ data: Data) -> [AccountModel]? {
        guard let list = try? JSONDecoder().decode(GeminiModels.self, from: data) else { return nil }
        return list.models
            .filter { id, _ in
                let lower = id.lowercased()
                return !["chat_", "tab_", "rev_"].contains { lower.hasPrefix($0) }
                    && !["image", "mquery", "lite"].contains { lower.contains($0) }
            }
            .map { AccountModel(id: $0.key, name: $0.value.displayName) }
            .sorted { $0.id < $1.id }
    }

    private static func gemini() async -> [AccountModel]? {
        var token = await GeminiOAuthSession.loadRefreshed()?.accessToken
        if token?.isEmpty ?? true { token = await CredentialStore.antigravityAccessTokenAsync() }
        guard let token, !token.isEmpty else { return nil }
        let base = GeminiQuotaProvider.productionAPIBase
        let headers = ["User-Agent": "antigravity", "Content-Type": "application/json"]
        guard let assistBody = try? JSONEncoder().encode(
                ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]),
              let assist = await post(base + "loadCodeAssist", body: assistBody, headers: headers, auth: .bearer(token)),
              let project = (try? JSONDecoder().decode(CodeAssistProject.self, from: assist))?.cloudaicompanionProject,
              let body = try? JSONEncoder().encode(["project": project]),
              let data = await post(base + "fetchAvailableModels", body: body, headers: headers, auth: .bearer(token))
        else { return nil }
        return parseGeminiModels(data)
    }

    // MARK: - GitHub Copilot

    /// `GET api.githubcopilot.com/models` with the GitHub OAuth token: every
    /// model with whether it is in this account's picker.
    static let copilotModelsURL = "https://api.githubcopilot.com/models"

    private struct CopilotModels: Decodable {
        struct Model: Decodable {
            struct Policy: Decodable { let state: String? }
            struct Capabilities: Decodable { let type: String? }
            let id: String?
            let name: String?
            let model_picker_enabled: Bool?
            let policy: Policy?
            let capabilities: Capabilities?
        }
        let data: [Model]
    }

    /// Selectable: in the picker, a chat model, and not disabled by policy.
    /// `policy` is absent on some picker models, so it is not required.
    static func parseCopilotModels(_ data: Data) -> [AccountModel]? {
        guard let list = try? JSONDecoder().decode(CopilotModels.self, from: data) else { return nil }
        return list.data.compactMap { model in
            guard model.model_picker_enabled == true,
                  model.capabilities?.type == "chat",
                  model.policy?.state != "disabled",
                  let id = model.id, !id.isEmpty
            else { return nil }
            return AccountModel(id: id, name: model.name)
        }
    }

    private static func copilot() async -> [AccountModel]? {
        guard let token = await key(.copilot),
              let data = await get(copilotModelsURL, auth: .bearer(token))
        else { return nil }
        return parseCopilotModels(data)
    }

    // MARK: - OpenCode Go

    /// Filtered to the workspace when authenticated (36 ids against 43
    /// public), so the request always carries the key.
    static let openCodeGoModelsURL = "https://opencode.ai/zen/go/v1/models"

    private static func openCodeGo() async -> [AccountModel]? {
        guard let key = await key(.opencode),
              let data = await get(openCodeGoModelsURL, auth: .bearer(key))
        else { return nil }
        return parseIdList(data)
    }

    // MARK: - Kiro

    /// `ListAvailableModels` on the same AWS JSON endpoint and identity as the
    /// quota call. `origin` is required: without it the call is a 400.
    static let kiroTarget = "AmazonCodeWhispererService.ListAvailableModels"

    private struct KiroModels: Decodable {
        struct Model: Decodable {
            let modelId: String?
            let modelName: String?
        }
        let models: [Model]
    }

    static func parseKiroModels(_ data: Data) -> [AccountModel]? {
        guard let list = try? JSONDecoder().decode(KiroModels.self, from: data) else { return nil }
        return list.models.compactMap { model in
            guard let id = model.modelId, !id.isEmpty else { return nil }
            return AccountModel(id: id, name: model.modelName)
        }
    }

    private static func kiro() async -> [AccountModel]? {
        // Reading the CLI's database is credential discovery, behind the opt-in.
        guard CredentialStore.isCLIDiscoveryEnabled,
              case .found(let identity) = await KiroQuotaProvider.readIdentityAsync(
                databaseURL: KiroQuotaProvider.stateDatabaseURL()),
              let body = try? JSONSerialization.data(
                withJSONObject: ["profileArn": identity.profileARN, "origin": "KIRO_CLI"]),
              let data = await post(KiroQuotaProvider.endpoint, body: body, headers: [
                "Content-Type": KiroQuotaProvider.contentType,
                "X-Amz-Target": kiroTarget,
                "Authorization": "Bearer \(identity.accessToken)",
              ])
        else { return nil }
        return parseKiroModels(data)
    }

    // MARK: - Grok

    static let grokModelsURL = "https://cli-chat-proxy.grok.com/v1/models"

    private static func grok() async -> [AccountModel]? {
        guard let token = await key(.grok),
              let data = await get(
                grokModelsURL,
                headers: [GrokQuotaProvider.clientHeader.name: GrokQuotaProvider.clientHeader.value],
                auth: .bearer(token))
        else { return nil }
        return parseIdList(data)
    }

    // MARK: - DevPass

    /// LLM Gateway's model list is scoped to the key: 145 ids with a DevPass
    /// key against 297 public.
    static let devPassModelsURL = "https://api.llmgateway.io/v1/models"

    private static func devPass() async -> [AccountModel]? {
        guard let key = await key(.devpass),
              let data = await get(devPassModelsURL, auth: .bearer(key))
        else { return nil }
        return parseIdList(data)
    }

    // MARK: - ClinePass

    /// Cline serves the ClinePass model list as a plan catalogue, the same for
    /// every caller, so it counts only when the account's own plan says
    /// ClinePass is enabled.
    static let clinePlanURL = "https://api.cline.bot/api/v1/users/me/plan"
    static let clineModelsURL = "https://api.cline.bot/api/v1/ai/cline/recommended-models"

    private struct ClinePlan: Decodable {
        struct Inner: Decodable {
            struct Plan: Decodable {
                struct Entitlements: Decodable {
                    struct Pass: Decodable { let enabled: Bool? }
                    let cline_pass: Pass?
                }
                let entitlements: Entitlements?
            }
            let plan: Plan?
        }
        let data: Inner?
    }

    static func clinePassEnabled(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(ClinePlan.self, from: data))?.data?.plan?.entitlements?.cline_pass?.enabled == true
    }

    private struct ClineModels: Decodable {
        struct Model: Decodable { let id: String? }
        struct Lists: Decodable { let clinePass: [Model]? }
        let clinePass: [Model]?
        let data: Lists?
    }

    static func parseClinePassModels(_ data: Data) -> [AccountModel]? {
        guard let lists = try? JSONDecoder().decode(ClineModels.self, from: data),
              let models = lists.data?.clinePass ?? lists.clinePass
        else { return nil }
        return models.compactMap { model in
            guard let id = model.id, !id.isEmpty else { return nil }
            return AccountModel(id: id, name: nil)
        }
    }

    private static func clinePass() async -> [AccountModel]? {
        guard let key = await key(.clinepass) else { return nil }
        // The same credential handling as the quota call: a pasted account
        // token may lack the `workos:` prefix the API wants.
        let prefix = ClinePassQuotaProvider.workosPrefix
        var credential = key
        var plan = await get(clinePlanURL, auth: .bearer(credential))
        if plan == nil, !key.lowercased().hasPrefix(prefix) {
            credential = prefix + key
            plan = await get(clinePlanURL, auth: .bearer(credential))
        }
        guard let plan, clinePassEnabled(plan),
              let data = await get(clineModelsURL, auth: .bearer(credential))
        else { return nil }
        return parseClinePassModels(data)
    }
}
