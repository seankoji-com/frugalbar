import Foundation

/// Only the published account AND organization identify a subscription. Email,
/// file name, nickname and auth-file order cannot establish equivalence.
struct ClaudeAccountProfile: Decodable, Sendable {
    static let endpoint = "https://api.anthropic.com/api/oauth/profile"
    struct Account: Decodable, Sendable { let uuid: String }
    struct Organization: Decodable, Sendable {
        let uuid: String
        let rateLimitTier: String?
        enum CodingKeys: String, CodingKey {
            case uuid
            case rateLimitTier = "rate_limit_tier"
        }
    }
    let account: Account
    let organization: Organization
    var instanceID: String {
        ClaudeAccount.instanceID(identity: "account|\(account.uuid.lowercased())|\(organization.uuid.lowercased())")
    }
    var planName: String? {
        organization.rateLimitTier.flatMap(CredentialStore.claudePlanName(fromRateLimitTier:))
    }
    static func decode(_ data: Data) throws -> Self {
        guard let profile = try? JSONDecoder().decode(Self.self, from: data),
              UUID(uuidString: profile.account.uuid) != nil,
              UUID(uuidString: profile.organization.uuid) != nil else { throw ProviderError.badResponse }
        return profile
    }
    static func fetch(token: String) async throws -> Self {
        let (data, response) = try await QuotaHTTP.get(url: endpoint,
            headers: ["Accept": "application/json", "anthropic-beta": "oauth-2025-04-20",
                      "User-Agent": CLIProxyClient.claudeCLIUserAgent], auth: .bearer(token))
        if let reason = QuotaHTTP.failureReason(for: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After")) { throw ProviderError(reason) }
        return try decode(data)
    }
}

private struct ClaudeAccountBinding: Codable, Sendable {
    let source: String
    let accountID: String
    let verified: Bool
}

/// A route is transient and never encoded. Only its opaque source key and safe
/// descriptor enter preferences. Credentials are not exposed to the UI.
struct ClaudeAccountRoute: Sendable {
    let source: String
    let sourceLabel: String
    let token: String?
    let proxy: CLIProxyConfig?
    let authFile: CLIProxyAuthFile?
    let plan: String?
    let nickname: String?
    let failure: UnavailableReason?
    let profile: ClaudeAccountProfile?
}

actor ClaudeAccountDiscovery {
    static let shared = ClaudeAccountDiscovery()
    private static let bindingsKey = "QuotaBarClaudeAccountBindings"
    private let defaults: UserDefaults
    private let proxyConfig: @Sendable () -> CLIProxyConfig?
    private let directCredential: @Sendable () async -> String?
    private let directPlan: @Sendable () async -> String?
    private let profileCredential: @Sendable (String) async -> Data?
    private let backoff: ClaudeProxyBackoff
    private let grants: ClaudeGrantSchedule
    private var profileWaits: [String: (until: Date, reason: UnavailableReason)] = [:]

    init(defaults: UserDefaults = CredentialStore.preferences,
                proxyConfig: @escaping @Sendable () -> CLIProxyConfig? = {
                    TestHost.isActive ? nil : CLIProxyClient.discoverConfig()
                },
                directCredential: @escaping @Sendable () async -> String? = {
                    TestHost.isActive ? nil : await CredentialStore.apiKeyAsync(for: .claude)
                },
                directPlan: @escaping @Sendable () async -> String? = {
                    TestHost.isActive ? nil : await CredentialStore.claudePlanNameAsync()
                },
                profileCredential: @escaping @Sendable (String) async -> Data? = { path in
                    // Tests inject bytes explicitly. No ambient file or Keychain
                    // lookup may make a hermetic test depend on this Mac's login.
                    guard !TestHost.isActive else { return nil }
                    return await Task.detached(priority: .utility) {
                        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
                        defer { try? handle.close() }
                        // A credential blob is small. Bound malformed/incorrect
                        // files instead of pulling arbitrary logs into memory.
                        guard let bytes = try? handle.read(upToCount: 1_048_577), bytes.count <= 1_048_576
                        else { return nil }
                        return bytes
                    }.value
                },
                backoff: ClaudeProxyBackoff? = nil, grants: ClaudeGrantSchedule? = nil) {
        self.defaults = defaults; self.proxyConfig = proxyConfig
        self.directCredential = directCredential; self.directPlan = directPlan
        self.profileCredential = profileCredential
        self.backoff = backoff ?? (TestHost.isActive ? ClaudeProxyBackoff() : .shared)
        self.grants = grants ?? (TestHost.isActive ? ClaudeGrantSchedule() : .shared)
    }

    func providers(now: Date = Date()) async -> [any QuotaProvider] {
        let oldAccounts = ClaudeAccountStore.all(in: defaults)
        let oldBindings = defaults.data(forKey: Self.bindingsKey).flatMap {
            try? JSONDecoder().decode([ClaudeAccountBinding].self, from: $0)
        } ?? []
        let config = proxyConfig()
        let directToken = await directCredential().flatMap { $0.isEmpty ? nil : $0 }
        var routes: [ClaudeAccountRoute] = []
        // Discovery failures preserve the identity of known rows; they never
        // fall back to a different account selected by the hub or local CLI.
        var unavailableBindings: [(ClaudeAccountBinding, UnavailableReason)] = []
        var proxyInventoryFailed = false
        var inventoryFailure: UnavailableReason?
        if let config {
            do {
                let files = try await CLIProxyClient.fetchAuthFiles(config: config, now: now)
                let prefix = Self.proxySourcePrefix(config)
                let enabled = files.filter {
                    $0.provider.lowercased() == "claude" && $0.disabled != true && !$0.authIndex.isEmpty
                }.sorted { ($0.id ?? $0.authIndex, $0.authIndex) < ($1.id ?? $1.authIndex, $1.authIndex) }
                var seen = Set<String>()
                for file in enabled where seen.insert(file.authIndex).inserted {
                    routes.append(ClaudeAccountRoute(source: prefix + ClaudeAccount.digest(file.id ?? file.authIndex),
                        sourceLabel: "CLI Proxy (\(config.url.host ?? "configured host"))", token: nil,
                        proxy: config, authFile: file, plan: nil, nickname: nil, failure: nil, profile: nil))
                }
            } catch {
                proxyInventoryFailed = true
                let reason = unavailableReason(for: error)
                inventoryFailure = reason
                unavailableBindings += oldBindings.filter { $0.source.hasPrefix(Self.proxySourcePrefix(config)) }
                    .map { ($0, reason) }
            }
        }
        if let token = directToken {
            routes.append(ClaudeAccountRoute(source: "direct|" + ClaudeAccount.digest(token),
                sourceLabel: "This Mac's Claude Code session", token: token, proxy: nil, authFile: nil,
                plan: await directPlan(), nickname: nil, failure: nil, profile: nil))
        }
        for source in ClaudeAccountStore.profileSources(in: defaults) where source.isEnabled {
            let data = await profileCredential(source.path)
            let token = CredentialStore.claudeOAuthToken(from: data)
            routes.append(ClaudeAccountRoute(source: "profile|" + source.id,
                sourceLabel: "Saved profile (\(URL(fileURLWithPath: source.path).deletingLastPathComponent().lastPathComponent))",
                token: token, proxy: nil, authFile: nil, plan: CredentialStore.claudePlanName(from: data),
                nickname: source.nickname, failure: token == nil ? .notConfigured : nil, profile: nil))
        }
        // Profile reads are independent. A slow or rejected account cannot
        // prevent another account's identity being resolved.
        let waits = profileWaits
        let userInitiated = QuotaFetchContext.isUserInitiated
        let discovered = await withTaskGroup(of: ClaudeAccountRoute.self, returning: [ClaudeAccountRoute].self) { group in
            for route in routes {
                group.addTask {
                    guard route.failure == nil else { return route }
                    let profile: ClaudeAccountProfile?
                    var failure: UnavailableReason?
                    do {
                        if !userInitiated, let wait = waits[route.source], now < wait.until {
                            throw ProviderError(wait.reason)
                        }
                        if let config = route.proxy, let file = route.authFile {
                            profile = try await CLIProxyClient.fetchClaudeProfile(config: config, account: file, now: now)
                        } else if let token = route.token {
                            profile = try await ClaudeAccountProfile.fetch(token: token)
                        } else { profile = nil }
                    } catch {
                        profile = nil
                        // An identity endpoint's unavailable shape need not
                        // prevent a first unknown source's usage read, but an
                        // explicit rejection or throttle must be respected.
                        let reason = unavailableReason(for: error)
                        switch reason {
                        case .rateLimited, .credentialRejected: failure = reason
                        default: break
                        }
                    }
                    return ClaudeAccountRoute(source: route.source, sourceLabel: route.sourceLabel,
                        token: route.token, proxy: route.proxy, authFile: route.authFile,
                        plan: profile?.planName ?? route.plan, nickname: route.nickname,
                        failure: failure, profile: profile)
                }
            }
            var result: [ClaudeAccountRoute] = []
            for await route in group { result.append(route) }
            return result.sorted { $0.source < $1.source }
        }
        guard !Task.isCancelled else { return [] }
        var groups: [String: [ClaudeAccountRoute]] = [:]
        var bindings: [ClaudeAccountBinding] = []
        for route in discovered {
            if case .rateLimited(let until)? = route.failure, let until {
                profileWaits[route.source] = (until, route.failure!)
            } else if route.profile != nil { profileWaits[route.source] = nil }
            let previous = oldBindings.first { $0.source == route.source }
            let id = route.profile?.instanceID ?? previous?.accountID
                ?? ClaudeAccount.instanceID(identity: "source|" + route.source)
            let verified = route.profile != nil || previous?.verified == true
            bindings.append(ClaudeAccountBinding(source: route.source, accountID: id, verified: verified))
            if route.profile == nil, previous?.verified == true {
                // A previously verified source cannot publish fresh quota under
                // that name until its current credential identifies itself.
                unavailableBindings.append((ClaudeAccountBinding(source: route.source, accountID: id, verified: true),
                    route.failure ?? .badResponse))
            } else {
                groups[id, default: []].append(route)
            }
        }
        for (binding, _) in unavailableBindings where !bindings.contains(where: { $0.source == binding.source }) {
            bindings.append(binding)
        }
        var descriptors = groups.map { id, routes in
            ClaudeAccount(id: id, badge: "", sourceLabel: routes.map(\.sourceLabel).sorted().joined(separator: " · "),
                fallbackName: routes.allSatisfy { $0.source.hasPrefix("direct|") } ? "This Mac" : "Account",
                nickname: routes.compactMap(\.nickname).first,
                planName: routes.compactMap(\.plan).first)
        }
        for (binding, _) in unavailableBindings where groups[binding.accountID] == nil {
            if let old = oldAccounts.first(where: { $0.id == binding.accountID }),
               !descriptors.contains(where: { $0.id == old.id }) { descriptors.append(old) }
        }
        if descriptors.isEmpty {
            // Preserve the original unconfigured/direct behavior when no
            // independent source exists. An inventory outage must not select
            // an arbitrary account from a named row.
            if !proxyInventoryFailed { _ = ClaudeAccountStore.saveDiscovered([], in: defaults) }
            if let inventoryFailure { return [ClaudeDiscoveryFailureProvider(reason: inventoryFailure)] }
            return [ClaudeQuotaProvider(apiKey: "", directCredential: { nil })]
        }
        let accounts = ClaudeAccountStore.saveDiscovered(descriptors, in: defaults)
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.bindingsKey) }
        return accounts.map { account in
            ClaudeAccountQuotaProvider(account: account, routes: groups[account.id] ?? [],
                failure: unavailableBindings.first { $0.0.accountID == account.id }?.1,
                backoff: backoff, grants: grants)
        }
    }

    private static func proxySourcePrefix(_ config: CLIProxyConfig) -> String {
        "proxy|" + ClaudeAccount.digest(config.url.absoluteString) + "|"
    }
}

