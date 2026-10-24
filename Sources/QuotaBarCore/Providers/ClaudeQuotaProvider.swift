import Foundation
import CryptoKit

/// Claude subscription quota from Anthropic's OAuth usage endpoint, read via
/// CLI Proxy or directly with the Claude Code OAuth token. Derived from
/// claude-rate-monitor (MIT).
public final class ClaudeQuotaProvider: QuotaProvider, Sendable {
    public let vendorId: VendorIdentifier = .claude
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions
    private let apiKey: String?
    private let cliProxyConfig: CLIProxyConfig?
    private let proxyBackoff: ClaudeProxyBackoff
    private let monthlyCredit: @Sendable (Date) async -> ClaudeMonthlyCredit?
    /// Resolves the *direct* Claude Code OAuth token — the one this Mac's own
    /// `claude` login holds, as opposed to whatever the proxy holds.
    private let directCredential: @Sendable () async -> String?

    public init(
        apiKey: String? = nil,
        cliProxyConfig: CLIProxyConfig? = nil,
        // Injectable so a test can drive the proxy-failure fall-through below
        // without reading the developer's own Claude login out of the Keychain.
        // Nil means the production path: this Mac's Claude Code credential.
        directCredential: (@Sendable () async -> String?)? = nil,
        proxyBackoff: ClaudeProxyBackoff? = nil,
        monthlyCredit: (@Sendable (Date) async -> ClaudeMonthlyCredit?)? = nil
    ) {
        self.monthlyCredit = monthlyCredit ?? { now in
            guard !TestHost.isActive else { return nil }
            return await ClaudeMonthlyCreditSession.shared.read(now: now)
        }
        self.apiKey = apiKey
        self.cliProxyConfig = cliProxyConfig
        self.proxyBackoff = proxyBackoff ?? (TestHost.isActive ? ClaudeProxyBackoff() : .shared)
        self.directCredential = directCredential
            ?? { await CredentialStore.apiKeyAsync(for: .claude) }
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        try await fetchSnapshot(now: Date())
    }

