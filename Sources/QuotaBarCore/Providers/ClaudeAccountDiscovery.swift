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
    var identity: String? = nil
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
    let failure: UnavailableReason?
    let profile: ClaudeAccountProfile?
}

actor ClaudeAccountDiscovery {
    static let shared = ClaudeAccountDiscovery()
    static let lockedVaultReason = UnavailableReason.unsupported("Unlock Keychain in Settings to read Claude.")
    private static let bindingsKey = "QuotaBarClaudeAccountBindings"
    private let defaults: UserDefaults
    private let proxyConfig: @Sendable () -> CLIProxyConfig?
    private let directCredential: @Sendable () async -> String?
    private let directPlan: @Sendable () async -> String?
    private let isVaultLocked: @Sendable () -> Bool
    private let backoff: ClaudeProxyBackoff
    private let grants: ClaudeGrantSchedule
    private let monthlyCredit: @Sendable (Date) async -> ClaudeMonthlyCredit?
    private let lastMonthlyCredit: @Sendable () async -> ClaudeMonthlyCredit?
    private var profileWaits: [String: (until: Date, reason: UnavailableReason)] = [:]
    private var cachedProviders: [any QuotaProvider] = []
    private var discoverySignature: String?
    private var lastDiscoveryAt: Date?
    private var lastUserDiscoveryAt: Date?

    init(defaultsSuiteName: String? = nil,
                proxyConfig: @escaping @Sendable () -> CLIProxyConfig? = {
                    TestHost.isActive ? nil : CLIProxyClient.discoverConfig()
                },
                directCredential: @escaping @Sendable () async -> String? = {
                    TestHost.isActive ? nil : await CredentialStore.apiKeyAsync(for: .claude)
                },
                directPlan: @escaping @Sendable () async -> String? = {
                    TestHost.isActive ? nil : await CredentialStore.claudePlanNameAsync()
                },
                isVaultLocked: @escaping @Sendable () -> Bool = {
                    !TestHost.isActive && KeychainVault.shared.statusSnapshot().isLockedOrDenied
                },
                backoff: ClaudeProxyBackoff? = nil, grants: ClaudeGrantSchedule? = nil,
                monthlyCredit: (@Sendable (Date) async -> ClaudeMonthlyCredit?)? = nil,
                lastMonthlyCredit: (@Sendable () async -> ClaudeMonthlyCredit?)? = nil) {
        self.monthlyCredit = monthlyCredit ?? { now in
            guard !TestHost.isActive else { return nil }
            return await ClaudeMonthlyCreditSession.shared.read(now: now)
        }
        self.lastMonthlyCredit = lastMonthlyCredit ?? {
            guard !TestHost.isActive else { return nil }
            return await ClaudeMonthlyCreditSession.shared.lastRead()
        }
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? CredentialStore.preferences
        self.proxyConfig = proxyConfig
        self.directCredential = directCredential; self.directPlan = directPlan
        self.isVaultLocked = isVaultLocked
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
        if config == nil, directToken == nil, isVaultLocked() {
            let reason = Self.lockedVaultReason
            if oldAccounts.isEmpty { return [ClaudeDiscoveryFailureProvider(reason: reason)] }
            return oldAccounts.map { ClaudeDiscoveryFailureProvider(reason: reason, account: $0) }
        }
        let names = defaults.dictionary(forKey: ClaudeAccountStore.nicknamesKey) as? [String: String] ?? [:]
        let signature = ClaudeAccount.digest((config?.url.absoluteString ?? "") + "|"
            + (config?.managementKey ?? "") + "|" + (directToken ?? "") + "|"
            + names.keys.sorted().map { $0 + "=" + names[$0]! }.joined(separator: "|"))
        let userInitiated = QuotaFetchContext.isUserInitiated
        let measuredFrom = userInitiated ? lastUserDiscoveryAt : lastDiscoveryAt
        if signature == discoverySignature,
           let measuredFrom, now.timeIntervalSince(measuredFrom) < 30 { return cachedProviders }
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
                let fileIndices = Dictionary(grouping: enabled, by: { $0.id ?? "" })
                    .mapValues { Set($0.map(\.authIndex)) }
                var seen = Set<String>()
                for file in enabled where seen.insert(file.authIndex).inserted {
                    let hint = Self.safeAccountHint(file.email).map { " · " + $0 } ?? ""
                    // A stable file id survives hub auth-index regeneration.
                    // Ambiguous/missing ids use the exact credential index and
                    // cannot falsely merge two unknown accounts.
                    let sourceID: String
                    if let id = file.id, !id.isEmpty, fileIndices[id]?.count == 1 { sourceID = "file|" + id }
                    else { sourceID = "index|" + file.authIndex }
                    routes.append(ClaudeAccountRoute(source: prefix + ClaudeAccount.digest(sourceID),
                        sourceLabel: "CLI Proxy (\(config.url.host ?? "configured host"))" + hint, token: nil,
                        proxy: config, authFile: file, plan: nil, failure: nil, profile: nil))
                }
            } catch {
                proxyInventoryFailed = true
                let reason = unavailableReason(for: error)
                inventoryFailure = reason
                let activeIDs = Set(oldAccounts.map(\.id))
                unavailableBindings += oldBindings.filter {
                    $0.source.hasPrefix(Self.proxySourcePrefix(config)) && activeIDs.contains($0.accountID)
                }
                    .map { ($0, reason) }
            }
        }
        if let token = directToken {
            routes.append(ClaudeAccountRoute(source: "direct|" + ClaudeAccount.digest(token),
                sourceLabel: "This Mac's Claude Code session", token: token, proxy: nil, authFile: nil,
                plan: await directPlan(), failure: nil, profile: nil))
        }
        // Profile reads are independent. A slow or rejected account cannot
        // prevent another account's identity being resolved.
        let waits = profileWaits
        let backoff = self.backoff
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
                        if !userInitiated {
                            let until: Date?
                            if let config = route.proxy, let file = route.authFile {
                                until = await backoff.retryAfter(config: config, account: file.authIndex, now: now)
                            } else if let token = route.token {
                                until = await backoff.directRetryAfter(token: token, now: now)
                            } else { until = nil }
                            if let until { throw ProviderError(.rateLimited(retryAfter: until)) }
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
                        plan: profile?.planName ?? route.plan,
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
        var identities: [String: String] = [:]
        for binding in oldBindings {
            if let identity = binding.identity { identities[identity] = binding.accountID }
        }
        // Promote an unknown source without moving its existing readings or
        // nickname to a new id. If two such sources now prove identical, keep
        // the oldest badge and retain the other's history as an explicit alias.
        let verifiedGroups = Dictionary(grouping: discovered.filter { $0.profile != nil }, by: { $0.profile!.instanceID })
        let badges = defaults.dictionary(forKey: ClaudeAccountStore.badgesKey) as? [String: String] ?? [:]
        for (identity, routes) in verifiedGroups where identities[identity] == nil {
            let candidates = routes.compactMap { route in
                oldBindings.first { $0.source == route.source && !$0.verified }?.accountID
            }
            let previousID = candidates.min {
                (Int(badges[$0] ?? "") ?? Int.max, $0) < (Int(badges[$1] ?? "") ?? Int.max, $1)
            }
            identities[identity] = previousID ?? identity
        }
        var aliases: [String: Set<String>] = [:]
        for route in discovered {
            if case .rateLimited(let until)? = route.failure, let until {
                profileWaits[route.source] = (until, route.failure!)
            } else if route.profile != nil { profileWaits[route.source] = nil }
            let previous = oldBindings.first { $0.source == route.source }
            let identity = route.profile?.instanceID
            let id = identity.flatMap { identities[$0] } ?? previous?.accountID
                ?? ClaudeAccount.instanceID(identity: "source|" + route.source)
            let verified = route.profile != nil || previous?.verified == true
            bindings.append(ClaudeAccountBinding(source: route.source, accountID: id, verified: verified,
                identity: identity ?? previous?.identity))
            if let identity, let previous, previous.accountID != id,
               !previous.verified || previous.identity == identity {
                aliases[id, default: []].insert(previous.accountID)
                if let old = oldAccounts.first(where: { $0.id == previous.accountID }) {
                    aliases[id, default: []].formUnion(old.historyAliases)
                }
            }
            if route.profile == nil, previous?.verified == true {
                // A previously verified source cannot publish fresh quota under
                // that name until its current credential identifies itself.
                unavailableBindings.append((ClaudeAccountBinding(source: route.source, accountID: id, verified: true,
                    identity: previous?.identity),
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
                planName: routes.compactMap(\.plan).first,
                historyAliases: Set(oldAccounts.first { $0.id == id }?.historyAliases ?? [])
                    .union(aliases[id] ?? []).sorted())
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
            let result: [any QuotaProvider] = if let inventoryFailure {
                [ClaudeDiscoveryFailureProvider(reason: inventoryFailure)]
            } else { [ClaudeQuotaProvider(apiKey: "", directCredential: { nil })] }
            return remember(result, signature: signature, now: now, userInitiated: userInitiated)
        }
        let accounts = ClaudeAccountStore.saveDiscovered(descriptors, in: defaults)
        // Retain identity bindings while a hub account is disabled or removed.
        // They are metadata, not active routes; rediscovery must recover the
        // same account id and nickname rather than start a new history line.
        let currentSources = Set(bindings.map(\.source))
        bindings += oldBindings.filter { !currentSources.contains($0.source) }
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.bindingsKey) }
        let creditRows = Self.creditRows(accounts: accounts, bindings: bindings)
        let result: [any QuotaProvider] = accounts.map { account in
            ClaudeAccountQuotaProvider(account: account, routes: groups[account.id] ?? [],
                failure: unavailableBindings.first { $0.0.accountID == account.id }?.1,
                backoff: backoff, grants: grants, creditRows: creditRows, monthlyCredit: monthlyCredit,
                lastMonthlyCredit: lastMonthlyCredit)
        }
        return remember(result, signature: signature, now: now, userInitiated: userInitiated)
    }

    /// Each shown account's verified OAuth identity (account + organisation),
    /// from the bindings discovery itself established. An account with no
    /// verified identity has none, so it can never receive the credit.
    private static func creditRows(accounts: [ClaudeAccount],
                                   bindings: [ClaudeAccountBinding]) -> [ClaudeMonthlyCreditBinding.Row] {
        accounts.map { account in
            let identities = Set(bindings.filter { $0.accountID == account.id && $0.verified }.compactMap(\.identity))
            // Two different verified identities on one row cannot happen by
            // construction; if they ever did, the row is not provably one
            // organisation and gets no identity.
            return .init(accountID: account.id, identity: identities.count == 1 ? identities.first : nil)
        }
    }

    /// The rows Settings explains the credit's placement against.
    static func storedCreditRows(defaults: UserDefaults = CredentialStore.preferences) -> [ClaudeMonthlyCreditBinding.Row] {
        let bindings = defaults.data(forKey: bindingsKey).flatMap {
            try? JSONDecoder().decode([ClaudeAccountBinding].self, from: $0)
        } ?? []
        return creditRows(accounts: ClaudeAccountStore.all(in: defaults), bindings: bindings)
    }

    private func remember(_ providers: [any QuotaProvider], signature: String,
                          now: Date, userInitiated: Bool) -> [any QuotaProvider] {
        cachedProviders = providers
        discoverySignature = signature
        lastDiscoveryAt = now
        if userInitiated { lastUserDiscoveryAt = now }
        return providers
    }

    private static func proxySourcePrefix(_ config: CLIProxyConfig) -> String {
        "proxy|" + ClaudeAccount.digest(config.url.absoluteString) + "|"
    }

    private static func safeAccountHint(_ value: String?) -> String? {
        guard let value = value?.trimmed, value.count <= 254,
              value.contains("@"), !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }
}

