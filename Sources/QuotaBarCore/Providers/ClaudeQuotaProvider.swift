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

    public init(apiKey: String? = nil, cliProxyConfig: CLIProxyConfig? = nil) {
        self.apiKey = apiKey
        self.cliProxyConfig = cliProxyConfig
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
        if let proxyConfig {
            do {
                return try await fetchSnapshotViaProxy(config: proxyConfig, now: now)
            } catch let error as ProviderError {
                if error.reason == .credentialRejected || error.reason == .rateLimited(retryAfter: nil) {
                    return unavailable(error.reason)
                }
            } catch {
                // If proxy call failed with transport or connection error, fall through to direct token.
            }
        }

        guard let token = await credential(injected: nil, for: .claude) else {
            return unavailable(.notConfigured)
        }
        return try await fetchSnapshotDirect(token: token, now: now)
    }

    private func fetchSnapshotViaProxy(config: CLIProxyConfig, now: Date) async throws -> QuotaSnapshot {
        let (usage, _) = try await CLIProxyClient.fetchClaudeUsage(config: config)
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
            url: CLIProxyClient.claudeOAuthUsageURL,
            headers: ["Accept": "application/json", "anthropic-beta": "oauth-2025-04-20"],
            auth: .bearer(token)
        )
        if let reason = QuotaHTTP.failureReason(for: response.statusCode) { return unavailable(reason) }
        guard let usage = try? JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data) else {
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
        // A model-scoped weekly cap only blocks that model, so it is shown but
        // does not drive the badge or urgency, which describe the whole plan.
        let row3 = modelWeeklyRow(usage, now: now)

        let remainingPercent = max(0, Int(((1 - worst) * 100).rounded()))
        let badgeText = "\(remainingPercent)% left"
        let primaryReset = row1?.resetsAt ?? row2?.resetsAt

        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: planName ?? "Claude", renewalDate: nil),
            status: .measured(urgency), resetsAt: primaryReset, lastUpdated: now,
            auxiliaryInfo: "Live Claude subscription quota",
            row1: row1,
            row2: row2,
            row3: row3,
            badgeText: badgeText,
            planName: planName, cliSource: cliSource
        )
    }

    struct Reading { let used: Double; let reset: Date? }

    /// The API has reported utilization both as a 0…1 fraction and as a
    /// percentage. Accept either rather than discarding a real reading.
    private static func reading(_ window: ClaudeOAuthUsageResponse.Window) -> Reading? {
        let used = window.utilization > 1 ? window.utilization / 100 : window.utilization
        guard (0...1).contains(used) else { return nil }
        return Reading(used: used, reset: CLIProxyClient.parseResetDate(window.resetsAt))
    }

    /// The fuller of the Opus and Sonnet weekly windows, when either is reported.
    private func modelWeeklyRow(_ usage: ClaudeOAuthUsageResponse, now: Date) -> DualBarMetrics? {
        let candidates = [
            usage.sevenDayOpus.flatMap(Self.reading).map { ($0, "OP") },
            usage.sevenDaySonnet.flatMap(Self.reading).map { ($0, "SN") },
        ].compactMap { $0 }
        guard let (reading, label) = candidates.max(by: { $0.0.used < $1.0.used }) else { return nil }
        return row(reading, label: label, window: QuotaWindow.week, now: now)
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