    func fetchSnapshot(now: Date) async throws -> QuotaSnapshot {
        // Billing is independent of OAuth usage. Read it concurrently so a
        // slow web process cannot add its entire wait to the quota request,
        // and a quota transport failure does not erase a fresh entitlement.
        async let credit = monthlyCredit(now)
        var snapshot: QuotaSnapshot
        do {
            snapshot = try await fetchUsageSnapshot(now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            snapshot = unavailable(unavailableReason(for: error))
        }
        // A refused usage read does not erase the plan the credential states.
        // Without this, a rate-limited Claude header said only "Claude" while
        // the account's "Max (20x)" was sitting in the same Keychain blob.
        if snapshot.planName == nil {
            snapshot.planName = await CredentialStore.claudePlanNameAsync()
        }
        snapshot.monthlyAPICredit = await credit
        return snapshot
    }

    private func fetchUsageSnapshot(now: Date) async throws -> QuotaSnapshot {
        // If an explicit apiKey is injected, use direct token path.
        if let injectedKey = apiKey, !injectedKey.isEmpty {
            return try await fetchSnapshotDirect(token: injectedKey, now: now)
        }
        if apiKey != nil {
            return unavailable(.notConfigured)
        }

        // Check CLI Proxy: explicit config, or discovered from ~/.t3/userdata
        let proxyConfig = cliProxyConfig ?? (TestHost.isActive ? nil : CLIProxyClient.discoverConfig())
        // Why the proxy failed, when it did — reported below only if the direct
        // token cannot answer either, because a proxy-side failure says nothing
        // about a different credential.
        var proxyFailure: UnavailableReason?
        if let proxyConfig {
            // A healthy direct token must not erase the proxy token's throttle.
            // Providers are rebuilt each pass, so this state outlives this
            // instance. Manual refresh deliberately probes the proxy again.
            if !QuotaFetchContext.isUserInitiated,
               let until = await proxyBackoff.retryAfter(config: proxyConfig, now: now) {
                proxyFailure = .rateLimited(retryAfter: until)
            } else {
                do {
                    let snapshot = try await fetchSnapshotViaProxy(config: proxyConfig, now: now)
                    await proxyBackoff.record(nil, config: proxyConfig)
                    return snapshot
                } catch let error as ProviderError {
                    proxyFailure = error.reason
                    await proxyBackoff.record(error.reason, config: proxyConfig)
                } catch {
                    // Transport failure establishes nothing about either token.
                }
            }
        }

        // The direct Claude Code token is an independent credential, so the
        // proxy failing is not evidence about it. A proxy-side 429 is the case
        // that matters: Anthropic throttles the usage endpoint per account
        // token for ~40 minutes at a time (the proxy's own token spent a whole
        // day 429 while this Mac's token answered the same endpoint 200), and
        // treating that as this provider's final answer left the Claude row
        // reading "Rate limited" with no bars until the process restarted.
        guard let token = await directCredential().flatMap({ $0.isEmpty ? nil : $0 }) else {
            // Nothing else to try, and the proxy's own reason is the honest
            // one: "Not configured" would send the user looking for a
            // credential that is right there.
            return unavailable(proxyFailure ?? .notConfigured)
        }
        let direct: QuotaSnapshot
        do {
            direct = try await fetchSnapshotDirect(token: token, now: now)
        } catch let error as ProviderError {
            return unavailable(proxyFailure ?? error.reason)
        }
        // A transport failure from the direct call propagates to the engine,
        // which maps it to its own reason — inventing one here would lose that
        // mapping for no gain.
        guard direct.status.confidence == .measured else {
            return unavailable(proxyFailure ?? direct.status.unavailableReason ?? .badResponse)
        }
        return direct
    }

    private func fetchSnapshotViaProxy(config: CLIProxyConfig, now: Date) async throws -> QuotaSnapshot {
        let (usage, _) = try await CLIProxyClient.fetchClaudeUsage(config: config, now: now)
        let host = config.url.host ?? "proxy"
        return try makeSnapshot(
            usage: usage,
            planName: await CredentialStore.claudePlanNameAsync(),
            cliSource: "CLI Proxy (\(host))",
            now: now
        )
    }

    private func fetchSnapshotDirect(token: String, now: Date) async throws -> QuotaSnapshot {
        // The same usage endpoint the proxy path calls, read directly. It used
        // to send a one-token Haiku request and read the rate-limit headers,
        // which spent the quota being reported on every poll.
        if !QuotaFetchContext.isUserInitiated,
           let until = await proxyBackoff.directRetryAfter(token: token, now: now) {
            return unavailable(.rateLimited(retryAfter: until))
        }
        let (data, response) = try await QuotaHTTP.get(
            url: CLIProxyClient.claudeOAuthUsageWithGrantsURL,
            headers: ["Accept": "application/json", "anthropic-beta": "oauth-2025-04-20"],
            auth: .bearer(token)
        )
        // Claude's own policy, not the API-key one: against this endpoint a 403
        // is a throttle rather than a bad token, and a 429 with no usable
        // `Retry-After` still buys a five-minute cooldown. See
        // `CLIProxyClient.claudeUsageFailureReason`.
        if let reason = CLIProxyClient.claudeUsageFailureReason(
            for: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"), now: now) {
            await proxyBackoff.recordDirect(reason, token: token)
            NSLog("frugalbar: Claude OAuth usage request returned %ld (%@)",
                  response.statusCode, String(describing: reason))
            return unavailable(reason)
        }
        guard let usage = try? JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data) else {
            NSLog("frugalbar: Claude OAuth usage body failed to decode (%ld bytes)", data.count)
            return unavailable(.badResponse)
        }
        await proxyBackoff.recordDirect(nil, token: token)
        // The plan is published in the credential blob, not in this payload.
        // Absent, the row shows no subtitle at all — "Claude" under "Claude"
        // was a placeholder that said nothing.
        return try makeSnapshot(
            usage: usage,
            planName: await CredentialStore.claudePlanNameAsync(),
            cliSource: "Claude OAuth usage endpoint",
            now: now
        )
    }

