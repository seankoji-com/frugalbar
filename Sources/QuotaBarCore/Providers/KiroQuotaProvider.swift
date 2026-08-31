import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Kiro credit usage, read from the service the Kiro CLI itself calls.
///
/// `POST https://codewhisperer.us-east-1.amazonaws.com/` with
/// `X-Amz-Target: AmazonCodeWhispererService.GetUsageLimits` — an AWS JSON 1.0
/// endpoint, authenticated with the bearer token the CLI already holds.
///
/// The credential comes from the CLI's own state database at
/// `~/Library/Application Support/kiro-cli/data.sqlite3`: the access token
/// lives in `auth_kv`, the CodeWhisperer profile ARN in `state`. FrugalBar
/// opens it read-only and never refreshes the token — the CLI owns that, and
/// racing it would log the user out of their editor.
///
/// Reading another tool's credential store is exactly what the CLI-discovery
/// opt-in governs, so this reports "Not configured" until that is switched on
/// in Preferences → General.
public final class KiroQuotaProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .kiro
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    /// Overridable so tests can point at their own database instead of the
    /// developer's real one — which holds a live token for a live account.
    private let databaseURL: URL?

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
    }

    // MARK: - Endpoint

    static let endpoint = "https://codewhisperer.us-east-1.amazonaws.com/"
    static let target = "AmazonCodeWhispererService.GetUsageLimits"
    static let contentType = "application/x-amz-json-1.0"

    /// The one resource type carrying the credit balance. Kiro also reports
    /// other rows here, and summing them would invent a denominator.
    static let creditResource = "CREDIT"

    // MARK: - Fetch

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        // An explicit database (tests) is trusted; discovering the real one is
        // credential discovery and stays behind the opt-in.
        let resolvedDatabase: URL
        if let databaseURL {
            resolvedDatabase = databaseURL
        } else {
            guard CredentialStore.isCLIDiscoveryEnabled else { return unavailable(.notConfigured) }
            resolvedDatabase = Self.stateDatabaseURL()
        }

        let identity: Identity
        switch await Self.readIdentityAsync(databaseURL: resolvedDatabase) {
        case .found(let found):
            identity = found
        case .notLoggedIn:
            return unavailable(.notConfigured)
        case .transientFailure:
            // The CLI was mid-write when the busy-timeout expired, or the
            // file was briefly unreadable — a real remedy exists (retry), but
            // it is not "add a key", which is what `.notConfigured` tells the
            // user. `.badResponse` is the closest existing reason that
            // doesn't claim either a credential or a network problem.
            return unavailable(.badResponse)
        }

        let body = try JSONSerialization.data(withJSONObject: ["profileArn": identity.profileARN])
        let (data, http) = try await QuotaHTTP.post(
            url: Self.endpoint,
            body: body,
            headers: [
                "Content-Type": Self.contentType,
                "X-Amz-Target": Self.target,
                "Authorization": "Bearer \(identity.accessToken)",
            ]
        )
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) { return unavailable(reason) }

        guard let response = try? JSONDecoder().decode(UsageLimitsResponse.self, from: data) else {
            return unavailable(.badResponse)
        }
        return Self.snapshot(from: response, provider: self, now: Date())
    }

    // MARK: - Snapshot construction

    static func snapshot(
        from response: UsageLimitsResponse,
        provider: KiroQuotaProvider,
        now: Date
    ) -> QuotaSnapshot {
        let credits = response.usageBreakdownList.filter { $0.resourceType == creditResource }
        // Exactly one credit row, or we cannot say which is the balance.
        guard credits.count == 1, let credit = credits.first else {
            return provider.unavailable(.badResponse)
        }

        let planLimit = credit.usageLimitWithPrecision
        let totalUsed = credit.currentUsageWithPrecision
        let overageUsed = credit.currentOveragesWithPrecision ?? 0
        guard planLimit.isFinite, planLimit > 0,
              totalUsed.isFinite, totalUsed >= 0,
              overageUsed.isFinite, overageUsed >= 0,
              // `currentUsage` is the total including overage, so an overage
              // larger than it is relationally impossible, not a big number.
              totalUsed >= overageUsed
        else { return provider.unavailable(.badResponse) }

        guard let resetsAt = plausibleReset(credit.nextDateReset ?? response.nextDateReset) else {
            return provider.unavailable(.badResponse)
        }

        let planUsed = totalUsed - overageUsed
        let fraction = min(max(planUsed / planLimit, 0), 1)
        let planName = (response.subscriptionInfo?.subscriptionTitle?.trimmed).flatMap {
            $0.isEmpty ? nil : $0
        }
        let windowLength = DualBarMetrics.monthWindowLength(endingAt: resetsAt)

        let urgency: Urgency = fraction >= 0.95 ? .critical
            : fraction >= 0.80 ? .warning
            : .none

        let remaining = max(planLimit - planUsed, 0)
        var snapshot = QuotaSnapshot(
            id: provider.vendorId.rawValue,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .percentage(usedFraction: fraction, displayDetails: nil),
            status: .measured(urgency),
            resetsAt: resetsAt,
            lastUpdated: now,
            auxiliaryInfo: "Kiro credits",
            row1: DualBarMetrics(
                primaryFraction: fraction,
                expectedPaceFraction: windowLength.flatMap {
                    DualBarMetrics.proRataPace(resetsAt: resetsAt, windowLength: $0, now: now)
                },
                label: "MO",
                usedText: "\(format(planUsed))/\(format(planLimit)) credits used",
                resetText: "Resets \(RelativeDateTimeFormatter().localizedString(for: resetsAt, relativeTo: now))",
                resetsAt: resetsAt,
                windowLength: windowLength
            ),
            badgeText: fraction >= 1.0 ? "Exhausted" : "\(format(remaining)) left",
            planName: planName,
            cliSource: "kiro-cli"
        )

        // Bonus credits are a separate pool with their own expiry, and they
        // outlive the monthly reset. Shown as their own bar rather than folded
        // into the plan percentage, which would overstate the plan allowance.
        let activeBonuses = (credit.bonuses ?? []).filter { $0.isActive }
        let bonusLimit = activeBonuses.compactMap(\.usageLimit).reduce(0, +)
        let bonusUsed = activeBonuses.compactMap(\.currentUsage).reduce(0, +)
        if bonusLimit > 0 {
            let bonusFraction = min(max(bonusUsed / bonusLimit, 0), 1)
            let expiry = activeBonuses.compactMap { plausibleReset($0.expiresAt) }.min()
            snapshot.row2 = DualBarMetrics(
                primaryFraction: bonusFraction,
                label: "BN",
                usedText: "\(format(bonusUsed))/\(format(bonusLimit)) bonus credits used",
                resetText: expiry.map {
                    "Expires \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))"
                },
                resetsAt: expiry
            )
        }

        // Overage is the ceiling the account really spends against, but only
        // once the vendor says it is switched on — a cap reported alongside
        // DISABLED is a price list, not an allowance.
        if response.overageConfiguration?.isEnabled == true,
           let cap = credit.overageCapWithPrecision, cap > 0, cap.isFinite
        {
            let overageFraction = min(max(overageUsed / cap, 0), 1)
            let rateText = credit.overageRate.map {
                " @ \(SubscriptionCycle.formatCost(Decimal($0), currencyCode: credit.currency ?? "USD"))/credit"
            } ?? ""
            snapshot.row3 = DualBarMetrics(
                primaryFraction: overageFraction,
                label: "OV",
                usedText: "\(format(overageUsed))/\(format(cap)) overage credits\(rateText)",
                resetText: credit.overageCharges.map {
                    "\(SubscriptionCycle.formatCost(Decimal($0), currencyCode: credit.currency ?? "USD")) charged"
                }
            )
        }

        return snapshot
    }

    /// Plausible Unix seconds for a Kiro date: 2001-09-09 through 2100-01-01.
    /// A value outside it is a unit change, not a date — milliseconds would
    /// land centuries beyond any real reset, and drawing a countdown from that
    /// is worse than drawing none.
    static func plausibleReset(_ value: Double?) -> Date? {
        guard let value, value.isFinite, (1_000_000_000...4_102_444_800).contains(value) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// Credits read best without a trailing `.0`, but fractional spend matters.
    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: - Response shape

    struct UsageLimitsResponse: Decodable, Sendable {
        let usageBreakdownList: [UsageBreakdown]
        let overageConfiguration: OverageConfiguration?
        let subscriptionInfo: SubscriptionInfo?
        let nextDateReset: Double?
    }

    struct UsageBreakdown: Decodable, Sendable {
        let resourceType: String
        let currentUsageWithPrecision: Double
        let usageLimitWithPrecision: Double
        let currentOveragesWithPrecision: Double?
        let overageCapWithPrecision: Double?
        let overageCharges: Double?
        let overageRate: Double?
        let currency: String?
        let nextDateReset: Double?
        let bonuses: [Bonus]?
    }

    struct Bonus: Decodable, Sendable {
        let currentUsage: Double?
        let usageLimit: Double?
        let expiresAt: Double?
        let status: String?

        var isActive: Bool { status?.uppercased() == "ACTIVE" }
    }

    struct OverageConfiguration: Decodable, Sendable {
        let overageStatus: String?

        var isEnabled: Bool { overageStatus?.uppercased() == "ENABLED" }
    }

    struct SubscriptionInfo: Decodable, Sendable {
        let subscriptionTitle: String?
    }

    // MARK: - CLI credentials

    struct Identity: Sendable, Equatable {
        let accessToken: String
        let profileARN: String
    }

    /// `readIdentity` used to collapse every failure into `nil` — a genuinely
    /// logged-out user and a database the CLI happened to be mid-write on
    /// looked identical, and both surfaced as "Not configured", telling a
    /// signed-in user to add a key. This distinguishes the two so the
    /// caller can report a transient read failure instead.
    enum IdentityReadOutcome: Sendable, Equatable {
        case found(Identity)
        /// No token row for either login method — a real "not signed in".
        case notLoggedIn
        /// The file couldn't be opened, or every read hit `SQLITE_BUSY`/
        /// `SQLITE_LOCKED` after the busy-timeout — the CLI was using the
        /// database, not evidence the user is logged out.
        case transientFailure
    }

    /// Where the Kiro CLI keeps its state database.
    static func stateDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["KIRO_DATA_DIR"]?.trimmed, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("data.sqlite3")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
    }

    /// Token rows the CLI writes, one per login method. Builder-ID logins land
    /// in the `odic` row and social logins in the `social` row, so reading only
    /// one of them leaves half of all users reporting "Not configured".
    static let tokenKeys = ["kirocli:odic:token", "kirocli:social:token"]

    /// Reads the CLI's credentials without disturbing them. Read-only: the CLI
    /// owns this file and its refresh cycle.
    ///
    /// Blocking SQLite work (`sqlite3_open_v2`, prepare/step, plus up to
    /// 250ms of busy-wait) — call `readIdentityAsync` from `fetchSnapshot()`,
    /// which hops this off the cooperative thread pool. `QuotaManager`
    /// fetches every provider concurrently inside a `withTaskGroup`, and a
    /// blocking call parked directly on a pool thread there is a
    /// pool-starvation risk with enough providers in flight — the same
    /// shape `CredentialStore.apiKeyAsync`/`credentialQueue` exist to avoid.
    static func readIdentity(databaseURL: URL) -> IdentityReadOutcome {
        #if canImport(SQLite3)
        guard FileManager.default.isReadableFile(atPath: databaseURL.path) else { return .notLoggedIn }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return .transientFailure
        }
        defer { sqlite3_close(db) }
        // The CLI may be mid-write. Wait briefly rather than reporting the
        // user as logged out because their editor happened to be busy.
        sqlite3_busy_timeout(db, 250)

        var sawBusy = false
        var accessToken: String?
        var tokenProfileARN: String?
        for key in tokenKeys {
            guard let json = queryValue(db: db, table: "auth_kv", key: key, sawBusy: &sawBusy),
                  let token = jsonString(in: json, key: "access_token")
            else { continue }
            accessToken = token
            tokenProfileARN = jsonString(in: json, key: "profile_arn")
            break
        }
        guard let accessToken else { return sawBusy ? .transientFailure : .notLoggedIn }

        // The `state` row is authoritative — it is what the CLI sends — but a
        // social login also stamps the ARN into the token blob, which covers a
        // profile that has not been written out yet.
        let profileARN = queryValue(db: db, table: "state", key: "api.codewhisperer.profile", sawBusy: &sawBusy)
            .flatMap { jsonString(in: $0, key: "arn") }
            ?? tokenProfileARN
        guard let profileARN else { return sawBusy ? .transientFailure : .notLoggedIn }

        return .found(Identity(accessToken: accessToken, profileARN: profileARN))
        #else
        return .notLoggedIn
        #endif
    }

    private static let sqliteQueue = DispatchQueue(
        label: "com.quotabar.kiro-sqlite",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func readIdentityAsync(databaseURL: URL) async -> IdentityReadOutcome {
        await withCheckedContinuation { continuation in
            sqliteQueue.async {
                continuation.resume(returning: readIdentity(databaseURL: databaseURL))
            }
        }
    }

    #if canImport(SQLite3)
    /// SQLite hands back a pointer it may free on the next step; copying the
    /// bytes before returning is what `SQLITE_TRANSIENT` means for binds.
    private static let transientDestructor = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    private static func queryValue(db: OpaquePointer?, table: String, key: String, sawBusy: inout Bool) -> String? {
        // Table names cannot be bound, so they come from `tokenKeys`-style
        // literals above and never from a response. The key is bound.
        let sql = "SELECT value FROM \(table) WHERE key = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, key, -1, transientDestructor) == SQLITE_OK else { return nil }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            if stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED { sawBusy = true }
            return nil
        }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
    #endif

    static func jsonString(in json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}
