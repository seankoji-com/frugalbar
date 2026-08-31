import Foundation

/// Grok subscription usage, read from the billing backend the Grok CLI uses.
///
/// `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, carrying
/// the CLI's own bearer token plus the `x-xai-token-auth: xai-grok-cli` header
/// the proxy requires. The grok.com gRPC-web endpoint is not an option: it now
/// demands a browser-held keypair no menu bar app can produce.
///
/// The token comes from `~/.grok/auth.json`, so this reports only what the
/// user is already signed in to — and, like every other local credential
/// FrugalBar reads, only once CLI discovery is switched on in
/// Preferences → General.
///
/// The CLI mints short-lived tokens (roughly six hours) and refreshes them
/// itself. FrugalBar deliberately does not: writing to `auth.json` behind the
/// CLI's back risks invalidating the session the user is actively working in.
/// An expired token surfaces as "Credential rejected", which running `grok`
/// clears.
public final class GrokQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .grok
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let accessToken: String?

    public init(accessToken: String? = nil) {
        self.accessToken = accessToken
    }

    static let billingURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"

    /// The plan name lives here, not on the billing response — `/v1/billing`
    /// carries the numbers and says nothing about which tier produced them.
    static let settingsURL = "https://cli-chat-proxy.grok.com/v1/settings"

    /// The proxy rejects a bearer token that does not also declare which client
    /// it was minted for.
    static let clientHeader = (name: "x-xai-token-auth", value: "xai-grok-cli")

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let token = await credential(injected: accessToken, for: .grok) else {
            return unavailable(.notConfigured)
        }

        // Issued together: the plan name is a second endpoint, and serialising
        // them would add its latency to every refresh for a string that
        // changes about once a year.
        //
        // The settings fetch is bounded by its own short deadline, separate
        // from the provider's own — it is best-effort by design (a label,
        // never thrown on failure), and without its own bound a slow or hung
        // `/v1/settings` could consume the whole per-provider budget and flip
        // the entire vendor to `.timedOut` even though `/v1/billing` already
        // came back with a valid gauge.
        async let billing = QuotaHTTP.get(
            url: Self.billingURL,
            headers: [
                Self.clientHeader.name: Self.clientHeader.value,
                "Accept": "application/json",
            ],
            auth: .bearer(token)
        )
        async let tierNameOutcome = withDeadline(seconds: 2) { await Self.fetchPlanName(token: token) }

        let (data, http) = try await billing
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) { return unavailable(reason) }

        guard let response = try? JSONDecoder().decode(BillingResponse.self, from: data),
              let config = response.config
        else { return unavailable(.badResponse) }

        let planOverride: String? = if case .success(let name) = await tierNameOutcome { name } else { nil }

        return Self.snapshot(
            from: config,
            tier: response.subscriptionTier,
            planOverride: planOverride,
            provider: self,
            now: Date()
        )
    }

    /// Reads `subscription_tier_display` from the CLI settings envelope.
    ///
    /// Best-effort on purpose: a plan name is a label, and losing it must never
    /// cost the user the usage gauge they actually came for. Every failure path
    /// returns nil rather than throwing.
    static func fetchPlanName(token: String) async -> String? {
        // Every failure path returns nil identically to the caller, but each
        // is logged once here — otherwise a broken endpoint is indistinguishable
        // from a vendor that simply publishes no plan name, and nothing
        // signals *when* the settings endpoint starts failing versus a
        // payload shape changing underneath it.
        guard let (data, http) = try? await QuotaHTTP.get(
            url: Self.settingsURL,
            headers: [
                Self.clientHeader.name: Self.clientHeader.value,
                "Accept": "application/json",
            ],
            auth: .bearer(token)
        ) else {
            NSLog("frugalbar: Grok plan-name request failed — network error or no response")
            return nil
        }
        guard http.statusCode == 200 else {
            NSLog("frugalbar: Grok plan-name request returned status \(http.statusCode)")
            return nil
        }
        guard let settings = try? JSONDecoder().decode(SettingsResponse.self, from: data) else {
            NSLog("frugalbar: Grok plan-name response failed to decode")
            return nil
        }
        return planDisplayName(settings.subscriptionTierDisplay)
    }

    // MARK: - Snapshot construction

    static func snapshot(
        from config: BillingConfig,
        tier: String?,
        planOverride: String? = nil,
        provider: GrokQuotaProvider,
        now: Date
    ) -> QuotaSnapshot {
        let periodEnd = config.currentPeriod?.end.flatMap(parseISO8601)
            ?? config.billingPeriodEnd.flatMap(parseISO8601)
        let periodStart = config.currentPeriod?.start.flatMap(parseISO8601)
            ?? config.billingPeriodStart.flatMap(parseISO8601)

        // xAI states the period explicitly, so the pace marker is measured
        // rather than assumed — the window is weekly on some plans and monthly
        // on others, and guessing either would misplace every marker.
        let windowLength: TimeInterval? = {
            guard let periodStart, let periodEnd else { return nil }
            let length = periodEnd.timeIntervalSince(periodStart)
            return length > 0 ? length : nil
        }()

        let planName = planOverride ?? planDisplayName(config.subscriptionTier ?? tier)

        // `creditUsagePercent` is the plan gauge, and the only thing that may
        // drive it — on-demand spend is a different denominator (dollars
        // against a spend cap, not credits against a plan allowance) and is
        // drawn only as its own `OD` bar below, never promoted into the
        // headline. A plan with no percentage but a live on-demand cap used
        // to fall back to the OD ratio here, which then showed the same
        // number twice: once mislabeled as plan usage (headline gauge,
        // badge, row1 "% used"), and again correctly as the OD bar.
        let fraction: Double? = config.creditUsagePercent.flatMap { percent in
            percent.isFinite ? min(max(percent / 100, 0), 1) : nil
        }

        // No usage figure and no period is nothing to draw. Saying so beats a
        // zeroed bar that reads as "plenty left".
        guard fraction != nil || periodEnd != nil else {
            return provider.unavailable(.unsupported("Grok reported no billing period"))
        }

        let windowLabel = periodLabel(config.currentPeriod?.type, windowLength: windowLength)
        let resetText = periodEnd.map {
            "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))"
        }

        // On-demand spend is a separate budget that only exists once the user
        // has enabled it, and it is billed on top of the plan — drawn as its
        // own bar regardless of whether the plan itself reported a usage
        // percentage, never folded into the headline gauge above.
        let odRow: DualBarMetrics? = {
            guard let cap = config.onDemandCap?.val, cap > 0, cap.isFinite,
                  let used = config.onDemandUsed?.val, used.isFinite
            else { return nil }
            return DualBarMetrics(
                primaryFraction: min(max(used / cap, 0), 1),
                label: "OD",
                usedText: "\(SubscriptionCycle.formatCost(Decimal(used), currencyCode: "USD"))"
                    + " of \(SubscriptionCycle.formatCost(Decimal(cap), currencyCode: "USD")) cap used",
                resetText: resetText,
                resetsAt: periodEnd,
                windowLength: windowLength
            )
        }()

        guard let fraction else {
            // A period with no usage number: report the cycle honestly and
            // leave the gauge unmeasured rather than inventing a percentage.
            // The on-demand bar, if any, still draws — it is a real,
            // independently-measured figure regardless of whether the plan
            // published one.
            var snapshot = QuotaSnapshot(
                id: provider.vendorId.rawValue,
                vendorId: provider.vendorId,
                displayName: provider.displayName,
                category: provider.category,
                metric: .subscription(tierName: planName ?? "Grok", renewalDate: periodEnd),
                status: .unavailable(.unsupported("Grok published no usage figure")),
                resetsAt: periodEnd,
                lastUpdated: now,
                auxiliaryInfo: "Grok billing period",
                row1: DualBarMetrics(
                    primaryFraction: nil,
                    label: windowLabel,
                    usedText: "Usage not published",
                    resetText: resetText,
                    resetsAt: periodEnd,
                    windowLength: windowLength
                ),
                planName: planName,
                cliSource: "grok CLI"
            )
            snapshot.row2 = odRow
            return snapshot
        }

        let urgency: Urgency = fraction >= 0.95 ? .critical
            : fraction >= 0.80 ? .warning
            : .none
        let percentUsed = Int((fraction * 100).rounded())

        var snapshot = QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .percentage(usedFraction: fraction, displayDetails: nil),
            status: .measured(urgency),
            resetsAt: periodEnd,
            lastUpdated: now,
            auxiliaryInfo: "Grok subscription credits",
            row1: DualBarMetrics(
                primaryFraction: fraction,
                expectedPaceFraction: windowLength.flatMap {
                    DualBarMetrics.proRataPace(resetsAt: periodEnd, windowLength: $0, now: now)
                },
                label: windowLabel,
                usedText: "\(percentUsed)% used",
                resetText: resetText,
                resetsAt: periodEnd,
                windowLength: windowLength
            ),
            badgeText: fraction >= 1.0 ? "Exhausted" : "\(100 - percentUsed)% left",
            planName: planName,
            cliSource: "grok CLI"
        )

        snapshot.row2 = odRow

        return snapshot
    }

    /// xAI names the period on the response; the length is only a fallback for
    /// an unrecognised name, and stays coarse enough not to mislabel.
    static func periodLabel(_ type: String?, windowLength: TimeInterval?) -> String {
        switch type?.uppercased() {
        case "USAGE_PERIOD_TYPE_WEEKLY":  return "WK"
        case "USAGE_PERIOD_TYPE_MONTHLY": return "MO"
        case "USAGE_PERIOD_TYPE_DAILY":   return "1D"
        default: break
        }
        guard let windowLength else { return "CR" }
        switch windowLength {
        case ..<(2 * 86_400):  return "1D"
        case ..<(10 * 86_400): return "WK"
        default:               return "MO"
        }
    }

    /// The wire form is a tier token; these are the labels xAI markets.
    static func planDisplayName(_ raw: String?) -> String? {
        let trimmed = raw?.trimmed ?? ""
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased().filter(\.isLetter) {
        case "supergrokheavy", "heavy": return "SuperGrok Heavy"
        case "supergrok":               return "SuperGrok"
        default:                        return trimmed
        }
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    // MARK: - Response shape

    struct SettingsResponse: Decodable, Sendable {
        let subscriptionTierDisplay: String?

        enum CodingKeys: String, CodingKey {
            case subscriptionTierDisplay = "subscription_tier_display"
        }
    }

    struct BillingResponse: Decodable, Sendable {
        let config: BillingConfig?
        let subscriptionTier: String?
    }

    struct BillingConfig: Decodable, Sendable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
        let onDemandCap: Amount?
        let onDemandUsed: Amount?
        let subscriptionTier: String?
    }

    struct Period: Decodable, Sendable {
        let type: String?
        let start: String?
        let end: String?
    }

    /// The proxy reports amounts as `{ "val": <number> }`. Decoded as a Double
    /// so an unexpected fractional value cannot fail an otherwise good payload.
    struct Amount: Decodable, Sendable {
        let val: Double?
    }
}

// MARK: - CLI credential

extension GrokQuotaProvider {

    /// Reads the Grok CLI's cached OIDC access token.
    ///
    /// `auth.json` is a map keyed by issuer+client, one entry per login. The
    /// newest unexpired entry wins: a stale entry left behind by an earlier
    /// login would otherwise send a token the proxy has already rejected.
    static func discoverCLIToken(
        authURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json"),
        now: Date = Date()
    ) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let entries: [(token: String, expiry: Date?)] = root.values.compactMap { value in
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty
            else { return nil }
            let expiry = (entry["expires_at"] as? String).flatMap(parseISO8601)
            return (token, expiry)
        }
        guard !entries.isEmpty else { return nil }

        // Prefer a live token; fall back to the freshest expired one so the
        // provider can report "Credential rejected" rather than the much
        // vaguer "Not configured" for a user who is simply signed out.
        let unexpired = entries.filter { ($0.expiry ?? .distantFuture) > now }
        let pool = unexpired.isEmpty ? entries : unexpired
        return pool.max { ($0.expiry ?? .distantPast) < ($1.expiry ?? .distantPast) }?.token
    }
}
