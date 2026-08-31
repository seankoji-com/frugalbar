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

    @Test("a plan key produces a cycle bar and a weekly premium bar")
    func planUsage() async throws {
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, body: devPassBody()) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }

        #expect(snapshot.status.confidence == .measured)
        #expect(snapshot.planName == "DevPass Pro")
        // The weekly premium window is the only bar: it is the only allowance
        // the vendor gives a reset date for.
        #expect(snapshot.row1?.label == "WK")
        #expect(abs(try #require(snapshot.row1?.primaryFraction) - 0.25) < 0.0001)
        #expect(snapshot.row2 == nil)
        // Plan credits still drive the badge and the overall pressure reading,
        // they just have no bar to be drawn in.
        #expect(snapshot.badgeText == "\(DevPassQuotaProvider.money(Decimal(string: "157.50")!)) left")
        #expect(abs(try #require(snapshot.consumptionFraction) - 79.5 / 237.0) < 0.0001)
    }

    @Test("the vendor publishes no monthly cycle date, and none is invented")
    func noCycleDate() async throws {
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, body: devPassBody()) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }
        // The only reset the API states is the weekly premium one, and it is
        // the only one drawn. Nothing claims to know when the month turns over.
        #expect(snapshot.bars.count == 1)
        #expect(snapshot.bars.allSatisfy { $0.label != "MO" })
        // The default fixture's plan credits (79.50/237.00 ≈ 0.34) are worse
        // than its premium window (10/40 = 0.25), so the badge and headline
        // are driven by the window that has no reset date at all — reporting
        // the premium reset here would attribute the badge's pressure to the
        // wrong window's clock.
        #expect(snapshot.resetsAt == nil)
    }

    @Test("when the premium window is the binding one, its reset is reported")
    func resetReportedWhenPremiumBinds() async throws {
        // Premium window (30/40 = 0.75) now worse than plan credits (10/237
        // ≈ 0.04) — the reverse of the default fixture — so the visible bar
        // and the headline pressure now refer to the same window, and its
        // real reset date is safe to surface.
        let body = devPassBody(creditsUsed: "\"10.00\"", premiumUsed: "\"30.00\"")
        let snapshot = try await withStubbedHTTP(host: StubHost.devpass, body: body) {
            try await DevPassQuotaProvider(apiKey: "llmgtwy_x").fetchSnapshot()
        }
        #expect(snapshot.resetsAt == DevPassQuotaProvider.parseISO8601("2026-09-06T00:00:00Z"))
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
    @Test("a brand-new Lite plan, with no premium reset yet, still reads cleanly")
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
        #expect(snapshot.row1?.label == "WK")
        #expect(snapshot.row1?.primaryFraction == 0)
        // No premium call yet means no week to reset: the bar must carry no
        // window and no pace marker rather than a fabricated seven-day one.
        #expect(snapshot.resetsAt == nil)
        #expect(snapshot.row1?.resetsAt == nil)
        #expect(snapshot.row1?.windowLength == nil)
        #expect(snapshot.row1?.expectedPaceFraction == nil)
        #expect(snapshot.row1?.resetText == nil)
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
