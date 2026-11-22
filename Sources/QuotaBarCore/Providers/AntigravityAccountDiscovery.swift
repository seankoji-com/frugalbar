import Foundation

private struct AntigravityAccountBinding: Codable, Sendable {
    let source: String
    let accountID: String
    let verified: Bool
    var identity: String? = nil
}

/// A route is transient and never encoded. Only its opaque source key and safe
/// descriptor enter preferences. Credentials are never exposed to the UI.
struct AntigravityAccountRoute: Sendable {
    let source: String
    let sourceLabel: String
    let isPrimary: Bool
    let accessToken: String?
    let proxy: CLIProxyConfig?
    let authFile: CLIProxyAuthFile?
    let projectID: String?
    let planName: String?
    let failure: UnavailableReason?

    var verifiedIdentity: String? {
        guard let projectID, !projectID.isEmpty else { return nil }
        return AntigravityAccount.instanceID(identity: "project|\(projectID)")
    }

    var transport: GeminiQuotaProvider.Transport? {
        if let proxy, let authFile {
            return .proxy(config: proxy, account: authFile, batchKey: source)
        }
        if let accessToken, !accessToken.isEmpty {
            return .direct(accessToken: accessToken, batchKey: source)
        }
        return nil
    }
}

actor AntigravityAccountDiscovery {
    static let shared = AntigravityAccountDiscovery()
    private static let bindingsKey = "QuotaBarAntigravityAccountBindings"

    private let defaults: UserDefaults
    private let proxyConfig: @Sendable () -> CLIProxyConfig?
    private let directCredential: @Sendable () async -> String?
    private let apiBases: [String]

    private struct CachedPlan {
        let accounts: [AntigravityAccount]
        let routesByAccountID: [String: [AntigravityAccountRoute]]
        let failureByAccountID: [String: UnavailableReason]
        let fallbackProviders: Bool
        let inventoryFailure: UnavailableReason?
    }

    private var cachedPlan: CachedPlan?
    private var discoverySignature: String?
    private var lastDiscoveryAt: Date?
    private var lastUserDiscoveryAt: Date?

    init(
        defaultsSuiteName: String? = nil,
        proxyConfig: @escaping @Sendable () -> CLIProxyConfig? = {
            TestHost.isActive ? nil : CLIProxyClient.discoverConfig()
        },
        directCredential: @escaping @Sendable () async -> String? = {
            guard !TestHost.isActive else { return nil }
            if let session = await GeminiOAuthSession.loadRefreshed() { return session.accessToken }
            return await CredentialStore.antigravityAccessTokenAsync()
        },
        apiBases: [String]? = nil
    ) {
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? CredentialStore.preferences
        self.proxyConfig = proxyConfig
        self.directCredential = directCredential
        self.apiBases = apiBases ?? GeminiQuotaProvider.productionAPIHosts
    }

    func providers(now: Date = Date()) async -> [any QuotaProvider] {
        let oldAccounts = AntigravityAccountStore.all(in: defaults)
        let oldBindings = defaults.data(forKey: Self.bindingsKey).flatMap {
            try? JSONDecoder().decode([AntigravityAccountBinding].self, from: $0)
        } ?? []
        let config = proxyConfig()
        let directToken = await directCredential().flatMap { $0.isEmpty ? nil : $0 }
        let names = defaults.dictionary(forKey: AntigravityAccountStore.nicknamesKey) as? [String: String] ?? [:]
        let signature = AntigravityAccount.digest(
            (config?.url.absoluteString ?? "") + "|"
                + (config?.managementKey ?? "") + "|"
                + (directToken ?? "") + "|"
                + names.keys.sorted().map { $0 + "=" + names[$0]! }.joined(separator: "|")
        )
        let userInitiated = QuotaFetchContext.isUserInitiated
        let measuredFrom = userInitiated ? lastUserDiscoveryAt : lastDiscoveryAt
        if signature == discoverySignature,
           let cachedPlan,
           let measuredFrom,
           now.timeIntervalSince(measuredFrom) < 30 {
            // Always construct a fresh per-pass batch so quota responses are
            // never cached across refreshes.
            return makeProviders(from: cachedPlan, batch: AntigravityRequestBatch())
        }

        let batch = AntigravityRequestBatch()
        var routes: [AntigravityAccountRoute] = []
        var unavailableBindings: [(AntigravityAccountBinding, UnavailableReason)] = []
        var proxyInventoryFailed = false
        var inventoryFailure: UnavailableReason?

        if let token = directToken {
            routes.append(AntigravityAccountRoute(
                source: "direct|" + AntigravityAccount.digest(token),
                sourceLabel: "This Mac's Google OAuth session",
                isPrimary: true,
                accessToken: token,
                proxy: nil,
                authFile: nil,
                projectID: nil,
                planName: nil,
                failure: nil
            ))
        }

        if let config {
            do {
                let files = try await CLIProxyClient.fetchAuthFiles(config: config, now: now)
                let prefix = Self.proxySourcePrefix(config)
                let enabled = files.filter {
                    $0.provider.lowercased() == "antigravity"
                        && $0.disabled != true
                        && !$0.authIndex.isEmpty
                }.sorted { ($0.id ?? $0.authIndex, $0.authIndex) < ($1.id ?? $1.authIndex, $1.authIndex) }
                let fileIndices = Dictionary(grouping: enabled, by: { $0.id ?? "" })
                    .mapValues { Set($0.map(\.authIndex)) }
                var seen = Set<String>()
                for file in enabled where seen.insert(file.authIndex).inserted {
                    let hint = Self.safeAccountHint(file.email).map { " · " + $0 } ?? ""
                    let sourceID: String
                    if let id = file.id, !id.isEmpty, fileIndices[id]?.count == 1 {
                        sourceID = "file|" + id
                    } else {
                        sourceID = "index|" + file.authIndex
                    }
                    routes.append(AntigravityAccountRoute(
                        source: prefix + AntigravityAccount.digest(sourceID),
                        sourceLabel: "CLI Proxy (\(config.url.host ?? "configured host"))" + hint,
                        isPrimary: false,
                        accessToken: nil,
                        proxy: config,
                        authFile: file,
                        projectID: nil,
                        planName: nil,
                        failure: nil
                    ))
                }
            } catch {
                proxyInventoryFailed = true
                let reason = unavailableReason(for: error)
                inventoryFailure = reason
                let activeIDs = Set(oldAccounts.map(\.id))
                unavailableBindings += oldBindings.filter {
                    $0.source.hasPrefix(Self.proxySourcePrefix(config)) && activeIDs.contains($0.accountID)
                }.map { ($0, reason) }
            }
        }

        // Probe loadCodeAssist concurrently per route using the shared pass batch
        // so the pool providers reuse the exact same response with no extra calls.
        let bases = self.apiBases
        let discovered = await withTaskGroup(of: AntigravityAccountRoute.self, returning: [AntigravityAccountRoute].self) { group in
            for route in routes {
                group.addTask {
                    await Self.probeIdentity(route: route, bases: bases, batch: batch, now: now)
                }
            }
            var result: [AntigravityAccountRoute] = []
            for await route in group { result.append(route) }
            return result.sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                return lhs.source < rhs.source
            }
        }
        guard !Task.isCancelled else { return [] }

        var groups: [String: [AntigravityAccountRoute]] = [:]
        var bindings: [AntigravityAccountBinding] = []
        var identities: [String: String] = [:]
        for binding in oldBindings {
            if let identity = binding.identity { identities[identity] = binding.accountID }
        }

        let verifiedGroups = Dictionary(
            grouping: discovered.filter { $0.verifiedIdentity != nil },
            by: { $0.verifiedIdentity! }
        )
        let badges = defaults.dictionary(forKey: AntigravityAccountStore.badgesKey) as? [String: String] ?? [:]
        for (identity, matchingRoutes) in verifiedGroups where identities[identity] == nil {
            let candidates = matchingRoutes.compactMap { route in
                oldBindings.first { $0.source == route.source && !$0.verified }?.accountID
            }
            let previousID = candidates.min {
                (Int(badges[$0] ?? "") ?? Int.max, $0) < (Int(badges[$1] ?? "") ?? Int.max, $1)
            }
            identities[identity] = previousID ?? identity
        }

        var aliases: [String: Set<String>] = [:]
        for route in discovered {
            let previous = oldBindings.first { $0.source == route.source }
            let identity = route.verifiedIdentity
            let id = identity.flatMap { identities[$0] } ?? previous?.accountID
                ?? AntigravityAccount.instanceID(identity: "source|" + route.source)
            let verified = identity != nil || previous?.verified == true
            bindings.append(AntigravityAccountBinding(
                source: route.source,
                accountID: id,
                verified: verified,
                identity: identity ?? previous?.identity
            ))
            if let identity, let previous, previous.accountID != id,
               !previous.verified || previous.identity == identity {
                aliases[id, default: []].insert(previous.accountID)
                if let old = oldAccounts.first(where: { $0.id == previous.accountID }) {
                    aliases[id, default: []].formUnion(old.historyAliases)
                }
            }
            groups[id, default: []].append(route)
        }

        for (binding, _) in unavailableBindings where !bindings.contains(where: { $0.source == binding.source }) {
            bindings.append(binding)
        }

        var descriptors = groups.map { id, groupRoutes -> AntigravityAccount in
            let isPrimary = groupRoutes.contains(where: \.isPrimary)
            return AntigravityAccount(
                id: id,
                badge: "",
                sourceLabel: groupRoutes.map(\.sourceLabel).sorted().joined(separator: " · "),
                fallbackName: isPrimary ? "This Mac" : "Account",
                planName: groupRoutes.compactMap(\.planName).first,
                isPrimary: isPrimary,
                historyAliases: Set(oldAccounts.first { $0.id == id }?.historyAliases ?? [])
                    .union(aliases[id] ?? []).sorted()
            )
        }
        for (binding, _) in unavailableBindings where groups[binding.accountID] == nil {
            if let old = oldAccounts.first(where: { $0.id == binding.accountID }),
               !descriptors.contains(where: { $0.id == old.id }) {
                descriptors.append(old)
            }
        }

        if descriptors.isEmpty {
            if !proxyInventoryFailed { _ = AntigravityAccountStore.saveDiscovered([], in: defaults) }
            let plan = CachedPlan(
                accounts: [],
                routesByAccountID: [:],
                failureByAccountID: [:],
                fallbackProviders: inventoryFailure == nil,
                inventoryFailure: inventoryFailure
            )
            return remember(plan, batch: batch, signature: signature, now: now, userInitiated: userInitiated)
        }

        let accounts = AntigravityAccountStore.saveDiscovered(descriptors, in: defaults)
        let currentSources = Set(bindings.map(\.source))
        bindings += oldBindings.filter { !currentSources.contains($0.source) }
        if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: Self.bindingsKey)
        }

        var failureByAccountID: [String: UnavailableReason] = [:]
        for (binding, reason) in unavailableBindings where failureByAccountID[binding.accountID] == nil {
            failureByAccountID[binding.accountID] = reason
        }
        let plan = CachedPlan(
            accounts: accounts,
            routesByAccountID: groups,
            failureByAccountID: failureByAccountID,
            fallbackProviders: false,
            inventoryFailure: nil
        )
        return remember(plan, batch: batch, signature: signature, now: now, userInitiated: userInitiated)
    }

    private func remember(
        _ plan: CachedPlan,
        batch: AntigravityRequestBatch,
        signature: String,
        now: Date,
        userInitiated: Bool
    ) -> [any QuotaProvider] {
        cachedPlan = plan
        discoverySignature = signature
        lastDiscoveryAt = now
        if userInitiated { lastUserDiscoveryAt = now }
        return makeProviders(from: plan, batch: batch)
    }

    private func makeProviders(
        from plan: CachedPlan,
        batch: AntigravityRequestBatch
    ) -> [any QuotaProvider] {
        let allowances: [GeminiQuotaProvider.Allowance] = [.gemini, .claude, .argon]
        if plan.accounts.isEmpty {
            if let reason = plan.inventoryFailure {
                return allowances.map { allowance in
                    AntigravityDiscoveryFailureProvider(allowance: allowance, reason: reason)
                }
            }
            return allowances.map { allowance in
                GeminiQuotaProvider(allowance: allowance, requests: batch)
            }
        }
        var result: [any QuotaProvider] = []
        for account in plan.accounts {
            // Direct primary route first so primary behaviour never changes,
            // with proxy fallback only when proven to be the same account.
            let routes = (plan.routesByAccountID[account.id] ?? []).sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                return lhs.source < rhs.source
            }
            let transports = routes.compactMap(\.transport)
            let initialFailure = plan.failureByAccountID[account.id] ?? routes.compactMap(\.failure).first
            for allowance in allowances {
                result.append(GeminiQuotaProvider(
                    account: account,
                    transports: transports,
                    initialFailure: transports.isEmpty ? initialFailure : nil,
                    apiBaseOverride: apiBases.count == 1 ? apiBases[0] : nil,
                    allowance: allowance,
                    requests: batch
                ))
            }
        }
        return result
    }

    private static func probeIdentity(
        route: AntigravityAccountRoute,
        bases: [String],
        batch: AntigravityRequestBatch,
        now: Date
    ) async -> AntigravityAccountRoute {
        guard let transport = route.transport else { return route }
        var resolvedProject: String?
        var resolvedPlan: String?
        var terminalFailure: UnavailableReason?
        for base in bases {
            do {
                let (data, http) = try await batch.response(
                    accountID: transport.batchKey, key: base + "assist"
                ) {
                    try await GeminiQuotaProvider.loadCodeAssist(
                        transport: transport, directToken: route.accessToken, base: base, now: now)
                }
                if let googleReason = GeminiQuotaProvider.googleErrorReason(statusCode: http.statusCode, data: data) {
                    terminalFailure = googleReason
                    break
                }
                if let reason = QuotaHTTP.failureReason(
                    for: http.statusCode,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                    now: now
                ) {
                    if reason == .credentialRejected {
                        terminalFailure = reason
                        break
                    }
                    continue
                }
                if let assist = try? JSONDecoder().decode(GeminiQuotaProvider.CodeAssist.self, from: data),
                   let project = assist.cloudaicompanionProject?.trimmed, !project.isEmpty {
                    resolvedProject = project
                    resolvedPlan = assist.planName
                    break
                }
            } catch let error as ProviderError {
                if error.reason == .credentialRejected {
                    terminalFailure = error.reason
                    break
                }
            } catch {
                // Network / transport errors leave identity unverified so this
                // source stays separate rather than merging with another account.
            }
        }
        return AntigravityAccountRoute(
            source: route.source,
            sourceLabel: route.sourceLabel,
            isPrimary: route.isPrimary,
            accessToken: route.accessToken,
            proxy: route.proxy,
            authFile: route.authFile,
            projectID: resolvedProject,
            planName: resolvedPlan,
            failure: terminalFailure
        )
    }

    private static func proxySourcePrefix(_ config: CLIProxyConfig) -> String {
        "proxy|" + AntigravityAccount.digest(config.url.absoluteString) + "|"
    }

    private static func safeAccountHint(_ value: String?) -> String? {
        guard let value = value?.trimmed, value.count <= 254,
              value.contains("@"), !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }
}

private struct AntigravityDiscoveryFailureProvider: QuotaProvider {
    let allowance: GeminiQuotaProvider.Allowance
    let reason: UnavailableReason
    var vendorId: VendorIdentifier {
        switch allowance {
        case .gemini: .gemini
        case .claude: .antigravityClaude
        case .argon:  .antigravityArgon
        }
    }
    var displayName: String { vendorId.displayName }
    var category: MetricCategory { .aiSubscriptions }
    func fetchSnapshot() async throws -> QuotaSnapshot { unavailable(reason) }
}
