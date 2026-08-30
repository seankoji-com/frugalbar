import Foundation

/// Memoises the fetched-and-ranked OpenRouter model catalog behind a TTL so
/// repeated polls don't each re-fetch and re-rank the same public catalog.
/// Deliberately process-lifetime state, not a second cache layer with disk
/// persistence — a cold app launch always fetches fresh.
actor ModelCatalogCache {

    static let shared = ModelCatalogCache()

    private var cached: (sessionKey: ObjectIdentifier, badges: OpenRouterProvider.ModelBadges, at: Date)?

    /// Returns the memoised badges if they're younger than `ttl` and were
    /// fetched through the same `URLSession` the caller is using now,
    /// otherwise runs `fetch` and caches the result.
    ///
    /// Keyed on the session's identity rather than being a single unkeyed
    /// slot: production always resolves `QuotaHTTP.session` to the same
    /// long-lived instance, so this is a plain multi-hour cache there, but a
    /// test that swaps in its own stub session via
    /// `QuotaHTTP.$session.withValue(_:)` gets a fresh key and therefore a
    /// guaranteed cache miss — it can never read back another test's stub
    /// response. Deliberately does not coalesce concurrent misses onto one
    /// in-flight call either, for the same reason: an actor hop preserves
    /// the caller's own task-local session, and joining another caller's
    /// in-flight future would hand back a result fetched under *that*
    /// caller's session instead.
    fileprivate func badges(
        sessionKey: ObjectIdentifier,
        ttl: TimeInterval,
        fetch: @Sendable @escaping () async -> OpenRouterProvider.ModelBadges
    ) async -> OpenRouterProvider.ModelBadges {
        if let cached, cached.sessionKey == sessionKey,
           Date().timeIntervalSince(cached.at) < ttl {
            return cached.badges
        }
        let badges = await fetch()
        cached = (sessionKey, badges, Date())
        return badges
    }

    /// Test hook — drops memoised state between cases.
    func reset() {
        cached = nil
    }
}