private struct ClaudeDiscoveryFailureProvider: QuotaProvider {
    let reason: UnavailableReason
    var account: ClaudeAccount? = nil
    var vendorId: VendorIdentifier { .claude }
    var displayName: String { account?.name ?? "Claude" }
    var category: MetricCategory { .aiSubscriptions }
    var instanceID: String { account?.id ?? vendorId.rawValue }
    func fetchSnapshot() async throws -> QuotaSnapshot {
        var snapshot = unavailable(reason)
        snapshot.claudeAccount = account
        snapshot.planName = account?.planName
        return snapshot
    }
}

/// Fallback is permitted only between routes whose published account and
/// organization matched. Unknown sources always receive separate instance ids.
struct ClaudeAccountQuotaProvider: QuotaProvider {
    let account: ClaudeAccount
    let routes: [ClaudeAccountRoute]
    let failure: UnavailableReason?
    let backoff: ClaudeProxyBackoff
    let grants: ClaudeGrantSchedule
    /// Every shown row's identity, so the credit binds only when exactly one
    /// row matches the web session's account.
    var creditRows: [ClaudeMonthlyCreditBinding.Row] = []
    var monthlyCredit: @Sendable (Date) async -> ClaudeMonthlyCredit? = { _ in nil }
    /// The last completed read, taken when the wait for this poll's read runs
    /// out. Its identity is the one that read verified, so binding still
    /// applies; only its freshness is older.
    var lastMonthlyCredit: @Sendable () async -> ClaudeMonthlyCredit? = { nil }
    var vendorId: VendorIdentifier { .claude }
    var displayName: String { account.name }
    var category: MetricCategory { .aiSubscriptions }
    var instanceID: String { account.id }

