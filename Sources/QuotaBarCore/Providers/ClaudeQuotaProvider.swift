import Foundation

/// Claude subscription quota from Anthropic's OAuth usage endpoint, read via
/// CLI Proxy or directly with the Claude Code OAuth token. Derived from
/// claude-rate-monitor (MIT).
public final class ClaudeQuotaProvider: QuotaProvider, Sendable {
    public let vendorId: VendorIdentifier = .claude
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions
    private let apiKey: String?
    private let cliProxyConfig: CLIProxyConfig?
    /// Resolves the *direct* Claude Code OAuth token — the one this Mac's own
    /// `claude` login holds, as opposed to whatever the proxy holds.
    private let directCredential: @Sendable () async -> String?

    public init(
        apiKey: String? = nil,
        cliProxyConfig: CLIProxyConfig? = nil,
        // Injectable so a test can drive the proxy-failure fall-through below
        // without reading the developer's own Claude login out of the Keychain.
        // Nil means the production path: this Mac's Claude Code credential.
        directCredential: (@Sendable () async -> String?)? = nil
    ) {
        self.apiKey = apiKey
        self.cliProxyConfig = cliProxyConfig
        self.directCredential = directCredential
            ?? { await CredentialStore.apiKeyAsync(for: .claude) }
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        try await fetchSnapshot(now: Date())
    }

    func fetchSnapshot(now: Date) async throws -> QuotaSnapshot {
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
            do {
                return try await fetchSnapshotViaProxy(config: proxyConfig, now: now)
            } catch let error as ProviderError {
                proxyFailure = error.reason
            } catch {
                // Transport or connection failure: nothing about either
                // credential has been established, so fall through to the
                // direct token with nothing to report yet.
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
        let (data, response) = try await QuotaHTTP.get(
            url: CLIProxyClient.claudeOAuthUsageWithGrantsURL,
            headers: ["Accept": "application/json", "anthropic-beta": "oauth-2025-04-20"],
            auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(
            for: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"), now: now) {
            NSLog("frugalbar: Claude OAuth usage request returned %ld (%@)",
                  response.statusCode, String(describing: reason))
            return unavailable(reason)
        }
        guard let usage = try? JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data) else {
            NSLog("frugalbar: Claude OAuth usage body failed to decode (%ld bytes)", data.count)
            return unavailable(.badResponse)
        }
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
        return snapshot
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