    func makeSnapshot(
        usage: ClaudeOAuthUsageResponse,
        planName: String?,
        cliSource: String,
        now: Date
    ) throws -> QuotaSnapshot {
        let fiveHourReading = usage.fiveHour.flatMap(Self.reading)
        let weeklyReading = usage.sevenDay.flatMap(Self.reading)

        guard fiveHourReading != nil || weeklyReading != nil else {
            return unavailable(.badResponse)
        }

        let readings = [fiveHourReading, weeklyReading].compactMap { $0 }
        let worst = readings.map(\.used).max() ?? 0
        let urgency: Urgency = worst > 0.90 ? .critical : worst > 0.70 ? .warning : .none

        let row1 = fiveHourReading.map { row($0, label: "5H", window: QuotaWindow.fiveHours, now: now) }
        let row2 = weeklyReading.map { row($0, label: "WK", window: QuotaWindow.week, now: now) }
        // The Opus/Sonnet weekly windows are decoded but deliberately not
        // surfaced. A model-scoped cap only blocks that model, yet every bar
        // in a snapshot is read as plan-wide: exhaustion sorting, advice's
        // worst bar and `displayBars`' collapse would all treat a spent Opus
        // window as the whole plan being spent. Showing them needs a
        // per-model scope on `DualBarMetrics` that those consumers skip.

        let remainingPercent = max(0, Int(((1 - worst) * 100).rounded()))
        let badgeText = "\(remainingPercent)% left"
        let primaryReset = row1?.resetsAt ?? row2?.resetsAt

        var snapshot = QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: planName ?? "Claude", renewalDate: nil),
            status: .measured(urgency), resetsAt: primaryReset, lastUpdated: now,
            auxiliaryInfo: Self.auxiliaryInfo(grants: usage.resetGrants),
            row1: row1,
            row2: row2,
            badgeText: badgeText,
            planName: planName, cliSource: cliSource
        )
        // nil whenever the surface served no grants, so a CLI login (which
        // Anthropic currently answers with `ineligible_reason: "surface"`)
        // shows no reset-credit row rather than "0 banked".
        snapshot.resetCreditsAvailable = usage.resetGrants?.resetsAvailable
        snapshot.resetCreditsApplicable = usage.resetGrants?.resetsUsableNow
        // `cedar_ember` grants carry an end for each banked reset. Expand the
        // count so the ticket glyphs line up with their own expiries; a grant
        // that published no end contributes nil, not the reset window's date.
        snapshot.resetCreditExpiries = usage.resetGrants?.grants.flatMap { grant -> [Date?] in
            guard let left = grant.resetsLeft, left > 0 else { return [] }
            let expiry = CLIProxyClient.parseResetDate(grant.endsAt)
            return Array(repeating: expiry, count: left)
        } ?? []
        snapshot.apiCredits = Self.apiCredits(from: usage)
        return snapshot
    }

    /// The prepaid API credits this endpoint published alongside the quota, as
    /// their own entries — never folded into the quota above.
    ///
    /// Two pools can arrive at once, and they are different money: the monthly
    /// extra-usage allowance (`spend` or the older `extra_usage`) and the promo
    /// / cloud-session credit (`iguana_necktie`). Each is drawn separately
    /// because each has its own limit and its own expiry rule, and each entry
    /// names the block it was actually read from rather than assuming the newer
    /// one won.
    ///
    /// An entry needs a published **limit**: it is the only figure that makes a
    /// balance a balance rather than a spend figure wearing a balance label,
    /// which is the wrong-label defect this codebase already shipped once. So a
    /// pool with no limit yields no entry — nothing is inferred from `used`
    /// alone. A pool that published a limit and has spent past it is a
    /// different case, and a measured one: its limit and used figures are both
    /// present, so its remaining headroom is a real zero and the entry says so.
    /// The account with none of its allowance left is the one most worth
    /// showing, and absence of the figure is kept for the payload that withheld
    /// it.
    static func apiCredits(from usage: ClaudeOAuthUsageResponse) -> [APICreditEntry] {
        var entries: [APICreditEntry] = []

        if let credit = usage.monthlyCredit, let limit = credit.limit {
            // `remaining` is nil only when the pool is over its limit: the
            // payload's own limit and used figures are both present and their
            // difference is a real zero rather than a missing reading.
            let remaining = credit.remaining ?? 0
            entries.append(APICreditEntry(
                id: "claude.extra-usage",
                vendorId: .claude,
                label: "Extra usage",
                metric: .currency(balance: remaining, limit: limit, spent: nil,
                                  currencyCode: credit.currencyCode),
                currencyBasis: .prepaidCredit,
                detail: "\(money(limit, credit.currencyCode)) monthly limit",
                source: "OAuth usage payload · \(credit.source.rawValue)"
            ))
        }

        // The promo credit states its own remaining figure; falling back to
        // `limit - used` covers a payload that withheld only the total, and
        // yields nothing when it withheld enough that neither can be known.
        // A figure the payload did publish is taken only when it cannot be
        // negative: `-3` of a promo credit is not money that is left, and
        // printing it under a balance label is the mislabelled figure this
        // function already refuses the derived way below zero. The two agree.
        if let promo = usage.promoCredit {
            let derived = promo.limitDollars.flatMap { limit in
                promo.usedDollars.flatMap { used in limit >= used ? limit - used : nil }
            }
            let published = promo.remainingDollars.flatMap { $0 >= 0 ? $0 : nil }
            if let remaining = published ?? derived {
                entries.append(APICreditEntry(
                    id: "claude.promo-credit",
                    vendorId: .claude,
                    label: "Promo credit",
                    metric: .currency(balance: remaining, limit: promo.limitDollars, spent: nil,
                                      currencyCode: "USD"),
                    currencyBasis: .prepaidCredit,
                    detail: promo.resetsAt
                        .flatMap(CLIProxyClient.parseResetDate)
                        .map { "Subscription month ends \(Self.shortDate($0))" } ?? "Cloud-session credit",
                    source: "OAuth usage payload · iguana_necktie",
                    monthlyPeriodEnd: promo.resetsAt.flatMap(CLIProxyClient.parseResetDate)
                ))
            }
        }

        return entries
    }

    /// A money figure for a caption, in the vendor's own currency. Routed
    /// through `MoneyText` so the vendor's own note ("$200.00 monthly limit")
    /// and the figure drawn beside it ("$179.50") are chosen by one rule —
    /// `NumberFormatter` consulted the process locale, which made a card say
    /// "USD 179.50" above a note that said "$200.00".
    static func money(_ amount: Decimal, _ currencyCode: String) -> String {
        MoneyText.format(amount, code: currencyCode)
    }

    /// An absolute date, so an expiry never reads as a countdown to a refill.
    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// The row caption, with the banked-reset count appended when Anthropic
    /// published one. Mirrors the OpenAI row so the two read the same way.
    static func auxiliaryInfo(grants: ClaudeOAuthUsageResponse.ResetGrants?) -> String {
        var info = "Live Claude subscription quota"
        guard let banked = grants?.resetsAvailable, banked > 0 else { return info }
        info += " · \(banked) reset credit\(banked == 1 ? "" : "s") banked"
        if let usable = grants?.resetsUsableNow, usable > 0 {
            info += " · \(usable) redeemable now"
        }
        return info
    }

    struct Reading { let used: Double; let reset: Date? }

    /// The API has reported utilization both as a 0…1 fraction and as a
    /// percentage. Accept either rather than discarding a real reading.
    private static func reading(_ window: ClaudeOAuthUsageResponse.Window) -> Reading? {
        let used = window.utilization > 1 ? window.utilization / 100 : window.utilization
        guard (0...1).contains(used) else { return nil }
        return Reading(used: used, reset: CLIProxyClient.parseResetDate(window.resetsAt))
    }

    /// `window` is the length Anthropic meters this reading over. It turns the
    /// reset time into the pro-rata pace marker — the share of the allowance
    /// that should be spent by now. Without it the bar drew a fixed marker that
    /// described no window at all.
    private func row(_ reading: Reading, label: String, window: TimeInterval, now: Date = Date()) -> DualBarMetrics {
        let expectedPace: Double?
        let resetText: String?
        if let reset = reading.reset {
            expectedPace = DualBarMetrics.proRataPace(resetsAt: reset, windowLength: window, now: now)
            resetText = "Resets \(RelativeDateTimeFormatter().localizedString(for: reset, relativeTo: now))"
        } else {
            expectedPace = nil
            resetText = nil
        }
        return DualBarMetrics(primaryFraction: reading.used,
                       expectedPaceFraction: expectedPace,
                       label: label,
                       usedText: "\(Int((reading.used * 100).rounded()))% used",
                       resetText: resetText,
                       resetsAt: reading.reset, windowLength: window)
    }
}

