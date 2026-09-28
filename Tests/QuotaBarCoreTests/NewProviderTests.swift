import Testing
import Foundation
import SQLite3
@testable import QuotaBarCore

// MARK: - File-local HTTP stub

/// A stub keyed by request host.
///
/// The three suites below each drive a different vendor host, so keying the
/// canned response by host lets them run concurrently without clobbering one
/// another's handler — a shared single-slot handler made every suite's result
/// depend on which one happened to be mid-flight. Tests within a suite share a
/// host, so each suite is also `.serialized`.
private final class NewProviderStub: URLProtocol {
    nonisolated(unsafe) private static var _stubs: [String: @Sendable (URLRequest) -> Stubbed] = [:]
    nonisolated(unsafe) private static var _lastRequests: [String: URLRequest] = [:]
    private static let lock = NSLock()

    struct Stubbed: Sendable {
        let status: Int
        let body: Data
    }

    static func install(_ stub: Stubbed, host: String) {
        lock.withLock { _stubs[host] = { _ in stub } }
    }

    /// For a provider that calls several paths on one host — Grok reads its
    /// usage and its plan name from two different endpoints.
    static func install(host: String, responder: @escaping @Sendable (URLRequest) -> Stubbed) {
        lock.withLock { _stubs[host] = responder }
    }

    static func remove(host: String) {
        lock.withLock { _stubs[host] = nil }
    }