private struct ClaudeDiscoveryFailureProvider: QuotaProvider {
    let reason: UnavailableReason
    var vendorId: VendorIdentifier { .claude }
    var displayName: String { "Claude" }
    var category: MetricCategory { .aiSubscriptions }
    func fetchSnapshot() async throws -> QuotaSnapshot { unavailable(reason) }
}

/// Fallback is permitted only between routes whose published account and
/// organization matched. Unknown sources always receive separate instance ids.
struct ClaudeAccountQuotaProvider: QuotaProvider {
    let account: ClaudeAccount
    let routes: [ClaudeAccountRoute]
    let failure: UnavailableReason?
    let backoff: ClaudeProxyBackoff
    let grants: ClaudeGrantSchedule
    var vendorId: VendorIdentifier { .claude }
    var displayName: String { account.name }
    var category: MetricCategory { .aiSubscriptions }
    var instanceID: String { account.id }

    func fetchSnapshot() async throws -> QuotaSnapshot {
        var firstFailure = failure
        for route in routes.sorted(by: { ($0.proxy == nil ? 1 : 0) < ($1.proxy == nil ? 1 : 0) }) {
            if let reason = route.failure { firstFailure = firstFailure ?? reason; continue }
            let provider = ClaudeQuotaProvider(apiKey: route.proxy == nil ? route.token : nil,
                cliProxyConfig: route.proxy, directCredential: { nil }, proxyBackoff: backoff,
                grantSchedule: grants, monthlyCredit: { _ in nil }, account: account,
                proxyAccount: route.authFile)
            do {
                let snapshot = try await provider.fetchSnapshot()
                if snapshot.status.confidence == .measured { return snapshot }
                firstFailure = firstFailure ?? snapshot.status.unavailableReason
            } catch { firstFailure = firstFailure ?? unavailableReason(for: error) }
        }
        var snapshot = unavailable(firstFailure ?? .notConfigured)
        snapshot.claudeAccount = account
        snapshot.planName = account.planName
        return snapshot
    }
}