/// A relayed throttle belongs to the proxy credential even when the direct
/// credential succeeds. In-memory only, with one configured proxy retained;
/// neither configuration nor credentials are written to logs or preferences.
public actor ClaudeProxyBackoff {
    static let shared = ClaudeProxyBackoff()
    private var configuration: CLIProxyConfig?
    private var until: Date?
    private var directTokenDigest: SHA256.Digest?
    private var directUntil: Date?

    public init() {}

    func retryAfter(config: CLIProxyConfig, now: Date) -> Date? {
        guard configuration?.url == config.url,
              configuration?.managementKey == config.managementKey,
              let until, now < until else { return nil }
        return until
    }

    func directRetryAfter(token: String, now: Date) -> Date? {
        guard directTokenDigest == SHA256.hash(data: Data(token.utf8)), let directUntil, now < directUntil else { return nil }
        return directUntil
    }

    func recordDirect(_ reason: UnavailableReason?, token: String) {
        let digest = SHA256.hash(data: Data(token.utf8))
        if directTokenDigest != digest { directUntil = nil }
        directTokenDigest = digest
        if case .rateLimited(let retryAfter)? = reason {
            if let retryAfter { directUntil = max(directUntil ?? retryAfter, retryAfter) }
        } else if reason == nil {
            directUntil = nil
        }
    }

    func record(_ reason: UnavailableReason?, config: CLIProxyConfig) {
        let sameCredential = configuration?.url == config.url
            && configuration?.managementKey == config.managementKey
        if !sameCredential { until = nil }
        configuration = config
        if case .rateLimited(let retryAfter)? = reason {
            if let retryAfter { until = max(until ?? retryAfter, retryAfter) }
        } else if reason == nil {
            // Only a success retracts a throttle. A failed manual probe does
            // not give the automatic poll permission to ignore Retry-After.
            until = nil
        }
    }
}