    static func lastRequest(host: String) -> URLRequest? {
        lock.withLock { _lastRequests[host] }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NewProviderStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let responder: (@Sendable (URLRequest) -> Stubbed)? = Self.lock.withLock {
            Self._lastRequests[host] = request
            return Self._stubs[host]
        }
        guard let stub = responder?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum StubHost {
    static let grok = "cli-chat-proxy.grok.com"
    static let devpass = "api.llmgateway.io"
    static let opencode = "opencode.ai"
    static let commandcode = "api.commandcode.ai"
}

private func withRoutedHTTP<T: Sendable>(
    host: String,
    routes: [String: String],
    _ operation: @Sendable () async throws -> T
) async throws -> T {
    NewProviderStub.install(host: host) { request in
        let path = request.url?.path ?? ""
        let body = routes.first { path.hasSuffix($0.key) }?.value ?? "{}"
        return NewProviderStub.Stubbed(status: 200, body: Data(body.utf8))
    }
    defer { NewProviderStub.remove(host: host) }
    return try await QuotaHTTP.$session.withValue(NewProviderStub.makeSession()) {
        try await operation()
    }
}

private func withStubbedHTTP<T: Sendable>(
    host: String,
    status: Int = 200,
    body: String,
    _ operation: @Sendable () async throws -> T
) async throws -> T {
    NewProviderStub.install(
        NewProviderStub.Stubbed(status: status, body: Data(body.utf8)), host: host)
    defer { NewProviderStub.remove(host: host) }
    return try await QuotaHTTP.$session.withValue(NewProviderStub.makeSession()) {
        try await operation()
    }
}

// MARK: - Kiro

/// The exact body `AmazonCodeWhispererService.GetUsageLimits` returned for a
/// live KIRO FREE account, with the account identifiers scrubbed. Captured
/// rather than imagined, so a field rename upstream shows up here as a
/// failing test instead of a silently empty gauge.
private let kiroLiveBody = """
{"daysUntilReset":0,"limits":[],"nextDateReset":1.7882208E9,
 "overageConfiguration":{"overageStatus":"DISABLED"},
 "subscriptionInfo":{"overageCapability":"OVERAGE_INCAPABLE",
   "subscriptionManagementTarget":"PURCHASE","subscriptionTitle":"KIRO FREE",
   "type":"Q_DEVELOPER_STANDALONE_FREE","upgradeCapability":"UPGRADE_CAPABLE"},
 "usageBreakdownList":[{"bonuses":[{"bonusCode":"scrubbed","currentUsage":295.94,
     "description":"bonus","displayName":"bonus","expiresAt":1.7907768E9,
     "redeemedAt":1.787190028206E9,"status":"ACTIVE","usageLimit":500.0}],
   "currency":"USD","currentOverages":0,"currentOveragesWithPrecision":0.0,
   "currentUsage":18,"currentUsageWithPrecision":18.43,"displayName":"Credit",
   "nextDateReset":1.7882208E9,"overageCap":10000,"overageCapWithPrecision":10000.0,
   "overageCharges":0.0,"overageRate":0.04,"resourceType":"CREDIT","unit":"INVOCATIONS",
   "usageLimit":50,"usageLimitWithPrecision":50.0}],
 "userInfo":{"userId":"scrubbed"}}
"""

private func kiroSnapshot(_ body: String, now: Date = Date()) throws -> QuotaSnapshot {
    let response = try JSONDecoder().decode(
        KiroQuotaProvider.UsageLimitsResponse.self, from: Data(body.utf8))
    return KiroQuotaProvider.snapshot(
        from: response, provider: KiroQuotaProvider(), now: now)
}

@Suite("KiroQuotaProvider", .serialized)
struct KiroQuotaProviderTests {

    @Test("the live GetUsageLimits body produces a measured credit gauge")
    func liveBody() throws {
        let snapshot = try kiroSnapshot(kiroLiveBody)

        #expect(snapshot.status.confidence == .measured)
        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
        #expect(snapshot.row1?.label == "MO")
        // 18.43 of 50, and the plan bar must not absorb the bonus pool.
        let fraction = try #require(snapshot.row1?.primaryFraction)
        #expect(abs(fraction - 0.3686) < 0.0001)
        #expect(snapshot.row1?.usedText == "18.43/50 credits used")
    }

    @Test("bonus credits get their own bar with their own expiry")
    func bonusRow() throws {
        let snapshot = try kiroSnapshot(kiroLiveBody)
        let bonus = try #require(snapshot.row2)

        #expect(bonus.label == "BN")
        #expect(abs(try #require(bonus.primaryFraction) - 0.59188) < 0.0001)
        #expect(bonus.resetsAt == Date(timeIntervalSince1970: 1_790_776_800))
    }

    @Test("an overage cap reported alongside DISABLED is a price list, not an allowance")
    func overageDisabled() throws {
        // The live body carries overageCap 10000 with overageStatus DISABLED.
        // Drawing that as headroom would claim 200x the real allowance.
        #expect(try kiroSnapshot(kiroLiveBody).row3 == nil)
    }

    @Test("an enabled overage does get its own bar")
    func overageEnabled() throws {
        let body = kiroLiveBody
            .replacingOccurrences(of: "\"overageStatus\":\"DISABLED\"", with: "\"overageStatus\":\"ENABLED\"")
            .replacingOccurrences(of: "\"currentOveragesWithPrecision\":0.0", with: "\"currentOveragesWithPrecision\":25.0")
            .replacingOccurrences(of: "\"currentUsageWithPrecision\":18.43", with: "\"currentUsageWithPrecision\":43.43")
        let overage = try #require(try kiroSnapshot(body).row3)

        #expect(overage.label == "OV")
        #expect(abs(try #require(overage.primaryFraction) - 0.0025) < 0.00001)
    }

    @Test("overage larger than total usage is impossible, so the reading is refused")
    func overageExceedsTotal() throws {
        // `currentUsage` already includes overage. If the overage exceeds it,
        // the two fields disagree and neither can be trusted — better to
        // report nothing than a plan percentage computed from a negative.
        let body = kiroLiveBody.replacingOccurrences(
            of: "\"currentOveragesWithPrecision\":0.0", with: "\"currentOveragesWithPrecision\":99.0")
        #expect(try kiroSnapshot(body).status.confidence == .unavailable)
    }

    @Test("a reset timestamp in milliseconds is rejected rather than drawn centuries out")
    func implausibleReset() throws {
        let body = kiroLiveBody.replacingOccurrences(of: "1.7882208E9", with: "1.7882208E12")
        #expect(try kiroSnapshot(body).status.confidence == .unavailable)
    }

    @Test("a zero plan limit has no denominator, so no fraction is invented")
    func zeroLimit() throws {
        let body = kiroLiveBody.replacingOccurrences(
            of: "\"usageLimitWithPrecision\":50.0", with: "\"usageLimitWithPrecision\":0.0")
        #expect(try kiroSnapshot(body).status.confidence == .unavailable)
    }

    @Test("credits pass 80% and 95% into warning and critical")
    func urgencyThresholds() throws {
        func urgency(used: String) throws -> Urgency {
            let body = kiroLiveBody.replacingOccurrences(
                of: "\"currentUsageWithPrecision\":18.43", with: "\"currentUsageWithPrecision\":\(used)")
            return try kiroSnapshot(body).status.urgency
        }
        #expect(try urgency(used: "18.43") == Urgency.none)
        #expect(try urgency(used: "41.0") == .warning)
        #expect(try urgency(used: "48.0") == .critical)
    }
}

// MARK: - Kiro CLI credentials

@Suite("KiroQuotaProvider credentials")
struct KiroCredentialTests {

    /// Builds a throwaway copy of the CLI's state database.
    private func makeDatabase(tokenKey: String, arnInState: Bool) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kiro-test-\(UUID().uuidString).sqlite3")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let token = #"{"access_token":"tok-abc","profile_arn":"arn:from:token"}"#
        let profile = #"{"arn":"arn:from:state","profile_name":"Social_Default_Profile"}"#
        var sql = """
        CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO auth_kv VALUES ('\(tokenKey)', '\(token)');
        """
        if arnInState {
            sql += "INSERT INTO state VALUES ('api.codewhisperer.profile', '\(profile)');"
        }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test("both login methods are read", arguments: ["kirocli:odic:token", "kirocli:social:token"])
    func bothTokenKeys(key: String) throws {
        let url = try makeDatabase(tokenKey: key, arnInState: true)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .found(let identity) = KiroQuotaProvider.readIdentity(databaseURL: url) else {
            Issue.record("expected .found, got no identity")
            return
        }
        #expect(identity.accessToken == "tok-abc")
        #expect(identity.profileARN == "arn:from:state")
    }

    @Test("the ARN in the token blob covers a profile row the CLI has not written yet")
    func arnFallback() throws {
        let url = try makeDatabase(tokenKey: "kirocli:social:token", arnInState: false)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .found(let identity) = KiroQuotaProvider.readIdentity(databaseURL: url) else {
            Issue.record("expected .found, got no identity")
            return
        }
        #expect(identity.profileARN == "arn:from:token")
    }

    @Test("a missing database is not logged in, not a crash")
    func missingDatabase() {
        let url = URL(fileURLWithPath: "/nonexistent/kiro/data.sqlite3")
        #expect(KiroQuotaProvider.readIdentity(databaseURL: url) == .notLoggedIn)
    }

    @Test("KIRO_DATA_DIR overrides the default location")
    func dataDirOverride() {
        let url = KiroQuotaProvider.stateDatabaseURL(environment: ["KIRO_DATA_DIR": "/custom/kiro"])
        #expect(url.path == "/custom/kiro/data.sqlite3")
    }

    @Test("the default location is the CLI's Application Support directory")
    func defaultLocation() {
        let url = KiroQuotaProvider.stateDatabaseURL(environment: [:])
        #expect(url.path.hasSuffix("Library/Application Support/kiro-cli/data.sqlite3"))
    }
}

// MARK: - Grok

/// The exact body `cli-chat-proxy.grok.com/v1/billing?format=credits` returned
/// for a live account.
private let grokLiveBody = """
{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
   "start":"2026-08-30T13:06:43.146982+00:00","end":"2026-09-06T13:06:43.146982+00:00"},
 "creditUsagePercent":21.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},
 "productUsage":[{"product":"GrokBuild","usagePercent":21.0}],"isUnifiedBillingUser":true,
 "prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
 "billingPeriodStart":"2026-08-30T13:06:43.146982+00:00",
 "billingPeriodEnd":"2026-09-06T13:06:43.146982+00:00"}}
"""

@Suite("GrokQuotaProvider", .serialized)
struct GrokQuotaProviderTests {

    @Test("the live billing body produces a measured weekly gauge")
    func liveBody() async throws {
        let snapshot = try await withStubbedHTTP(host: StubHost.grok, body: grokLiveBody) {
            try await GrokQuotaProvider(accessToken: "tok").fetchSnapshot()
        }

        #expect(snapshot.status.confidence == .measured)
        #expect(snapshot.row1?.label == "WK")
        #expect(abs(try #require(snapshot.row1?.primaryFraction) - 0.21) < 0.0001)
        #expect(snapshot.row1?.usedText == "21% used")
        #expect(snapshot.badgeText == "79% left")
        // A seven-day period, measured from the two dates xAI published.
        #expect(abs(try #require(snapshot.row1?.windowLength) - 7 * 86_400) < 1)
    }

    @Test("the request carries the client header the proxy requires")
    func clientHeader() async throws {
        _ = try await withStubbedHTTP(host: StubHost.grok, body: grokLiveBody) {
            try await GrokQuotaProvider(accessToken: "tok").fetchSnapshot()
        }
        let request = try #require(NewProviderStub.lastRequest(host: StubHost.grok))
        #expect(request.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("an expired token surfaces as a rejected credential, not a zeroed bar")
    func expiredToken() async throws {
        let body = #"{"error":"Invalid or expired credentials"}"#
        let snapshot = try await withStubbedHTTP(host: StubHost.grok, status: 401, body: body) {
            try await GrokQuotaProvider(accessToken: "stale").fetchSnapshot()
        }
        #expect(snapshot.status == .unavailable(.credentialRejected))
        #expect(snapshot.row1 == nil)
    }

    @Test("an on-demand cap above zero gets its own bar")
    func onDemandRow() async throws {
        let body = grokLiveBody
            .replacingOccurrences(of: "\"onDemandCap\":{\"val\":0}", with: "\"onDemandCap\":{\"val\":50}")
            .replacingOccurrences(of: "\"onDemandUsed\":{\"val\":0}", with: "\"onDemandUsed\":{\"val\":10}")
        let snapshot = try await withStubbedHTTP(host: StubHost.grok, body: body) {
            try await GrokQuotaProvider(accessToken: "tok").fetchSnapshot()
        }
        #expect(snapshot.row2?.label == "OD")
        #expect(abs(try #require(snapshot.row2?.primaryFraction) - 0.2) < 0.0001)
    }

    @Test("a zero on-demand cap draws no bar rather than an empty one")
    func zeroOnDemandCap() async throws {
        let snapshot = try await withStubbedHTTP(host: StubHost.grok, body: grokLiveBody) {
            try await GrokQuotaProvider(accessToken: "tok").fetchSnapshot()
        }
        #expect(snapshot.row2 == nil)
    }

    @Test("a period with no usage figure reports the cycle and leaves the gauge unmeasured")
    func periodWithoutUsage() async throws {
        let body = grokLiveBody.replacingOccurrences(of: "\"creditUsagePercent\":21.0,", with: "")
        let snapshot = try await withStubbedHTTP(host: StubHost.grok, body: body) {
            try await GrokQuotaProvider(accessToken: "tok").fetchSnapshot()
        }
        #expect(snapshot.status.confidence == .unavailable)
        #expect(snapshot.row1?.primaryFraction == nil)
        #expect(snapshot.resetsAt != nil)
    }

    @Test("no plan percentage but a live on-demand cap leaves the gauge unmeasured, not doubled")
    func onDemandNeverPromotedToHeadline() async throws {
        // The bug this pins: a plan reporting no creditUsagePercent but a
        // live on-demand cap used to fall back to the on-demand ratio for
        // the headline gauge — showing the same figure twice, once
        // mislabeled as plan usage and again correctly as the OD bar.
        let body = grokLiveBody
            .replacingOccurrences(of: "\"creditUsagePercent\":21.0,", with: "")
            .replacingOccurrences(of: "\"onDemandCap\":{\"val\":0}", with: "\"onDemandCap\":{\"val\":50}")
            .replacingOccurrences(of: "\"onDemandUsed\":{\"val\":0}", with: "\"onDemandUsed\":{\"val\":10}")
        let snapshot = try await withStubbedHTTP(host: StubHost.grok, body: body) {
            try await GrokQuotaProvider(accessToken: "tok").fetchSnapshot()
        }
        #expect(snapshot.status.confidence == .unavailable)
        #expect(snapshot.row1?.primaryFraction == nil)
        #expect(snapshot.row1?.usedText == "Usage not published")
        #expect(snapshot.row2?.label == "OD")
        #expect(abs(try #require(snapshot.row2?.primaryFraction) - 0.2) < 0.0001)
    }

    @Test("the plan name comes from /v1/settings, which is where xAI puts it")
    func planNameFromSettings() async throws {
        let snapshot = try await withRoutedHTTP(host: StubHost.grok, routes: [
            "/v1/billing": grokLiveBody,
            "/v1/settings": #"{"subscription_tier_display":"SuperGrok Lite","leader_mode":false}"#,
        ]) {
            try await GrokQuotaProvider(accessToken: "tok").fetchSnapshot()
        }
        #expect(snapshot.planName == "SuperGrok Lite")
        // The gauge still comes from billing, unaffected by the second call.
        #expect(abs(try #require(snapshot.row1?.primaryFraction) - 0.21) < 0.0001)
    }

    @Test("a settings endpoint that fails costs the label, never the gauge")
    func settingsFailureKeepsGauge() async throws {
        // Only /v1/billing answers; /v1/settings falls through to "{}".
        let snapshot = try await withRoutedHTTP(host: StubHost.grok, routes: [
            "/v1/billing": grokLiveBody,
        ]) {
            try await GrokQuotaProvider(accessToken: "tok").fetchSnapshot()
        }
        #expect(snapshot.planName == nil)
        #expect(snapshot.status.confidence == .measured)
        #expect(abs(try #require(snapshot.row1?.primaryFraction) - 0.21) < 0.0001)
    }

    @Test("a blank tier in settings is not a plan name")
    func blankTier() async throws {
        let snapshot = try await withRoutedHTTP(host: StubHost.grok, routes: [
            "/v1/billing": grokLiveBody,
            "/v1/settings": #"{"subscription_tier_display":"  "}"#,
        ]) {
            try await GrokQuotaProvider(accessToken: "tok").fetchSnapshot()
        }
        #expect(snapshot.planName == nil)
    }

    @Test("period labels come from the type xAI states", arguments: [
        ("USAGE_PERIOD_TYPE_WEEKLY", "WK"),
        ("USAGE_PERIOD_TYPE_MONTHLY", "MO"),
        ("USAGE_PERIOD_TYPE_DAILY", "1D"),
    ])
    func periodLabels(type: String, expected: String) {
        #expect(GrokQuotaProvider.periodLabel(type, windowLength: nil) == expected)
    }

    @Test("an unrecognised period type falls back to its length, never to a guess")
    func periodLabelFallback() {
        #expect(GrokQuotaProvider.periodLabel("SOMETHING_NEW", windowLength: 7 * 86_400) == "WK")
        #expect(GrokQuotaProvider.periodLabel(nil, windowLength: 30 * 86_400) == "MO")
        #expect(GrokQuotaProvider.periodLabel(nil, windowLength: nil) == "CR")
    }

    @Test("tier tokens map to the labels xAI markets", arguments: [
        ("supergrok", "SuperGrok"),
        ("SuperGrok Heavy", "SuperGrok Heavy"),
        ("heavy", "SuperGrok Heavy"),
    ])
    func planNames(raw: String, expected: String) {
        #expect(GrokQuotaProvider.planDisplayName(raw) == expected)
    }

    @Test("an unknown tier is passed through rather than blanked")
    func unknownPlanName() {
        #expect(GrokQuotaProvider.planDisplayName("SuperGrok Ultra") == "SuperGrok Ultra")
        #expect(GrokQuotaProvider.planDisplayName("   ") == nil)
    }

    @Test("the freshest unexpired auth.json entry wins")
    func tokenSelection() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let body = """
        {"https://auth.x.ai::old": {"key":"stale","expires_at":"1970-01-01T00:00:00Z"},
         "https://auth.x.ai::new": {"key":"fresh","expires_at":"2100-01-01T00:00:00Z"}}
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grok-auth-\(UUID().uuidString).json")
        try Data(body.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(GrokQuotaProvider.discoverCLIToken(authURL: url, now: now) == "fresh")
    }

    @Test("with only expired entries the token is still returned, so the reason is 'rejected' not 'not configured'")
    func allExpired() throws {
        let body = #"{"a": {"key":"stale","expires_at":"1970-01-01T00:00:00Z"}}"#
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grok-auth-\(UUID().uuidString).json")
        try Data(body.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(GrokQuotaProvider.discoverCLIToken(authURL: url, now: Date()) == "stale")
    }

    @Test("a missing auth.json yields no token")
    func missingAuthFile() {
        let url = URL(fileURLWithPath: "/nonexistent/.grok/auth.json")
        #expect(GrokQuotaProvider.discoverCLIToken(authURL: url) == nil)
    }
}

// MARK: - DevPass

/// A full `/v1/key` response, including the weekly premium fields that
/// FrugalBar deliberately ignores. Keeping them in the fixture proves the
/// decode-and-ignore path: a paid premium window must never surface, because
/// DevPass is a monthly product.
private func devPassBody(
    plan: String = "pro",
    creditsUsed: String = "\"79.50\"",
    creditsLimit: String = "\"237.00\"",
    remaining: String = "\"157.50\"",
    premiumUsed: String = "\"10.00\"",
    premiumLimit: String = "\"40.00\"",
    premiumReset: String = "\"2026-09-06T00:00:00Z\""
) -> String {
    """
    {"data":{"label":"laptop","usage":"412.30","limit":null,"devPlan":"\(plan)",
      "devPlanCreditsUsed":\(creditsUsed),"devPlanCreditsLimit":\(creditsLimit),
      "devPlanCreditsRemaining":\(remaining),"devPlanPremiumWeeklyLimit":\(premiumLimit),
      "devPlanPremiumCreditsUsed":\(premiumUsed),"devPlanPremiumWeekResetsAt":\(premiumReset)}}
    """
}

@Suite("DevPassQuotaProvider", .serialized)
struct DevPassQuotaProviderTests {

    @Test("a plan key reports only the monthly allowance")
    func planUsage() async throws {
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, body: devPassBody()) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }

        #expect(snapshot.status.confidence == .measured)
        #expect(snapshot.planName == "DevPass Pro")
        #expect(snapshot.bars.count == 1)
        #expect(snapshot.row1?.label == "MO")
        #expect(abs(try #require(snapshot.row1?.primaryFraction) - 79.5 / 237.0) < 0.0001)
        #expect(snapshot.resetsAt != nil)
        #expect(snapshot.row1?.expectedPaceFraction != nil)
        #expect(snapshot.row1?.resetText == "Renews Oct 1, 2026 09:10 GMT+10")
        // The monthly plan allowance drives the badge and the pressure reading.
        #expect(snapshot.badgeText == "\(DevPassQuotaProvider.money(Decimal(string: "157.50")!)) left")
        #expect(abs(try #require(snapshot.consumptionFraction) - 79.5 / 237.0) < 0.0001)
    }

    @Test("the monthly allowance pins the subscriber's renewal so the bar gets a pace marker and countdown")
    func monthlyCycleMarker() async throws {
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, body: devPassBody()) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }
        // The vendor publishes no monthly turnover date (only the ignored
        // weekly premium reset), so the renewal is the pinned, known one — which
        // is what lets the MO bar draw a period-time marker at all.
        #expect(snapshot.row1?.label == "MO")
        #expect(snapshot.resetsAt == DevPassQuotaProvider.pinnedMonthlyRenewal)
        #expect(snapshot.row1?.resetsAt == DevPassQuotaProvider.pinnedMonthlyRenewal)
        #expect(snapshot.row1?.expectedPaceFraction != nil)
        #expect(snapshot.row1?.resetText == "Renews Oct 1, 2026 09:10 GMT+10")
    }

    /// The pinned/injected renewal is a recurring monthly point; once the
    /// anchored moment passes, the next renewal must roll to the following
    /// month (same day/time) rather than going stale. Uses an explicit calendar
    /// and fixed dates so the assertion never depends on `Date()`.
    @Test("the monthly renewal rolls forward to the next occurrence after now")
    func renewalRollsForward() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 10 * 3600)! // GMT+10, always valid
        let make = { (y: Int, mo: Int, d: Int, h: Int, mi: Int) in
            var c = DateComponents()
            c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
            return cal.date(from: c)
        }
        // Anchored on the 15th at 10:00; now well past that date.
        let anchor = try #require(make(2026, 10, 15, 10, 0))
        let provider = DevPassQuotaProvider(monthlyRenewal: anchor)
        let now = try #require(make(2026, 11, 20, 0, 0))
        let next = try #require(provider.nextMonthlyRenewal(after: now, calendar: cal))
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        #expect(comps.year == 2026)
        #expect(comps.month == 12)
        #expect(comps.day == 15)   // same day-of-month preserved
        #expect(comps.hour == 10)
        #expect(comps.minute == 0)

        // A now before the anchor returns the anchor itself.
        let before = try #require(make(2026, 9, 1, 0, 0))
        #expect(provider.nextMonthlyRenewal(after: before, calendar: cal) == anchor)
    }

    @Test("a high premium window never leaks into a monthly reading")
    func premiumWindowIgnored() async throws {
        // Premium window (30/40 = 0.75) far worse than plan credits (10/237 ≈
        // 0.04). If the weekly premium were tracked, this would read 75% —
        // instead the monthly allowance stays the sole figure, at ~4%.
        let body = devPassBody(creditsUsed: "\"10.00\"", premiumUsed: "\"30.00\"")
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, body: body) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }
        #expect(abs(try #require(snapshot.consumptionFraction) - 10.0 / 237.0) < 0.0001)
        #expect(snapshot.status.urgency == .none)
        #expect(snapshot.row1?.label == "MO")
        // The exact pinned monthly renewal — not merely non-nil — so a leaked
        // weekly-premium reset (2026-09-06) could never slip through as the
        // snapshot's "renewal".
        #expect(snapshot.resetsAt == DevPassQuotaProvider.pinnedMonthlyRenewal)
        #expect(snapshot.row1?.resetsAt == DevPassQuotaProvider.pinnedMonthlyRenewal)
        #expect(snapshot.row1?.resetText == "Renews Oct 1, 2026 09:10 GMT+10")
    }

    @Test("decimal strings are parsed exactly, not through binary floating point")
    func decimalStrings() async throws {
        let snapshot = try await withStubbedHTTP(
            host: StubHost.devpass, body: devPassBody(creditsUsed: "\"0.10\"", creditsLimit: "\"0.30\"", remaining: "\"0.20\"")
        ) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }
        // Asserted on the digits, not the currency symbol: the symbol is the
        // reader's locale's business, and pinning it here would fail on a CI
        // runner in a different region for no defect.
        let badge = try #require(snapshot.badgeText)
        #expect(badge.contains("0.20"))
        #expect(!badge.contains("0.19") && !badge.contains("0.21"))
    }

    @Test("a quoted decimal survives decoding without floating-point drift")
    func decimalExactness() throws {
        struct Wrapper: Decodable { let v: DevPassQuotaProvider.DecimalString }
        let decoded = try JSONDecoder().decode(Wrapper.self, from: Data(#"{"v":"0.20"}"#.utf8))
        #expect(decoded.v.decimalValue == Decimal(string: "0.20"))
    }

    @Test("an unquoted number still decodes, so a future response shape does not go blank")
    func bareNumbers() async throws {
        let snapshot = try await withStubbedHTTP(
            host: StubHost.devpass, body: devPassBody(creditsUsed: "79.5", creditsLimit: "237", remaining: "157.5")
        ) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }
        #expect(abs(try #require(snapshot.consumptionFraction) - 79.5 / 237.0) < 0.0001)
    }

    @Test("a key with no DevPass plan reports its spend rather than an empty plan gauge")
    func noPlan() async throws {
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, body: devPassBody(plan: "none")) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }
        #expect(snapshot.planName == nil)
        #expect(snapshot.status.confidence == .unavailable)
        #expect(snapshot.row1?.label == "SP")
        #expect(snapshot.row1?.primaryFraction == nil)
    }

    @Test("a key spend cap does produce a gauge")
    func keyLimit() async throws {
        let body = devPassBody(plan: "none")
            .replacingOccurrences(of: "\"limit\":null", with: "\"limit\":\"500.00\"")
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, body: body) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }
        #expect(snapshot.status.confidence == .measured)
        #expect(snapshot.currencyBasis == .keySpendCap)
        #expect(abs(try #require(snapshot.row1?.primaryFraction) - 412.3 / 500.0) < 0.0001)
    }

    @Test("a rejected key is reported as such")
    func rejectedKey() async throws {
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, status: 403, body: "{}") {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_bad").fetchSnapshot()
        }
        #expect(snapshot.status == .unavailable(.credentialRejected))
    }

    @Test("no key at all is 'not configured'")
    func noKey() async throws {
        let snapshot = try await DevPassQuotaProvider(apiKey: "").fetchSnapshot()
        #expect(snapshot.status == .unavailable(.notConfigured))
    }

    /// The exact body `/v1/key` returned for a freshly created Lite plan.
    /// Two things a hand-written fixture would have missed: the weekly reset is
    /// `null` until the first premium call, and `usage`/`limit` are "0"/null.
    @Test("a brand-new Lite plan still reads cleanly and draws no premium bar")
    func freshLitePlan() async throws {
        let body = """
        {"data":{"label":"Dev Plan API Key","usage":"0","limit":null,"devPlan":"lite",
          "devPlanCreditsUsed":"0","devPlanCreditsLimit":"87","devPlanCreditsRemaining":"87.00",
          "devPlanPremiumWeeklyLimit":"10.44","devPlanPremiumCreditsUsed":"0.00",
          "devPlanPremiumWeekResetsAt":null}}
        """
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, body: body) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }

        #expect(snapshot.status == .measured(.none))
        #expect(snapshot.planName == "DevPass Lite")
        #expect(snapshot.consumptionFraction == 0)
        #expect(snapshot.row1?.label == "MO")
        #expect(snapshot.row1?.primaryFraction == 0)
        #expect(snapshot.resetsAt == DevPassQuotaProvider.pinnedMonthlyRenewal)
        #expect(snapshot.row1?.resetsAt == DevPassQuotaProvider.pinnedMonthlyRenewal)
    }

    @Test("plan tiers map to their marketed names", arguments: [
        ("lite", "DevPass Lite"), ("pro", "DevPass Pro"), ("max", "DevPass Max"),
    ])
    func planNames(raw: String, expected: String) {
        #expect(DevPassQuotaProvider.planDisplayName(raw) == expected)
    }

    @Test("'none' is a real answer, not a plan name")
    func noneIsNotAPlan() {
        #expect(DevPassQuotaProvider.planDisplayName("none") == nil)
        #expect(DevPassQuotaProvider.planDisplayName(nil) == nil)
    }
}

// MARK: - OpenCode Go

/// The regression this pins: a fully rate-limited account (every window
/// blocked, no window publishing a percent) used to fall through the
/// `measured.max()` guard to `.unavailable(.unsupported(...))` — rendering the
/// generic "No usage API" message and never letting the blocked-placeholder
/// rows this provider deliberately builds get drawn.
@Suite("OpenCodeGoProvider", .serialized)
struct OpenCodeGoProviderTests {

    @Test("a fully rate-limited account renders blocked placeholders, not 'unsupported'")
    func fullyRateLimited() async throws {
        let body = #"""
        {"usage":{"rolling":{"status":"rate-limited"},
                  "weekly":{"status":"rate-limited"},
                  "monthly":{"status":"rate-limited"}}}
        """#
        let snapshot = try await withStubbedHTTP(host: StubHost.opencode, body: body) {
            try await OpenCodeGoProvider(apiKey: "k").fetchSnapshot()
        }

        // The reading is *measured*, never the generic unsupported path — a
        // blocked window is meaningful, not "OpenCode published nothing".
        #expect(snapshot.status.confidence == .measured)
        #expect(snapshot.status.urgency == .critical)
        // Each row is a blocked placeholder: flagged, with no invented percent.
        #expect(snapshot.row1?.isBlocked == true)
        #expect(snapshot.row1?.primaryFraction == nil)
        #expect(snapshot.row2?.isBlocked == true)
        #expect(snapshot.row2?.primaryFraction == nil)
        #expect(snapshot.row3?.isBlocked == true)
        #expect(snapshot.row3?.primaryFraction == nil)
        // The stub was actually exercised.
        #expect(NewProviderStub.lastRequest(host: StubHost.opencode) != nil)
    }
}

// MARK: - Command Code

@Suite("CommandCodeQuotaProvider", .serialized)
struct CommandCodeQuotaProviderTests {

    /// A fixed instant so no assertion depends on the wall clock. Its two
    /// window resets land exactly five hours and seven days later, which makes
    /// the pro-rata pace marker exactly zero for a freshly-opened window.
    private static let now = Date(timeIntervalSince1970: 1_767_225_600)

    /// The credits body as `cmd`'s `/usage` reads it. Every field is a
    /// parameter so a test can move one thing at a time. The default balance is
    /// 60 of Pro's documented $80, i.e. 25% used — the same as either window,
    /// so no test has to reason about two different numbers at once.
    private static func body(
        fiveHourUsed: String = "1.25", fiveHourCap: String = "5",
        weeklyUsed: String = "5", weeklyCap: String = "20",
        limited: String = "false", planId: String = "individual-pro",
        monthly: String = "60", purchased: String = "0", free: String = "0",
        fiveHourReset: String = "1767243600000", weeklyReset: String = "1767830400000"
    ) -> String {
        """
        {
          "success": true,
          "credits": { "planId": "\(planId)", "monthlyCredits": \(monthly),
                       "purchasedCredits": \(purchased), "freeCredits": \(free) },
          "windowLimits": {
            "limited": \(limited),
            "fiveHour": { "used": \(fiveHourUsed), "cap": \(fiveHourCap), "resetAt": \(fiveHourReset) },
            "weekly":   { "used": \(weeklyUsed),  "cap": \(weeklyCap),  "resetAt": \(weeklyReset) }
          }
        }
        """
    }

    /// Parses a credits body and builds the snapshot at the fixed instant.
    private func snapshot(_ json: String) throws -> QuotaSnapshot {
        let response = try #require(
            CommandCodeQuotaProvider.decode(
                CommandCodeQuotaProvider.CreditsResponse.self, from: Data(json.utf8)))
        return CommandCodeQuotaProvider.snapshot(
            from: response, provider: CommandCodeQuotaProvider(), now: Self.now)
    }

    /// Routes `whoami` and `billing/credits` separately, so a test can fail one
    /// without the other.
    private func withCommandCode<T: Sendable>(
        creditsBody: String,
        creditsStatus: Int = 200,
        whoamiStatus: Int = 200,
        whoamiBody: String = #"{"org":{"id":"org-1"},"user":{"userName":"alice"}}"#,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        NewProviderStub.install(host: StubHost.commandcode) { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/whoami") {
                return NewProviderStub.Stubbed(status: whoamiStatus, body: Data(whoamiBody.utf8))
            }
            return NewProviderStub.Stubbed(status: creditsStatus, body: Data(creditsBody.utf8))
        }
        defer { NewProviderStub.remove(host: StubHost.commandcode) }
        return try await QuotaHTTP.$session.withValue(NewProviderStub.makeSession()) {
            try await operation()
        }
    }

    // MARK: Windows

    @Test("the two rolling windows are real, vendor-published measurements")
    func windows() throws {
        let snap = try snapshot(Self.body())

        #expect(snap.status.confidence == .measured)
        #expect(snap.row1?.label == "5H")
        #expect(snap.row1?.windowLength == QuotaWindow.fiveHours)
        #expect(abs(try #require(snap.row1?.primaryFraction) - 0.25) < 0.0001)
        #expect(snap.row1?.resetsAt == Date(timeIntervalSince1970: 1_767_243_600))

        #expect(snap.row2?.label == "WK")
        #expect(snap.row2?.windowLength == QuotaWindow.week)
        #expect(abs(try #require(snap.row2?.primaryFraction) - 0.25) < 0.0001)
        #expect(snap.row2?.resetsAt == Date(timeIntervalSince1970: 1_767_830_400))

        // Both windows opened at `now`, so no time has elapsed: pace at zero.
        #expect(snap.row1?.expectedPaceFraction == 0)
        #expect(snap.row2?.expectedPaceFraction == 0)
        // The longest window supplies the snapshot's turnover.
        #expect(snap.resetsAt == Date(timeIntervalSince1970: 1_767_830_400))
    }

    /// The credit gauge's denominator is the allowance Command Code publishes,
    /// not one we chose. Its numerator is the plan pool actually drawn down.
    @Test("the credit gauge uses the plan allowance Command Code publishes")
    func creditGaugeUsesPublishedAllowance() throws {
        let credits = try #require(try snapshot(Self.body()).row3)

        #expect(credits.label == "CR")
        // 60 left of Pro's documented $80 → 20 used.
        #expect(abs(try #require(credits.primaryFraction) - 0.25) < 0.0001)
        #expect(credits.usedText?.contains("20.00") == true)
        #expect(credits.usedText?.contains("80.00") == true)
    }

    @Test("documented plan allowances")
    func planAllowances() {
        #expect(CommandCodeQuotaProvider.planAllowance("individual-go") == 10)
        #expect(CommandCodeQuotaProvider.planAllowance("individual-goat") == 70)
        #expect(CommandCodeQuotaProvider.planAllowance("individual-pro") == 80)
        #expect(CommandCodeQuotaProvider.planAllowance("individual-pro-v1") == 80)
        #expect(CommandCodeQuotaProvider.planAllowance("individual-max") == 150)
        #expect(CommandCodeQuotaProvider.planAllowance("individual-ultra") == 300)
        #expect(CommandCodeQuotaProvider.planAllowance("Teams_Pro") == 40)
        #expect(CommandCodeQuotaProvider.planAllowance("mystery-tier") == nil)
        #expect(CommandCodeQuotaProvider.planAllowance(nil) == nil)
    }

    @Test("a half-spent GOAT plan reads 50% from its $70 allowance")
    func goatAllowance() throws {
        let credits = try #require(
            try snapshot(Self.body(planId: "individual-goat", monthly: "35")).row3)
        #expect(abs(try #require(credits.primaryFraction) - 0.5) < 0.0001)
    }

    /// The rule this provider must never break: an id we cannot price gets the
    /// balance and nothing else. If someone later widens the table carelessly,
    /// this is the test that has to stay honest.
    @Test("an unknown plan gets no gauge, only the balance — never a guessed denominator")
    func unknownPlanHasNoGauge() throws {
        let credits = try #require(
            try snapshot(Self.body(planId: "mystery-tier", monthly: "12.5")).row3)

        #expect(credits.primaryFraction == nil)
        #expect(credits.usedText?.contains("12.50") == true)
        // A text-only row must not count as spent.
        #expect(credits.primaryFractionForWorstBarRanking == -1)
    }

    @Test("a plan with no monthly credits is not given one")
    func providerPlanHasNoAllowance() throws {
        // Provider is pay-as-you-go — a real answer, not an unreadable id.
        #expect(CommandCodeQuotaProvider.planAllowance("individual-provider") == nil)
        let credits = try #require(try snapshot(Self.body(planId: "individual-provider")).row3)
        #expect(credits.primaryFraction == nil)
    }

    @Test("purchased and free credits widen the denominator")
    func extrasWidenTheGauge() throws {
        // The plan pool is spent (monthly 0) but $50 of top-up credits remain
        // and are spendable: the gauge must not read as exhausted.
        let snap = try snapshot(Self.body(monthly: "0", purchased: "50"))
        let credits = try #require(snap.row3)

        #expect(abs(try #require(credits.primaryFraction) - 80.0 / 130.0) < 0.0001)
        #expect(snap.status == .measured(.none))
    }

    @Test("a window over its cap reads as fully spent, not as a negative or a crash")
    func overCap() throws {
        let snap = try snapshot(Self.body(weeklyUsed: "21", weeklyCap: "20"))

        #expect(snap.row2?.primaryFraction == 1.0)
        #expect(snap.status == .measured(.critical))
        #expect(snap.badgeText == "Exhausted")
    }

    @Test("the vendor's own 'limited' signal reads as critical, never as a healthy window")
    func limitedIsCritical() throws {
        // Without the flag, 25% used is calm; the flag alone must carry it to
        // critical because a request right now would be declined.
        #expect(try snapshot(Self.body()).status == .measured(.none))
        #expect(try snapshot(Self.body(limited: "true")).status == .measured(.critical))
        #expect(try snapshot(Self.body(limited: "true")).badgeText == "Blocked")
    }

    @Test("a blocked signal is preserved without any usage or credit rows")
    func limitedWithoutRows() throws {
        let snap = try snapshot(#"{"windowLimits":{"limited":true}}"#)

        #expect(snap.status == .measured(.critical))
        #expect(snap.badgeText == "Blocked")
        #expect(snap.row1 == nil && snap.row2 == nil && snap.row3 == nil)
    }

    @Test("a window with no positive cap draws no bar")
    func zeroCap() throws {
        let snap = try snapshot(Self.body(fiveHourCap: "0"))

        #expect(snap.row1 == nil)
        #expect(snap.row2 != nil)
        #expect(snap.status.confidence == .measured)
    }

    @Test("a window with a cap but no usage figure is skipped, not read as 0% used")
    func missingUsed() throws {
        // A published cap with no usage is an absent reading: drawing 0% would
        // claim "plenty left" for a window we know nothing about.
        let json = """
        {"windowLimits":{"fiveHour":{"cap":40,"resetAt":1767243600000},
                         "weekly":{"used":5,"cap":20,"resetAt":1767830400000}}}
        """
        let snap = try snapshot(json)

        #expect(snap.row1 == nil)
        #expect(snap.row2 != nil)
        #expect(snap.status.confidence == .measured)
    }

    @Test("urgency crosses at 80% and 95%")
    func urgencyThresholds() throws {
        func urgency(used: String, cap: String) throws -> Urgency {
            try snapshot(Self.body(weeklyUsed: used, weeklyCap: cap)).status.urgency
        }
        #expect(try urgency(used: "5", cap: "20") == .none)
        #expect(try urgency(used: "17", cap: "20") == .warning)
        #expect(try urgency(used: "19.5", cap: "20") == .critical)
    }

    // MARK: Parsing tolerance

    @Test("resetAt parses as epoch milliseconds, epoch seconds, or ISO 8601")
    func resetForms() throws {
        func reset(_ value: String) throws -> Date? {
            let json = #"{"windowLimits":{"fiveHour":{"used":1,"cap":2,"resetAt":\#(value)}}}"#
            return try snapshot(json).row1?.resetsAt
        }
        let expected = Date(timeIntervalSince1970: 1_767_243_600)
        #expect(try reset("1767243600000") == expected)                    // milliseconds
        #expect(try reset("1767243600") == expected)                       // seconds
        #expect(try reset("\"2026-01-01T05:00:00Z\"") == expected)         // ISO 8601
        // Fractional seconds survive, but `Date` is a Double: compare with a
        // tolerance rather than asserting bit-exact equality.
        let fractional = try #require(try reset("\"2026-01-01T05:00:00.189Z\""))
        #expect(abs(fractional.timeIntervalSince(expected) - 0.189) < 0.0001)
    }

    @Test("numeric-string fields decode the same as bare numbers")
    func numericStrings() throws {
        let snap = try snapshot(
            Self.body(fiveHourUsed: "\"1.25\"", fiveHourCap: "\"5\"",
                      monthly: "\"12.5\"", purchased: "\"4\"", free: "\"0.5\""))

        #expect(abs(try #require(snap.row1?.primaryFraction) - 0.25) < 0.0001)
        // 67.5 used of 84.5 (Pro's $80 plus $4 purchased and $0.50 free).
        #expect(abs(try #require(snap.row3?.primaryFraction) - 67.5 / 84.5) < 0.0001)
        #expect(snap.row3?.usedText?.contains("67.50") == true)
        #expect(snap.row3?.usedText?.contains("84.50") == true)
    }

    @Test("a data envelope is unwrapped")
    func envelope() throws {
        let snap = try snapshot("{ \"data\": \(Self.body()) }")

        #expect(snap.row2 != nil)
        #expect(snap.row3 != nil)
        #expect(snap.status.confidence == .measured)
    }

    @Test("a pay-as-you-go account with no windows still reports its balance")
    func creditsOnly() throws {
        let snap = try snapshot(#"{"credits":{"monthlyCredits":3,"purchasedCredits":0,"freeCredits":0}}"#)

        #expect(snap.status.confidence == .measured)
        #expect(snap.row1 == nil)
        #expect(snap.row2 == nil)
        #expect(snap.row3?.primaryFraction == nil)
        #expect(snap.row3?.usedText?.contains("3.00") == true)
    }

    @Test("a payload publishing no figure at all is not rendered as healthy")
    func emptyPayload() throws {
        let snap = try snapshot("{}")

        #expect(snap.status == .unavailable(.badResponse))
        #expect(snap.row1 == nil && snap.row2 == nil && snap.row3 == nil)
    }

    @Test("plan ids map to marketed names, longest prefix first")
    func planNames() {
        #expect(CommandCodeQuotaProvider.planDisplayName("individual-provider") == "Provider")
        #expect(CommandCodeQuotaProvider.planDisplayName("individual-pro-v1") == "Pro")
        #expect(CommandCodeQuotaProvider.planDisplayName("individual-pro") == "Pro")
        #expect(CommandCodeQuotaProvider.planDisplayName("individual-goat") == "GOAT")
        #expect(CommandCodeQuotaProvider.planDisplayName("individual-go") == "Go")
        #expect(CommandCodeQuotaProvider.planDisplayName("Teams_Pro") == "Team Pro")
    }

    @Test("an unknown or absent plan id is given no name")
    func unknownPlan() throws {
        #expect(CommandCodeQuotaProvider.planDisplayName("mystery-tier") == nil)
        #expect(CommandCodeQuotaProvider.planDisplayName(nil) == nil)
        #expect(CommandCodeQuotaProvider.planDisplayName("  ") == nil)
        #expect(try snapshot(Self.body(planId: "mystery-tier")).planName == nil)
        #expect(try snapshot(Self.body(planId: "mystery-tier")).metric == .subscription(tierName: nil, renewalDate: nil))
        #expect(try snapshot(Self.body(planId: "individual-go")).planName == "Go")
        #expect(try snapshot(Self.body(planId: "individual-go")).metric == .subscription(tierName: "Go", renewalDate: nil))
    }

    // MARK: HTTP plumbing

    @Test("a 401 is a rejected credential with no rows")
    func rejected() async throws {
        let snap = try await withCommandCode(creditsBody: "{}", creditsStatus: 401) {
            try await CommandCodeQuotaProvider(apiKey: "user_bad").fetchSnapshot()
        }

        #expect(snap.status == .unavailable(.credentialRejected))
        #expect(snap.row1 == nil && snap.row2 == nil && snap.row3 == nil)
    }

    @Test("a 403 is also reported as a rejected credential")
    func forbidden() async throws {
        let snap = try await withCommandCode(creditsBody: "{}", creditsStatus: 403) {
            try await CommandCodeQuotaProvider(apiKey: "user_bad").fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.credentialRejected))
    }

    @Test("a 429 is a rate limit, not a fabricated calm reading")
    func throttled() async throws {
        let snap = try await withCommandCode(creditsBody: "{}", creditsStatus: 429) {
            try await CommandCodeQuotaProvider(apiKey: "user_ok").fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.rateLimited(retryAfter: nil)))
    }

    @Test("a 2xx body that is not a JSON object is a bad response")
    func notJSON() async throws {
        let snap = try await withCommandCode(creditsBody: "not json") {
            try await CommandCodeQuotaProvider(apiKey: "user_ok").fetchSnapshot()
        }
        #expect(snap.status == .unavailable(.badResponse))
    }

    @Test("whoami failing costs the org refinement, never the reading")
    func whoamiFailure() async throws {
        let snap = try await withCommandCode(creditsBody: Self.body(), whoamiStatus: 500) {
            try await CommandCodeQuotaProvider(apiKey: "user_ok").fetchSnapshot()
        }

        #expect(snap.status.confidence == .measured)
        #expect(snap.row1 != nil)
    }

    @Test("the org id from whoami reaches the credits call, with the key in a header")
    func orgIdForwarded() async throws {
        _ = try await withCommandCode(creditsBody: Self.body()) {
            try await CommandCodeQuotaProvider(apiKey: "user_ok").fetchSnapshot()
        }

        let request = try #require(NewProviderStub.lastRequest(host: StubHost.commandcode))
        #expect(request.url?.path.hasSuffix("/alpha/billing/credits") == true)
        #expect(request.url?.query == "orgId=org-1")
        // The credential rides in the header, never the URL.
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user_ok")
        #expect(request.url?.query?.contains("user_ok") != true)
    }

    @Test("no credential at all is 'not configured'")
    func noCredential() async throws {
        let snap = try await CommandCodeQuotaProvider(apiKey: "").fetchSnapshot()
        #expect(snap.status == .unavailable(.notConfigured))
    }
}
