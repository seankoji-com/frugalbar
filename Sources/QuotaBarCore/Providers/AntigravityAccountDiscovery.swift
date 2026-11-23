import Foundation

/// This Mac's direct credential: the access token, a stable key for the
/// Google sign-in it came from when there is one, and the account key when
/// the credential itself records its account.
struct AntigravityDirectSession: Sendable {
    let accessToken: String
    let sessionKey: String?
    var accountKey: String? = nil

    /// The key for a sign-in: a digest of its refresh token, which survives
    /// access-token renewal. A sign-in saved without a refresh token has no
    /// key: every such sign-in would otherwise share one and reuse another
    /// account's cached answer.
    static func sessionKey(refreshToken: String) -> String? {
        let refresh = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return refresh.isEmpty ? nil : AntigravityAccount.digest("google-sign-in|" + refresh)
    }
}

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
    /// An opaque key for the Google account this route signs in as, when
    /// known: a digest of the normalised email. Only equality is needed.
    var accountKey: String? = nil

    var verifiedIdentity: String? {
        guard let projectID, !projectID.isEmpty else { return nil }
        return AntigravityAccount.instanceID(identity: "project|\(projectID)")
    }

    func withAccountKey(_ key: String?) -> AntigravityAccountRoute {
        var copy = self
        copy.accountKey = key
        return copy
    }

    /// The account key for an email, or nil for anything that is not one.
    static func accountKey(forEmail email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              email.count <= 254, email.contains("@"),
              !email.contains(where: { $0.isWhitespace || $0.isNewline }),
              !email.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return AntigravityAccount.digest("google-account|" + email)
    }

    /// The identity a verified route is grouped under, given this Mac's
    /// route and the Google account it signs in as (nil when unknown).
    ///
    /// This Mac's route, and a proxy route whose account is not published,
    /// group by Cloud Code project exactly as before. A proxy route that
    /// names its Google account is keyed by that account and joins this
    /// Mac's row only when it is the same account: Google can attach two
    /// different accounts to one project, and grouping them by project hid
    /// the second account entirely. With this Mac's account unknown the
    /// proxy account keeps its own row, so the worst case is a duplicate row
    /// for one pass, never a hidden account.
    func groupingIdentity(directRoute: AntigravityAccountRoute?, directAccountKey: String?) -> String? {
        guard let project = verifiedIdentity else { return nil }
        guard !isPrimary, let accountKey else { return project }
        if accountKey == directAccountKey, let directIdentity = directRoute?.verifiedIdentity {
            return directIdentity
        }
        return AntigravityAccount.instanceID(identity: "account|\(accountKey)")
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
    /// This Mac's Google sign-in → the account key `userinfo` gave for it,
    /// keyed by the sign-in (a digest of its refresh token, which survives
    /// access-token renewal) so another sign-in can never reuse it. One
    /// entry, digests only.
    static let directAccountKeysKey = "QuotaBarAntigravityDirectAccountKeys"

    private let defaults: UserDefaults
    private let proxyConfig: @Sendable () -> CLIProxyConfig?
    private let directSession: @Sendable () async -> AntigravityDirectSession?
    private let environment: [String: String]
    private let apiBaseOverride: [String]?
    private let proxyBudgetSeconds: TimeInterval

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
        directCredential: (@Sendable () async -> String?)? = nil,
        directSession: @escaping @Sendable () async -> AntigravityDirectSession? = {
            guard !TestHost.isActive else { return nil }
            if let session = await GeminiOAuthSession.loadRefreshed() {
                // A session saved without a refresh token has nothing stable
                // to key on: every such sign-in would share one key and reuse
                // another account's answer, so its account is never cached.
                return AntigravityDirectSession(
                    accessToken: session.accessToken,
                    sessionKey: AntigravityDirectSession.sessionKey(refreshToken: session.refreshToken))
            }
            // The antigravity-usage session records its own Google account,
            // so it is known without `userinfo` (whose scope it may lack).
            return await CredentialStore.antigravitySessionAsync().map {
                AntigravityDirectSession(
                    accessToken: $0.accessToken, sessionKey: nil,
                    accountKey: AntigravityAccountRoute.accountKey(forEmail: $0.email))
            }
        },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        apiBases: [String]? = nil,
        proxyBudgetSeconds: TimeInterval = 4.0
    ) {
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? CredentialStore.preferences
        self.proxyConfig = proxyConfig
        // A bare token (tests, callers without a sign-in key) is a session
        // with no key, so its account is never cached.
        if let directCredential {
            self.directSession = {
                await directCredential().map { AntigravityDirectSession(accessToken: $0, sessionKey: nil) }
            }
        } else {
            self.directSession = directSession
        }
        self.environment = environment
        self.apiBaseOverride = apiBases
        self.proxyBudgetSeconds = proxyBudgetSeconds
    }

    func providers(now: Date = Date()) async -> [any QuotaProvider] {
        let oldAccounts = AntigravityAccountStore.all(in: defaults)
        let oldBindings = defaults.data(forKey: Self.bindingsKey).flatMap {
            try? JSONDecoder().decode([AntigravityAccountBinding].self, from: $0)
        } ?? []
        let config = proxyConfig()
        let session = await directSession()
        let directToken = session.map(\.accessToken).flatMap { $0.isEmpty ? nil : $0 }
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
        let configuredBase = GeminiQuotaProvider.apiBase(from: environment["FRUGALBAR_GEMINI_API_BASE"])
        // Honour FRUGALBAR_GEMINI_API_BASE during discovery so identity probes
        // hit the exact same authoritative host as GeminiQuotaProvider, and
        // never probe production hosts when an invalid override is configured.
        let bases: [String] = if let override = self.apiBaseOverride {
            override
        } else if configuredBase.invalid {
            []
        } else if let value = configuredBase.value {
            [value]
        } else {
            GeminiQuotaProvider.productionAPIHosts
        }

        let directRoute: AntigravityAccountRoute? = directToken.map { token in
            AntigravityAccountRoute(
                source: "direct|" + AntigravityAccount.digest(token),
                sourceLabel: "This Mac's Google OAuth session",
                isPrimary: true,
                accessToken: token,
                proxy: nil,
                authFile: nil,
                projectID: nil,
                planName: nil,
                failure: nil
            )
        }

        // Run the direct local identity probe concurrently with the bounded
        // proxy discovery + proxy identity probes so a slow or hung CLIProxyAPI
        // host can never stall the healthy local account past QuotaManager's deadline.
        let proxyBudget = self.proxyBudgetSeconds
        async let probedDirect = Self.probeDirectIdentity(
            route: directRoute, bases: bases, batch: batch, now: now)

        // Which Google account this Mac's sign-in is, needed only to tell it
        // apart from proxy accounts: recorded by the credential, remembered for
        // this sign-in, or asked of `userinfo`. The lookup starts alongside
        // proxy discovery and is cancelled, not awaited, when no proxy account
        // names an account to compare with, so it never lengthens a pass that
        // cannot use it. It is a production Google call, made only when
        // discovery uses the production hosts.
        let cached = (defaults.dictionary(forKey: Self.directAccountKeysKey) as? [String: String])
            .flatMap { cache in session?.sessionKey.flatMap { cache[$0] } }
        let knownDirectKey = session?.accountKey ?? cached
        let usesProductionHosts = apiBaseOverride == nil
            && !configuredBase.invalid && configuredBase.value == nil
        let lookup: Task<String?, Never>? = (directToken != nil && knownDirectKey == nil
            && config != nil && usesProductionHosts)
            ? Task { [directToken] in await Self.boundedAccountKey(token: directToken, seconds: proxyBudget) }
            : nil

        let proxyOutcome = await Self.discoverProxyRoutes(
            config: config,
            oldAccounts: oldAccounts,
            oldBindings: oldBindings,
            bases: bases,
            batch: batch,
            proxyBudget: proxyBudget,
            now: now
        )

        var directAccountKey = knownDirectKey
        if let lookup {
            if proxyOutcome.routes.contains(where: { $0.accountKey != nil }) {
                directAccountKey = await lookup.value
                if let key = directAccountKey, let sessionKey = session?.sessionKey {
                    defaults.set([sessionKey: key], forKey: Self.directAccountKeysKey)
                }
            } else {
                lookup.cancel()
            }
        }

        var discovered: [AntigravityAccountRoute] = []
        if let local = await probedDirect { discovered.append(local.withAccountKey(directAccountKey)) }
        discovered.append(contentsOf: proxyOutcome.routes)
        discovered.sort { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.source < rhs.source
        }
        let thisMacRoute = discovered.first { $0.isPrimary }
        var groupingIdentity: [String: String] = [:]
        for route in discovered {
            groupingIdentity[route.source] = route.groupingIdentity(
                directRoute: thisMacRoute, directAccountKey: directAccountKey)
        }
        let unavailableBindings = proxyOutcome.unavailableBindings
        let proxyInventoryFailed = proxyOutcome.inventoryFailed
        let inventoryFailure = proxyOutcome.inventoryFailure
        guard !Task.isCancelled else { return [] }

        var groups: [String: [AntigravityAccountRoute]] = [:]
        var bindings: [AntigravityAccountBinding] = []
        var identities: [String: String] = [:]
        for binding in oldBindings {
            if let identity = binding.identity { identities[identity] = binding.accountID }
        }

        let verifiedGroups = Dictionary(
            grouping: discovered.filter { groupingIdentity[$0.source] != nil },
            by: { groupingIdentity[$0.source]! }
        )
        let badges = defaults.dictionary(forKey: AntigravityAccountStore.badgesKey) as? [String: String] ?? [:]
        // A newly verified identity may adopt a route's earlier unverified ID,
        // but never an ID another identity already holds: since a proxy
        // account and this Mac can now be different identities on one
        // project, two of them adopting the same source-scoped ID would build
        // one row from two accounts' credentials. This Mac's identity is
        // settled first, then the rest in a stable order.
        var claimedIDs = Set(identities.values)
        let unassigned = verifiedGroups.filter { identities[$0.key] == nil }.sorted { lhs, rhs in
            let lhsPrimary = lhs.value.contains(where: \.isPrimary)
            let rhsPrimary = rhs.value.contains(where: \.isPrimary)
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            return lhs.key < rhs.key
        }
        for (identity, matchingRoutes) in unassigned {
            let candidates = matchingRoutes.compactMap { route in
                oldBindings.first { $0.source == route.source && !$0.verified }?.accountID
            }.filter { !claimedIDs.contains($0) }
            let previousID = candidates.min {
                (Int(badges[$0] ?? "") ?? Int.max, $0) < (Int(badges[$1] ?? "") ?? Int.max, $1)
            }
            let fallback = claimedIDs.contains(identity)
                ? AntigravityAccount.instanceID(identity: "reassigned|" + identity)
                : identity
            let assigned = previousID ?? fallback
            identities[identity] = assigned
            claimedIDs.insert(assigned)
        }

        let verifiedAccountIDs = Set(discovered.compactMap { route in
            groupingIdentity[route.source].map { identities[$0] ?? $0 }
        })
        var aliases: [String: Set<String>] = [:]
        for route in discovered {
            let previous = oldBindings.first { $0.source == route.source }
            let identity = groupingIdentity[route.source]
            // Never merge a currently unverified route into a verified account
            // ID — even if that verified account previously adopted this
            // route's source-scoped ID during promotion.
            let id: String
            let verified: Bool
            if let identity {
                id = identities[identity] ?? identity
                verified = true
            } else {
                let candidate = (previous?.verified == false ? previous?.accountID : nil)
                    ?? AntigravityAccount.instanceID(identity: "source|" + route.source)
                id = verifiedAccountIDs.contains(candidate)
                    ? AntigravityAccount.instanceID(identity: "unverified|" + route.source)
                    : candidate
                verified = false
            }
            bindings.append(AntigravityAccountBinding(
                source: route.source,
                accountID: id,
                verified: verified,
                identity: identity
            ))
            // An ID another identity holds is that account's history, never
            // an alias of this one.
            if let identity, let previous, previous.accountID != id,
               !previous.verified || previous.identity == identity,
               !identities.contains(where: { $0.value == previous.accountID && $0.key != identity }) {
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
                    environment: environment,
                    apiBaseOverride: apiBaseOverride?.count == 1 ? apiBaseOverride?[0] : nil,
                    allowance: allowance,
                    requests: batch
                ))
            }
        }
        return result
    }

    private struct ProxyDiscoveryOutcome: Sendable {
        let routes: [AntigravityAccountRoute]
        let unavailableBindings: [(AntigravityAccountBinding, UnavailableReason)]
        let inventoryFailed: Bool
        let inventoryFailure: UnavailableReason?
    }

    private static func probeDirectIdentity(
        route: AntigravityAccountRoute?,
        bases: [String],
        batch: AntigravityRequestBatch,
        now: Date
    ) async -> AntigravityAccountRoute? {
        guard let route else { return nil }
        return await probeIdentity(route: route, bases: bases, batch: batch, now: now)
    }

    private static func discoverProxyRoutes(
        config: CLIProxyConfig?,
        oldAccounts: [AntigravityAccount],
        oldBindings: [AntigravityAccountBinding],
        bases: [String],
        batch: AntigravityRequestBatch,
        proxyBudget: TimeInterval,
        now: Date
    ) async -> ProxyDiscoveryOutcome {
        guard let config else {
            return ProxyDiscoveryOutcome(routes: [], unavailableBindings: [], inventoryFailed: false, inventoryFailure: nil)
        }
        let inventoryOutcome: DeadlineOutcome<[CLIProxyAuthFile]> = await withDeadline(seconds: proxyBudget) {
            try await CLIProxyClient.fetchAuthFiles(config: config, now: now)
        }
        switch inventoryOutcome {
        case .failure(let reason):
            let activeIDs = Set(oldAccounts.map(\.id))
            let unavailable = oldBindings.filter {
                $0.source.hasPrefix(proxySourcePrefix(config)) && activeIDs.contains($0.accountID)
            }.map { ($0, reason) }
            return ProxyDiscoveryOutcome(routes: [], unavailableBindings: unavailable, inventoryFailed: true, inventoryFailure: reason)
        case .success(let files):
            let prefix = proxySourcePrefix(config)
            let enabled = files.filter {
                $0.provider.lowercased() == "antigravity"
                    && $0.disabled != true
                    && !$0.authIndex.isEmpty
            }.sorted { ($0.id ?? $0.authIndex, $0.authIndex) < ($1.id ?? $1.authIndex, $1.authIndex) }
            let fileIndices = Dictionary(grouping: enabled, by: { $0.id ?? "" })
                .mapValues { Set($0.map(\.authIndex)) }
            var seen = Set<String>()
            var proxyRoutes: [AntigravityAccountRoute] = []
            for file in enabled where seen.insert(file.authIndex).inserted {
                let hint = safeAccountHint(file.email).map { " · " + $0 } ?? ""
                let sourceID: String
                if let id = file.id, !id.isEmpty, fileIndices[id]?.count == 1 {
                    sourceID = "file|" + id
                } else {
                    sourceID = "index|" + file.authIndex
                }
                proxyRoutes.append(AntigravityAccountRoute(
                    source: prefix + AntigravityAccount.digest(sourceID),
                    sourceLabel: "CLI Proxy (\(config.url.host ?? "configured host"))" + hint,
                    isPrimary: false,
                    accessToken: nil,
                    proxy: config,
                    authFile: file,
                    projectID: nil,
                    planName: nil,
                    failure: nil,
                    accountKey: AntigravityAccountRoute.accountKey(forEmail: file.email)
                ))
            }
            // Bound each proxy route's identity probe independently so one
            // slow proxy account never discards healthy sibling probes.
            let probedProxy = await withTaskGroup(of: AntigravityAccountRoute.self, returning: [AntigravityAccountRoute].self) { group in
                for route in proxyRoutes {
                    group.addTask {
                        let outcome = await withDeadline(seconds: proxyBudget) {
                            await probeIdentity(route: route, bases: bases, batch: batch, now: now)
                        }
                        switch outcome {
                        case .success(let probed): return probed
                        case .failure(let reason):
                            return AntigravityAccountRoute(
                                source: route.source,
                                sourceLabel: route.sourceLabel,
                                isPrimary: route.isPrimary,
                                accessToken: route.accessToken,
                                proxy: route.proxy,
                                authFile: route.authFile,
                                projectID: nil,
                                planName: nil,
                                failure: reason,
                                accountKey: route.accountKey
                            )
                        }
                    }
                }
                var probed: [AntigravityAccountRoute] = []
                for await route in group { probed.append(route) }
                return probed
            }
            return ProxyDiscoveryOutcome(routes: probedProxy, unavailableBindings: [], inventoryFailed: false, inventoryFailure: nil)
        }
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
            failure: terminalFailure,
            accountKey: route.accountKey
        )
    }

    /// `fetchAccountKey` bounded by `seconds`, as structured child tasks so
    /// cancelling the caller cancels the request too (an unawaited lookup
    /// must not keep a `userinfo` call running for the whole budget).
    static func boundedAccountKey(token: String?, seconds: TimeInterval) async -> String? {
        guard let token else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await fetchAccountKey(token: token) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The account key for the Google account a direct token signs in as,
    /// from `userinfo`. FrugalBar's own Google sign-in requests
    /// `userinfo.email`; a token without that scope, an unverified email, or
    /// any failure yields nil (unknown, never a guess). The token is sent only
    /// in the Authorization header.
    static func fetchAccountKey(token: String) async -> String? {
        guard let (data, http) = try? await QuotaHTTP.get(
            url: "https://www.googleapis.com/oauth2/v3/userinfo",
            headers: ["Accept": "application/json"],
            auth: .bearer(token)
        ), http.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = body["email"] as? String,
              body["email_verified"] as? Bool == true
        else { return nil }
        return AntigravityAccountRoute.accountKey(forEmail: email)
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
    var instanceID: String {
        "\(AntigravityAccount.instancePrefix)proxy-unavailable:\(AntigravityAccount.poolSuffix(for: allowance))"
    }
    var displayName: String { vendorId.displayName }
    var category: MetricCategory { .aiSubscriptions }
    func fetchSnapshot() async throws -> QuotaSnapshot {
        QuotaSnapshot(
            id: instanceID,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .subscription(tierName: "", renewalDate: nil),
            status: .unavailable(reason),
            resetsAt: nil,
            lastUpdated: Date(),
            auxiliaryInfo: nil
        )
    }
}