    func fetchSnapshot() async throws -> QuotaSnapshot {
        try await fetchSnapshot(now: Date())
    }

    func fetchSnapshot(now: Date) async throws -> QuotaSnapshot {
        // Billing is independent of the usage read: read it concurrently, and
        // attach it whether or not usage answered, as the unnamed row does.
        // The billing page's reads are optional enrichment. They are bounded
        // well inside the provider deadline: two stalled WebKit callbacks
        // (billing, then account) could otherwise outlast it and throw away a
        // usage reading that had already been measured.
        async let credit = Self.bounded(monthlyCredit, fallback: lastMonthlyCredit,
                                        now: now, limit: creditWaitLimit)
        var snapshot = try await fetchUsage()
        let monthly = await credit
        if let monthly, case .bound(let id) = ClaudeMonthlyCreditBinding.resolve(
            webIdentities: monthly.webIdentities, rows: creditRows), id == account.id {
            snapshot.monthlyAPICredit = monthly
        } else {
            snapshot.monthlyAPICredit = nil
        }
        return snapshot
    }

    var creditWaitLimit: Duration = .seconds(4)

    /// The read's result, or once `limit` passes the last completed read
    /// (`fallback`), whichever is first. The read keeps running and updates
    /// the session's state for the next poll. Returning nil on the timeout
    /// dropped the line from the row for that whole poll whenever claude.ai
    /// took more than four seconds over its three requests.
    static func bounded(_ read: @escaping @Sendable (Date) async -> ClaudeMonthlyCredit?,
                        fallback: @escaping @Sendable () async -> ClaudeMonthlyCredit? = { nil },
                        now: Date, limit: Duration) async -> ClaudeMonthlyCredit? {
        await withCheckedContinuation { continuation in
            let gate = FirstResultGate(continuation)
            Task { gate.resume(await read(now)) }
            Task {
                try? await Task.sleep(for: limit)
                // The last read is an earlier observation, so it is drawn as
                // stale, keeping its own observation number and timestamp.
                var last = await fallback()
                last?.refreshFailed = true
                gate.resume(last)
            }
        }
    }

    private func fetchUsage() async throws -> QuotaSnapshot {
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