/// OpenRouter credit provider — `GET /api/v1/auth/key`.
///
/// Contract notes, because a previous revision misread all three:
///  - `limit` is the **spend cap on this key**, not the account balance, and
///    it is `null` when the key is uncapped (the default).
///  - `limit_remaining` is headroom under that cap, also `null` when uncapped.
///  - `usage` is credits consumed **since the key was created** (all time). It
///    never resets, so it is not a billing-period figure.
///
/// The account's real credit balance is only available from
/// `GET /api/v1/credits`, which requires a provisioning key we do not hold.
///
/// Therefore: with a cap we can draw a real gauge; without one we report spend
/// and draw no gauge, because there is no denominator. We never invent a cap.
public final class OpenRouterProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .openrouter
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .apiSpendAndCredits

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        // The catalog fetch needs no key, so it starts concurrently with the
        // (possibly key-gated) primary snapshot rather than after it.
        async let badgesTask = Self.fetchModelBadges()
        var snapshot = try await fetchPrimarySnapshot()
        let badges = await badgesTask
        snapshot.freeTierModelBadge = badges.freeTier
        snapshot.cheapestLargeContextModelBadge = badges.cheapestLargeContext
        return snapshot
    }

    private func fetchPrimarySnapshot() async throws -> QuotaSnapshot {
        guard let key = await credential(injected: apiKey, for: .openrouter) else {
            return unavailable(.notConfigured)
        }

        let (data, http) = try await QuotaHTTP.get(
            url: "https://openrouter.ai/api/v1/auth/key",
            auth: .bearer(key)
        )

        if http.statusCode == 429 {
            // A 429 on this metadata endpoint tells us nothing about the
            // user's credit balance, so it is an absent reading rather than a
            // critical quota.
            return unavailable(.rateLimited(retryAfter: Self.retryAfter(from: http)))
        }
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) {
            return unavailable(reason)
        }

        struct Response: Decodable, Sendable {
            struct Payload: Decodable, Sendable {
                let usage: Double?
                let usage_daily: Double?
                let usage_weekly: Double?
                let usage_monthly: Double?
                let limit: Double?
                let limit_remaining: Double?
                let is_free_tier: Bool?
                let is_management_key: Bool?
                let creator_user_id: String?
            }
            let data: Payload
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return unavailable(.badResponse)
        }

        guard let spentUsd = decoded.data.usage else {
            return unavailable(.badResponse)
        }

        // Spend per window, straight from `/auth/key`. These are this key's
        // figures; the credit balance below is account-wide, so the two are
        // different scopes and are labelled as such rather than combined.
        // A window the API omits stays nil and renders as an absence.
        let spendWindows = [
            SpendWindow(label: "1D", amount: decoded.data.usage_daily.map { Decimal($0) },
                        currencyCode: "USD"),
            SpendWindow(label: "WK", amount: decoded.data.usage_weekly.map { Decimal($0) },
                        currencyCode: "USD"),
        ]

        // Credits are authoritative when the supplied key can read them. If
        // this endpoint rejects a normal key, fall back to that key's cap.
        //
        // Best-effort on purpose: we already hold a good reading from
        // /auth/key, and losing it because an *enrichment* call timed out
        // would turn a working gauge into an error.
        let creditsResult = try? await QuotaHTTP.get(
            url: "https://openrouter.ai/api/v1/credits",
            auth: .bearer(key)
        )
        if let (creditsData, creditsHTTP) = creditsResult,
           (200...299).contains(creditsHTTP.statusCode) {
            struct CreditsResponse: Decodable {
                struct Payload: Decodable {
                    let total_credits: Double?
                    let total_usage: Double?
                }
                let data: Payload
            }
            if let credits = try? JSONDecoder().decode(CreditsResponse.self, from: creditsData),
               let purchased = credits.data.total_credits,
               let used = credits.data.total_usage,
               purchased >= 0, used >= 0 {
                let balance = max(purchased - used, 0)
                // Credit has no denominator to draw a gauge from, but a nearly
                // empty account is exactly what this app exists to warn about.
                // Thresholds are on the absolute balance, in dollars.
                let urgency: Urgency = balance < 1 ? .critical : balance < 5 ? .warning : .none
                var snapshot = QuotaSnapshot(
                    id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
                    category: category,
                    metric: .currency(balance: Decimal(balance), limit: nil,
                                      spent: Decimal(used), currencyCode: "USD"),
                    status: .measured(urgency), resetsAt: nil, lastUpdated: Date(),
                    auxiliaryInfo: "Account credit balance",
                    row1: nil, row2: nil,
                    badgeText: "\(String(format: "$%.2f", balance)) credit",
                    planName: nil, cliSource: "OPENROUTER_API_KEY / auth.json",
                    currencyBasis: .accountCredit
                )
                snapshot.spendWindows = spendWindows
                return snapshot
            }
        }
        let tierNote = decoded.data.is_free_tier == true ? "Free tier" : nil

        // `usage` never resets, so presenting it as a weekly figure would be a
        // fabricated number by this project's own definition.
        let weeklySpentUsd = decoded.data.usage_weekly ?? spentUsd
        let spendBadge = decoded.data.usage_weekly.map { String(format: "$%.2f this week", $0) }
            ?? String(format: "$%.2f lifetime", spentUsd)

        guard let capUsd = decoded.data.limit, capUsd > 0 else {
            var snapshot = QuotaSnapshot(
                id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
                category: category,
                metric: .currency(balance: Decimal(spentUsd), limit: nil,
                                  spent: Decimal(weeklySpentUsd), currencyCode: "USD"),
                status: .measured(.none),
                resetsAt: nil, lastUpdated: Date(),
                auxiliaryInfo: tierNote ?? "Key lifetime spend: \(String(format: "$%.2f", spentUsd))",
                row1: nil,
                row2: nil,
                badgeText: spendBadge,
                planName: nil,
                cliSource: "OPENROUTER_API_KEY / auth.json",
                currencyBasis: .lifetimeSpend
            )
            snapshot.spendWindows = spendWindows
            return snapshot
        }

        let remainingUsd = decoded.data.limit_remaining ?? max(capUsd - spentUsd, 0)

        let consumed = min(max((capUsd - remainingUsd) / capUsd, 0), 1)
        let urgency: Urgency = consumed > 0.90 ? .critical
                             : consumed > 0.70 ? .warning
                             : .none

        let remainingFormatted = String(format: "$%.2f", remainingUsd)

        var snapshot = QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category,
            metric: .currency(balance: Decimal(remainingUsd), limit: Decimal(capUsd),
                              spent: Decimal(weeklySpentUsd), currencyCode: "USD"),
            status: .measured(urgency),
            resetsAt: nil, lastUpdated: Date(),
            auxiliaryInfo: tierNote ?? "Key spend cap, not account credit",
            row1: nil,
            row2: nil,
            badgeText: "\(remainingFormatted) key cap left",
            planName: nil,
            cliSource: "OPENROUTER_API_KEY / auth.json",
            currencyBasis: .keySpendCap
        )
        snapshot.spendWindows = spendWindows
        return snapshot
    }







    private static func retryAfter(from http: HTTPURLResponse) -> Date? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    // MARK: - Model catalog badges

    /// One entry from `GET /api/v1/models`, OpenRouter's public model
    /// catalog. `pricing`/`context_length` are optional because a model
    /// missing either is excluded from both badge rankings below — never
    /// treated as `0` or as qualifying.
    private struct ModelCatalogEntry: Decodable, Sendable {
        struct Pricing: Decodable, Sendable {
            let prompt: String?
            let completion: String?
        }
        let id: String
        let name: String?
        let context_length: Int?
        let pricing: Pricing?
    }

    private struct ModelCatalogResponse: Decodable, Sendable {
        let data: [ModelCatalogEntry]
    }

    /// The two badge strings, or nil each when the catalog call failed or no
    /// model qualified. Never fabricated — every field comes straight off a
    /// real catalog entry.
    fileprivate struct ModelBadges: Sendable {
        var freeTier: String?
        var cheapestLargeContext: String?
    }

    private struct RankedModel {
        let id: String
        let name: String
        let contextLength: Int
        let promptPrice: Double
        let completionPrice: Double
    }

    /// How long a fetched-and-ranked catalog stays valid before the next
    /// call re-fetches. The public model list changes on the order of days,
    /// not seconds, so a multi-hour TTL trades a little staleness for
    /// sparing every poll of every OpenRouter provider instance a redundant
    /// `/api/v1/models` round trip and re-rank.
    static let catalogTTL: TimeInterval = 4 * 60 * 60

    /// Best-effort fetch of the free/cheap-model badges from OpenRouter's
    /// public catalog, which needs no key. Bounded to a deadline well under
    /// `CachePolicy.perProviderTimeout` (10s) so a slow-but-not-erroring
    /// `/api/v1/models` response can never ride the outer per-provider
    /// deadline down to a generic `.timedOut` — including on the no-key fast
    /// path, where `fetchPrimarySnapshot()` already has its real answer
    /// (`.notConfigured`) instantly and shouldn't be held hostage by this
    /// enrichment call. `withDeadline` races the fetch against its own
    /// timer; a miss here simply yields empty badges, exactly like the
    /// `try?` failure path it wraps.
    private static func fetchModelBadges() async -> ModelBadges {
        let sessionKey = ObjectIdentifier(QuotaHTTP.session)
        let outcome = await withDeadline(seconds: 5) {
            await ModelCatalogCache.shared.badges(sessionKey: sessionKey, ttl: catalogTTL) {
                await fetchModelBadgesFromCatalog()
            }
        }
        switch outcome {
        case .success(let badges):
            return badges
        case .failure:
            // The wrapped fetch never throws, so a `.failure` here is always
            // the 5s deadline itself elapsing. Logged so a degraded/slow
            // catalog is distinguishable in the unified log from the
            // legitimate "fetched fine, nothing qualified" case below, which
            // stays silent on purpose.
            NSLog("frugalbar: OpenRouter model-catalog fetch timed out after 5s; badges omitted this poll")
            return ModelBadges()
        }
    }

    private static func fetchModelBadgesFromCatalog() async -> ModelBadges {
        guard let result = try? await QuotaHTTP.get(url: "https://openrouter.ai/api/v1/models"),
              (200...299).contains(result.1.statusCode),
              let decoded = try? JSONDecoder().decode(ModelCatalogResponse.self, from: result.0)
        else {
            // Distinct from a genuine zero-match: this is a network/HTTP/
            // decode failure, not "fetched fine, no model qualified."
            NSLog("frugalbar: OpenRouter model-catalog fetch failed or returned an unparseable body; badges omitted this poll")
            return ModelBadges()
        }

        // A model with a missing/unparseable context_length or pricing is
        // dropped from consideration entirely — it never becomes a `0` or a
        // false qualifier for either ranking.
        let candidates: [RankedModel] = decoded.data.compactMap { entry in
            guard let pricing = entry.pricing,
                  let promptStr = pricing.prompt, let promptPrice = Double(promptStr),
                  let completionStr = pricing.completion, let completionPrice = Double(completionStr),
                  let contextLength = entry.context_length
            else { return nil }
            return RankedModel(
                id: entry.id, name: entry.name ?? entry.id, contextLength: contextLength,
                promptPrice: promptPrice, completionPrice: completionPrice
            )
        }

        // Badge 1: $0 prompt AND $0 completion, largest context wins. Ties
        // broken alphabetically by id for determinism.
        let free = candidates
            .filter { $0.promptPrice == 0.0 && $0.completionPrice == 0.0 }
            .min { lhs, rhs in
                lhs.contextLength != rhs.contextLength
                    ? lhs.contextLength > rhs.contextLength
                    : lhs.id < rhs.id
            }

        // Badge 2: strictly-paid (completion > 0) with context >= 1M,
        // cheapest $/M completion tokens wins. Ties broken alphabetically.
        let cheap = candidates
            .filter { $0.completionPrice > 0.0 && $0.contextLength >= 1_000_000 }
            .min { lhs, rhs in
                lhs.completionPrice != rhs.completionPrice
                    ? lhs.completionPrice < rhs.completionPrice
                    : lhs.id < rhs.id
            }

        return ModelBadges(
            freeTier: free.map { "Free · \($0.name) (\(abbreviateContext($0.contextLength)) ctx)" },
            cheapestLargeContext: cheap.map {
                "\(formatPricePerMillion($0.completionPrice)) · \($0.name) (\(abbreviateContext($0.contextLength)) ctx)"
            }
        )
    }

    /// Abbreviates a token count for a compact badge: `128000` → `"128K"`,
    /// `1000000` → `"1M"`, `10000000` → `"10M"`.
    private static func abbreviateContext(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let millions = Double(tokens) / 1_000_000
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        if tokens >= 1_000 {
            let thousands = Double(tokens) / 1_000
            return thousands == thousands.rounded() ? "\(Int(thousands))K" : String(format: "%.1fK", thousands)
        }
        return "\(tokens)"
    }

    /// OpenRouter publishes price per token in USD; badges read as $/M tokens.
    private static func formatPricePerMillion(_ perToken: Double) -> String {
        String(format: "$%.2f/M", perToken * 1_000_000)
    }
}
