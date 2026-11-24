import Foundation
import Testing
@testable import QuotaBarCore

private final class AntigravityAccountHTTP: URLProtocol {
    nonisolated(unsafe) static var server: AntigravityAccountFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = Self.server, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, data) = server.respond(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class AntigravityAccountFixture: @unchecked Sendable {
    struct RecordedCall: Sendable {
        let authIndex: String
        let method: String
        let url: String
        let dataField: String?
        let authorization: String?
    }

    private let lock = NSLock()
    private var _calls: [RecordedCall] = []
    private var _inventoryDown = false
    private var _duplicateDirect = false
    private var _dailyMissingForSecondary = false
    private var _secondaryErrorReason: String? = nil
    private var _primaryUnverified = false
    private var _disableSecondary = false
    private var _extraDisabledAndOtherProviders = true
    /// The Google account `userinfo` reports for the direct token; nil → 401.
    private var _directEmail: String? = nil
    /// Proxy auth files publish no email, as an older or stripped inventory.
    private var _hideProxyEmails = false
    /// `userinfo`'s `email_verified`; nil omits the field.
    private var _directEmailVerified: Bool? = true

    var directEmail: String? { get { lock.withLock { _directEmail } } set { lock.withLock { _directEmail = newValue } } }
    var directEmailVerified: Bool? { get { lock.withLock { _directEmailVerified } } set { lock.withLock { _directEmailVerified = newValue } } }
    var hideProxyEmails: Bool { get { lock.withLock { _hideProxyEmails } } set { lock.withLock { _hideProxyEmails = newValue } } }

    var inventoryDown: Bool { get { lock.withLock { _inventoryDown } } set { lock.withLock { _inventoryDown = newValue } } }
    var duplicateDirect: Bool { get { lock.withLock { _duplicateDirect } } set { lock.withLock { _duplicateDirect = newValue } } }
    var dailyMissingForSecondary: Bool { get { lock.withLock { _dailyMissingForSecondary } } set { lock.withLock { _dailyMissingForSecondary = newValue } } }
    var secondaryErrorReason: String? { get { lock.withLock { _secondaryErrorReason } } set { lock.withLock { _secondaryErrorReason = newValue } } }
    var primaryUnverified: Bool { get { lock.withLock { _primaryUnverified } } set { lock.withLock { _primaryUnverified = newValue } } }
    var disableSecondary: Bool { get { lock.withLock { _disableSecondary } } set { lock.withLock { _disableSecondary = newValue } } }

    func calls() -> [RecordedCall] { lock.withLock { _calls } }
    func resetCalls() { lock.withLock { _calls.removeAll() } }

    static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            bytes.append(buffer, count: read)
        }
        return bytes
    }

    func respond(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
            let urlString = request.url?.absoluteString ?? ""
            let authHeader = request.value(forHTTPHeaderField: "Authorization")

            if request.url?.path.hasSuffix("auth-files") == true {
                _calls.append(RecordedCall(authIndex: "inventory", method: request.httpMethod ?? "GET",
                    url: urlString, dataField: nil, authorization: authHeader))
                if _inventoryDown { return (503, [:], Data()) }
                var files: [[String: Any]] = [
                    [
                        "id": "agy-secondary-file",
                        "auth_index": "agy-sec",
                        "provider": "antigravity",
                        "email": _hideProxyEmails ? "" : "secondary@example.test",
                        "disabled": _disableSecondary
                    ]
                ]
                if _extraDisabledAndOtherProviders {
                    files.append([
                        "id": "agy-disabled-file",
                        "auth_index": "agy-off",
                        "provider": "antigravity",
                        "email": "disabled@example.test",
                        "disabled": true
                    ])
                    files.append([
                        "id": "agy-empty-index",
                        "auth_index": "",
                        "provider": "antigravity",
                        "disabled": false
                    ])
                    files.append([
                        "id": "claude-file",
                        "auth_index": "claude-1",
                        "provider": "claude",
                        "disabled": false
                    ])
                }
                return (200, [:], json(["files": files]))
            }

            let rawBody = Self.bodyData(of: request)
            if request.url?.path.hasSuffix("api-call") == true {
                let payload = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any] ?? [:]
                let authIndex = payload["auth_index"] as? String ?? ""
                let method = payload["method"] as? String ?? ""
                let targetURL = payload["url"] as? String ?? ""
                let dataField = payload["data"] as? String
                _calls.append(RecordedCall(authIndex: authIndex, method: method, url: targetURL,
                    dataField: dataField, authorization: authHeader))
                let (innerStatus, innerBody) = cloudCodeResponse(
                    isPrimary: _duplicateDirect && authIndex == "agy-sec",
                    isSecondary: authIndex == "agy-sec",
                    url: targetURL
                )
                return (200, [:], json([
                    "status_code": innerStatus,
                    "header": ["Content-Type": ["application/json"]],
                    "body": String(data: innerBody, encoding: .utf8)!
                ]))
            }

            if urlString.contains("oauth2/v3/userinfo") {
                _calls.append(RecordedCall(authIndex: "direct", method: request.httpMethod ?? "GET",
                    url: urlString, dataField: nil, authorization: authHeader))
                guard let email = _directEmail else { return (401, [:], Data()) }
                var body: [String: Any] = ["email": email]
                if let verified = _directEmailVerified { body["email_verified"] = verified }
                return (200, ["Content-Type": "application/json"], json(body))
            }

            // Direct Google OAuth request
            _calls.append(RecordedCall(authIndex: "direct", method: request.httpMethod ?? "POST",
                url: urlString, dataField: String(data: rawBody, encoding: .utf8), authorization: authHeader))
            let (status, body) = cloudCodeResponse(isPrimary: true, isSecondary: false, url: urlString)
            return (status, ["Content-Type": "application/json"], body)
        }
    }

    private func cloudCodeResponse(isPrimary: Bool, isSecondary: Bool, url: String) -> (Int, Data) {
        func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        let isDaily = url.contains("daily-cloudcode-pa.googleapis.com")

        if isSecondary, let reason = _secondaryErrorReason {
            return (403, json([
                "error": [
                    "code": 403,
                    "status": "PERMISSION_DENIED",
                    "details": [["reason": reason]]
                ]
            ]))
        }

        if url.contains("loadCodeAssist") {
            if isPrimary && !isSecondary && _primaryUnverified {
                return (500, json(["error": ["code": 500]]))
            }
            if isSecondary && _dailyMissingForSecondary && isDaily {
                return (503, json(["error": ["code": 503]]))
            }
            let project = (isPrimary || _duplicateDirect) ? "proj-primary-001" : "proj-secondary-002"
            let tier = (isPrimary || _duplicateDirect) ? "Google AI Ultra" : "Google AI Pro"
            return (200, json([
                "cloudaicompanionProject": project,
                "paidTier": ["id": "paid", "name": tier]
            ]))
        }

        if url.contains("retrieveUserQuotaSummary") {
            if isSecondary && _dailyMissingForSecondary && isDaily {
                // Daily host publishes only Claude/GPT, not Gemini — plain host publishes all.
                return (200, json(["groups": []]))
            }
            let geminiRemaining = isPrimary ? 0.80 : 0.30
            let claudeRemaining = isPrimary ? 0.60 : 0.25
            let argonRemaining = isPrimary ? 0.90 : 0.40
            return (200, json([
                "groups": [
                    [
                        "displayName": "Gemini Models",
                        "buckets": [
                            ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": geminiRemaining, "resetTime": "2027-01-15T06:00:00Z"],
                            ["bucketId": "gemini-wk", "window": "weekly", "remainingFraction": geminiRemaining - 0.1, "resetTime": "2027-01-20T00:00:00Z"]
                        ]
                    ],
                    [
                        "displayName": "Claude and GPT models",
                        "buckets": [
                            ["bucketId": "claude-5h", "window": "5h", "remainingFraction": claudeRemaining, "resetTime": "2027-01-15T06:00:00Z"]
                        ]
                    ],
                    [
                        "displayName": "Gemini 4 Argon",
                        "buckets": [
                            ["bucketId": "gemini-argon-5h", "window": "5h", "remainingFraction": argonRemaining, "resetTime": "2027-01-15T06:00:00Z"]
                        ]
                    ]
                ]
            ]))
        }

        return (404, Data())
    }
}

private func makeSession(fixture: AntigravityAccountFixture) -> URLSession {
    AntigravityAccountHTTP.server = fixture
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AntigravityAccountHTTP.self]
    return URLSession(configuration: config)
}

@Suite("Antigravity multi-account", .serialized)
struct AntigravityAccountTests {
    private let proxyConfig = CLIProxyConfig(
        url: URL(string: "http://proxy.example.test:8317")!,
        managementKey: "secret-mgmt-key-never-leak"
    )
    private let directToken = "ya29.secret-direct-oauth-token-never-leak"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshSuite() -> (String, UserDefaults) {
        let name = "com.quotabar.tests.agy-accounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (name, defaults)
    }

    @Test("discovers local and CLIProxyAPI accounts, skips disabled/other auth files, and coalesces per account")
    func discoveryAndPerAccountCoalescing() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        let session = makeSession(fixture: fixture)

        try await QuotaHTTP.$session.withValue(session) {
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suiteName,
                proxyConfig: { proxyConfig },
                directCredential: { directToken }
            )
            let providers = await discovery.providers(now: now)
            // 2 accounts × 3 pools = 6 providers (disabled & claude auth files excluded).
            #expect(providers.count == 6)

            var snapshots: [QuotaSnapshot] = []
            for provider in providers {
                snapshots.append(try await provider.fetchSnapshot())
            }
            let primarySnaps = snapshots.filter { $0.antigravityAccount?.isPrimary == true }
            let secondarySnaps = snapshots.filter { $0.antigravityAccount?.isPrimary == false }
            #expect(primarySnaps.count == 3)
            #expect(secondarySnaps.count == 3)

            // Primary and secondary keep distinct measured values (no cross-account cache bleed).
            let primaryGemini = try #require(primarySnaps.first { $0.vendorId == .gemini })
            let secondaryGemini = try #require(secondarySnaps.first { $0.vendorId == .gemini })
            #expect(primaryGemini.id != secondaryGemini.id)
            #expect(primaryGemini.id.hasPrefix(AntigravityAccount.instancePrefix))
            #expect(secondaryGemini.id.hasPrefix(AntigravityAccount.instancePrefix))
            #expect(abs((primaryGemini.row1?.primaryFraction ?? 0) - 0.20) < 0.001)
            #expect(abs((secondaryGemini.row1?.primaryFraction ?? 0) - 0.70) < 0.001)

            // Coalescing: 1 loadCodeAssist + 1 retrieveUserQuotaSummary per account across all 3 pools.
            let calls = fixture.calls()
            #expect(calls.filter { $0.authIndex == "direct" && $0.url.contains("loadCodeAssist") }.count == 1)
            #expect(calls.filter { $0.authIndex == "direct" && $0.url.contains("retrieveUserQuotaSummary") }.count == 1)
            #expect(calls.filter { $0.authIndex == "agy-sec" && $0.url.contains("loadCodeAssist") }.count == 1)
            #expect(calls.filter { $0.authIndex == "agy-sec" && $0.url.contains("retrieveUserQuotaSummary") }.count == 1)

            // Every relayed call uses POST with a non-empty JSON `data` string.
            let relayedCalls = calls.filter { $0.authIndex == "agy-sec" }
            #expect(relayedCalls.count == 2)
            #expect(relayedCalls.allSatisfy { $0.method == "POST" && !($0.dataField ?? "").isEmpty })

            // No token or management key leakage in ids, snapshots, or preferences.
            let stored = AntigravityAccountStore.all(in: defaults)
            #expect(stored.count == 2)
            let serializedPrefs = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
            #expect(!serializedPrefs.contains(directToken))
            #expect(!serializedPrefs.contains(proxyConfig.managementKey))
            for snap in snapshots {
                #expect(!snap.id.contains(directToken))
                #expect(!(snap.auxiliaryInfo ?? "").contains(directToken))
                #expect(!(snap.cliSource ?? "").contains(proxyConfig.managementKey))
            }
        }
    }

    @Test("deduplicates direct and proxy sources only when they are the same verified account")
    func deduplicationVerifiedVsUnverified() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.duplicateDirect = true
        // The proxy holds a copy of this Mac's own Google account.
        fixture.directEmail = "secondary@example.test"
        let session = makeSession(fixture: fixture)

        await QuotaHTTP.$session.withValue(session) {
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suiteName,
                proxyConfig: { proxyConfig },
                directCredential: { directToken },
                environment: [:]
            )
            let mergedProviders = await discovery.providers(now: now)
            // Same verified project and the same Google account → 1 account (3 pool providers).
            #expect(mergedProviders.count == 3)
            let accounts = AntigravityAccountStore.all(in: defaults)
            #expect(accounts.count == 1)
            #expect(accounts[0].isPrimary)
        }

        // Now verify unverified sources stay separate (never falsely merged).
        let (suite2, defaults2) = freshSuite()
        defer { defaults2.removePersistentDomain(forName: suite2) }
        let fixture2 = AntigravityAccountFixture()
        fixture2.duplicateDirect = true
        fixture2.primaryUnverified = true
        let session2 = makeSession(fixture: fixture2)

        await QuotaHTTP.$session.withValue(session2) {
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suite2,
                proxyConfig: { proxyConfig },
                directCredential: { directToken }
            )
            let providers = await discovery.providers(now: now)
            // Primary failed loadCodeAssist (unverified) so it keeps its own source| id.
            #expect(providers.count == 6)
            let accounts = AntigravityAccountStore.all(in: defaults2)
            #expect(accounts.count == 2)
            #expect(Set(accounts.map(\.id)).count == 2)
        }
    }

    /// One discovery pass with this Mac signed in as `signIn` (nil: a bare
    /// token with no sign-in key), returning the stored accounts.
    private func discoverAccounts(
        _ session: URLSession, suite: String, defaults: UserDefaults,
        signIn: String? = "sign-in-A", proxy: Bool = true, accessToken: String? = nil,
        recordedAccount: String? = nil, thisMac: Bool = true
    ) async -> [AntigravityAccount] {
        let token = accessToken ?? directToken
        let config = proxyConfig
        let at = now
        let key = AntigravityAccountRoute.accountKey(forEmail: recordedAccount)
        return await QuotaHTTP.$session.withValue(session) {
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suite,
                proxyConfig: { proxy ? config : nil },
                directSession: {
                    thisMac ? AntigravityDirectSession(accessToken: token, sessionKey: signIn, accountKey: key) : nil
                },
                environment: [:]
            )
            _ = await discovery.providers(now: at)
            return AntigravityAccountStore.all(in: defaults)
        }
    }

    private func userinfoCalls(_ fixture: AntigravityAccountFixture) -> Int {
        fixture.calls().filter { $0.url.contains("oauth2/v3/userinfo") }.count
    }

    @Test("a proxy account that is a different Google account on this Mac's project gets its own row")
    func differentAccountOnSharedProjectGetsItsOwnRow() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.duplicateDirect = true
        fixture.hideProxyEmails = true
        let session = makeSession(fixture: fixture)

        // Before the proxy names its account (as before this fix): one row.
        let before = await discoverAccounts(session, suite: suiteName, defaults: defaults)
        #expect(before.count == 1)
        let thisMacID = try #require(before.first?.id)

        // The reported case: the proxy names a different Google account than
        // this Mac's sign-in, on the same project. Two rows, and this Mac's
        // row is untouched (same ID, so its nickname, badge and history).
        fixture.hideProxyEmails = false
        fixture.directEmail = "primary@example.test"
        let after = await discoverAccounts(session, suite: suiteName, defaults: defaults)
        #expect(after.count == 2)
        #expect(after.first(where: { $0.isPrimary })?.id == thisMacID)
        #expect(after.first(where: { !$0.isPrimary })?.id != thisMacID)
        #expect(fixture.calls().contains {
            $0.url.contains("oauth2/v3/userinfo") && $0.authorization == "Bearer \(directToken)"
        })
    }

    @Test("the same Google account still merges; an unknown one stays a separate row")
    func sameAccountMergesUnknownStaysSeparate() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.duplicateDirect = true
        fixture.directEmail = " Secondary@Example.test "
        #expect(await discoverAccounts(makeSession(fixture: fixture), suite: suiteName, defaults: defaults).count == 1)

        // userinfo cannot say who this Mac is: never assumed to be the proxy's
        // account (that hid a second account), so a duplicate row at worst.
        let (suite2, defaults2) = freshSuite()
        defer { defaults2.removePersistentDomain(forName: suite2) }
        let fixture2 = AntigravityAccountFixture()
        fixture2.duplicateDirect = true
        #expect(await discoverAccounts(makeSession(fixture: fixture2), suite: suite2, defaults: defaults2).count == 2)

        // A proxy account that names no account groups by project, as before.
        let (suite3, defaults3) = freshSuite()
        defer { defaults3.removePersistentDomain(forName: suite3) }
        let fixture3 = AntigravityAccountFixture()
        fixture3.duplicateDirect = true
        fixture3.hideProxyEmails = true
        #expect(await discoverAccounts(makeSession(fixture: fixture3), suite: suite3, defaults: defaults3).count == 1)
    }

    @Test("userinfo is asked once per sign-in, again for a new sign-in, and never without a proxy")
    func userinfoOncePerSignIn() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.duplicateDirect = true
        fixture.directEmail = "primary@example.test"
        let session = makeSession(fixture: fixture)

        #expect(await discoverAccounts(session, suite: suiteName, defaults: defaults, proxy: false).count == 1)
        #expect(userinfoCalls(fixture) == 0)

        #expect(await discoverAccounts(session, suite: suiteName, defaults: defaults).count == 2)
        #expect(userinfoCalls(fixture) == 1)

        // The same sign-in with a renewed access token: remembered, not asked, still split.
        fixture.directEmail = nil
        let renewed = await discoverAccounts(session, suite: suiteName, defaults: defaults, accessToken: "ya29.renewed")
        #expect(userinfoCalls(fixture) == 1)
        #expect(renewed.count == 2)

        // A different sign-in never reuses that answer: it is asked for itself.
        _ = await discoverAccounts(session, suite: suiteName, defaults: defaults, signIn: "sign-in-B", accessToken: "ya29.B")
        #expect(userinfoCalls(fixture) == 2)
    }

    @Test("R1: a proxy account never adopts an ID this Mac's row already holds")
    func proxyNeverAdoptsThisMacsID() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.duplicateDirect = true
        fixture.hideProxyEmails = true
        let session = makeSession(fixture: fixture)

        // 1. Proxy only, probe failing: the proxy holds a source-scoped ID.
        fixture.secondaryErrorReason = "VALIDATION_REQUIRED"
        _ = await discoverAccounts(session, suite: suiteName, defaults: defaults, thisMac: false)
        // 2. Both verify on one project: that project's row adopts the proxy's ID.
        fixture.secondaryErrorReason = nil
        let merged = await discoverAccounts(session, suite: suiteName, defaults: defaults)
        #expect(merged.count == 1)
        let thisMacID = try #require(merged.first?.id)
        // 3. This Mac absent and the proxy failing: the proxy reclaims that ID, unverified.
        fixture.secondaryErrorReason = "VALIDATION_REQUIRED"
        _ = await discoverAccounts(session, suite: suiteName, defaults: defaults, thisMac: false)
        // 4. Both recover, and are different Google accounts: two rows, two IDs.
        fixture.secondaryErrorReason = nil
        fixture.hideProxyEmails = false
        fixture.directEmail = "primary@example.test"
        let split = await discoverAccounts(session, suite: suiteName, defaults: defaults)
        #expect(split.count == 2)
        #expect(Set(split.map(\.id)).count == 2)
        #expect(split.first(where: { $0.isPrimary })?.id == thisMacID)
        #expect(split.first(where: { !$0.isPrimary }).map { !$0.historyAliases.contains(thisMacID) } == true)

        // R5: this Mac signs out and the proxy's probe fails. The failing proxy
        // must not fall back onto this Mac's ID (whose cached quota it would show).
        fixture.secondaryErrorReason = "VALIDATION_REQUIRED"
        let failing = await discoverAccounts(session, suite: suiteName, defaults: defaults, thisMac: false)
        #expect(!failing.contains { !$0.isPrimary && $0.id == thisMacID })
    }

    @Test("R6: a proxy account never adopts an ID kept as this Mac's history alias")
    func proxyNeverAdoptsThisMacsHistoryAlias() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.duplicateDirect = true
        fixture.hideProxyEmails = true
        let session = makeSession(fixture: fixture)

        // Both probes fail, then both recover on one project: one row, the
        // other route's earlier ID kept as its history alias.
        fixture.primaryUnverified = true
        fixture.secondaryErrorReason = "VALIDATION_REQUIRED"
        _ = await discoverAccounts(session, suite: suiteName, defaults: defaults)
        fixture.primaryUnverified = false
        fixture.secondaryErrorReason = nil
        let merged = await discoverAccounts(session, suite: suiteName, defaults: defaults)
        let thisMac = try #require(merged.first(where: { $0.isPrimary }))

        // The proxy names a different account, fails once, then recovers.
        fixture.hideProxyEmails = false
        fixture.directEmail = "primary@example.test"
        fixture.secondaryErrorReason = "VALIDATION_REQUIRED"
        _ = await discoverAccounts(session, suite: suiteName, defaults: defaults)
        fixture.secondaryErrorReason = nil
        let recovered = await discoverAccounts(session, suite: suiteName, defaults: defaults)
        let proxy = try #require(recovered.first(where: { !$0.isPrimary }))
        #expect(proxy.id != thisMac.id)
        #expect(!thisMac.historyAliases.contains(proxy.id))
        #expect(recovered.first(where: { $0.isPrimary }).map { !$0.historyAliases.contains(proxy.id) } == true)
    }

    @Test("R4: only a JSON boolean true counts as a verified email")
    func onlyJSONTrueIsVerified() throws {
        let parsed = try #require(try JSONSerialization.jsonObject(
            with: Data(#"{"t": true, "f": false, "one": 1, "onePoint": 1.0, "string": "true"}"#.utf8)
        ) as? [String: Any])
        #expect(AntigravityAccountDiscovery.isJSONTrue(parsed["t"]))
        #expect(!AntigravityAccountDiscovery.isJSONTrue(parsed["f"]))
        #expect(!AntigravityAccountDiscovery.isJSONTrue(parsed["one"]))
        #expect(!AntigravityAccountDiscovery.isJSONTrue(parsed["onePoint"]))
        #expect(!AntigravityAccountDiscovery.isJSONTrue(parsed["string"]))
        #expect(!AntigravityAccountDiscovery.isJSONTrue(nil))
    }

    @Test("R2/R4: a sign-in without a refresh token has no cache key; an unverified email establishes nothing")
    func noKeyWithoutRefreshTokenOrVerifiedEmail() async throws {
        #expect(AntigravityDirectSession.sessionKey(refreshToken: "") == nil)
        #expect(AntigravityDirectSession.sessionKey(refreshToken: "  ") == nil)
        #expect(AntigravityDirectSession.sessionKey(refreshToken: "1//rt") != nil)

        // userinfo names the proxy's own account but does not mark it verified:
        // not proof that they are one account, so they are not merged.
        for verified in [Bool?.none, false] {
            let (suiteName, defaults) = freshSuite()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let fixture = AntigravityAccountFixture()
            fixture.duplicateDirect = true
            fixture.directEmail = "secondary@example.test"
            fixture.directEmailVerified = verified
            let accounts = await discoverAccounts(makeSession(fixture: fixture), suite: suiteName, defaults: defaults)
            #expect(accounts.count == 2)
        }
    }

    @Test("an antigravity-usage session's recorded account is used without asking userinfo")
    func antigravityUsageSessionRecordsItsAccount() async throws {
        let live = try JSONSerialization.data(withJSONObject: [
            "accessToken": "ya29.local", "expiresAt": (now.timeIntervalSince1970 + 3600) * 1000,
            "email": "Primary@Example.test",
        ])
        let parsed = try #require(CredentialStore.antigravitySession(fromTokens: live, now: now))
        #expect(parsed.accessToken == "ya29.local")
        #expect(parsed.email == "Primary@Example.test")
        let expired = try JSONSerialization.data(withJSONObject: [
            "accessToken": "ya29.local", "expiresAt": (now.timeIntervalSince1970 - 1) * 1000, "email": "a@b.test",
        ])
        #expect(CredentialStore.antigravitySession(fromTokens: expired, now: now) == nil)

        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.duplicateDirect = true
        let accounts = await discoverAccounts(makeSession(fixture: fixture), suite: suiteName, defaults: defaults,
                                              signIn: nil, recordedAccount: parsed.email)
        #expect(accounts.count == 2)
        #expect(userinfoCalls(fixture) == 0)
    }

    @Test("relayed api-call POST falls back from daily host to plain host")
    func relayedTwoHostFallback() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.dailyMissingForSecondary = true
        let session = makeSession(fixture: fixture)

        try await QuotaHTTP.$session.withValue(session) {
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suiteName,
                proxyConfig: { proxyConfig },
                directCredential: { nil }
            )
            let providers = await discovery.providers(now: now)
            #expect(providers.count == 3)
            let geminiProvider = try #require(providers.first { $0.vendorId == .gemini })
            let snap = try await geminiProvider.fetchSnapshot()
            #expect(snap.status.confidence == .measured)
            #expect(abs((snap.row1?.primaryFraction ?? 0) - 0.70) < 0.001)

            let calls = fixture.calls().filter { $0.authIndex == "agy-sec" }
            #expect(calls.contains { $0.url.contains("daily-cloudcode-pa.googleapis.com") })
            #expect(calls.contains { $0.url.contains("https://cloudcode-pa.googleapis.com/") })
        }
    }

    @Test("403 VALIDATION_REQUIRED and TOS_VIOLATION map to .unsupported with .unavailable confidence isolated per account")
    func google403IsolatedPerAccount() async throws {
        for (reasonCode, expectedMessage) in [
            ("VALIDATION_REQUIRED", "Google account verification required"),
            ("TOS_VIOLATION", "Account suspended (TOS violation)")
        ] {
            let (suiteName, defaults) = freshSuite()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let fixture = AntigravityAccountFixture()
            fixture.secondaryErrorReason = reasonCode
            let session = makeSession(fixture: fixture)

            try await QuotaHTTP.$session.withValue(session) {
                let discovery = AntigravityAccountDiscovery(
                    defaultsSuiteName: suiteName,
                    proxyConfig: { proxyConfig },
                    directCredential: { directToken }
                )
                let providers = await discovery.providers(now: now)
                #expect(providers.count == 6)

                var snapshots: [QuotaSnapshot] = []
                for provider in providers {
                    snapshots.append(try await provider.fetchSnapshot())
                }
                let primaryGemini = try #require(snapshots.first { $0.vendorId == .gemini && $0.antigravityAccount?.isPrimary == true })
                let secondaryGemini = try #require(snapshots.first { $0.vendorId == .gemini && $0.antigravityAccount?.isPrimary == false })

                // Primary account is completely unaffected.
                #expect(primaryGemini.status.confidence == .measured)
                // Secondary account maps to .unsupported(expectedMessage) with .unavailable confidence.
                #expect(secondaryGemini.status == .unavailable(.unsupported(expectedMessage)))
                #expect(secondaryGemini.status.confidence == .unavailable)
            }
        }
    }

    @Test("GeminiAPICredit attaches only to the primary .gemini row and never to secondary accounts")
    func geminiAPICreditPrimaryOnly() async throws {
        let primary = AntigravityAccount(
            id: "agy-account:primary", badge: "1",
            sourceLabel: "This Mac's Google OAuth session", fallbackName: "This Mac", isPrimary: true)
        let secondary = AntigravityAccount(
            id: "agy-account:secondary", badge: "2",
            sourceLabel: "CLI Proxy (host)", fallbackName: "Account 2", isPrimary: false)
        let credit = try #require(GeminiAPICredit(currencyCode: "USD", prepaidBalance: 45, monthlyCredit: 10, configuredAt: now))

        var primaryGemini = QuotaSnapshot(
            id: primary.poolInstanceID(for: .gemini), vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions, metric: .subscription(tierName: "Ultra", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        primaryGemini.antigravityAccount = primary

        var secondaryGemini = QuotaSnapshot(
            id: secondary.poolInstanceID(for: .gemini), vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        secondaryGemini.antigravityAccount = secondary

        var primaryClaude = QuotaSnapshot(
            id: primary.poolInstanceID(for: .claude), vendorId: .antigravityClaude, displayName: "AGY Claude",
            category: .aiSubscriptions, metric: .subscription(tierName: "Ultra", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
        primaryClaude.antigravityAccount = primary

        let attachedPrimary = QuotaManager.attachingGeminiCredit(to: primaryGemini, credit: credit)
        let attachedSecondary = QuotaManager.attachingGeminiCredit(to: secondaryGemini, credit: credit)
        let attachedClaude = QuotaManager.attachingGeminiCredit(to: primaryClaude, credit: credit)

        #expect(attachedPrimary.geminiAPICredit == credit)
        #expect(attachedSecondary.geminiAPICredit == nil)
        #expect(attachedClaude.geminiAPICredit == nil)

        // Each Google account's own credit (owner, 24 Nov 2026): the secondary
        // account gets its own, the primary's own wins over the older single
        // credit, and a non-Gemini pool still gets none.
        let mainOwn = try #require(GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 20,
                                                   configuredAt: now))
        let burnerOwn = try #require(GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 9,
                                                     configuredAt: now))
        let perAccount = [primary.id: mainOwn, secondary.id: burnerOwn]
        #expect(QuotaManager.attachingGeminiCredit(to: primaryGemini, credit: credit,
                                                   accountCredits: perAccount).geminiAPICredit == mainOwn)
        #expect(QuotaManager.attachingGeminiCredit(to: secondaryGemini, credit: credit,
                                                   accountCredits: perAccount).geminiAPICredit == burnerOwn)
        #expect(QuotaManager.attachingGeminiCredit(to: primaryClaude, credit: credit,
                                                   accountCredits: perAccount).geminiAPICredit == nil)
        // The secondary's own credit attaches even with no older single credit.
        #expect(QuotaManager.attachingGeminiCredit(to: secondaryGemini, credit: nil,
                                                   accountCredits: [secondary.id: burnerOwn]).geminiAPICredit == burnerOwn)
    }

    @Test("QuotaHistoryStore preserves legacy key continuity for the primary account and isolates secondary accounts")
    func historyAliasContinuity() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let primary = AntigravityAccount(
            id: "agy-account:primary1", badge: "1",
            sourceLabel: "This Mac", fallbackName: "This Mac", isPrimary: true)
        let secondary = AntigravityAccount(
            id: "agy-account:secondary2", badge: "2",
            sourceLabel: "CLI Proxy", fallbackName: "Account 2", isPrimary: false)

        let lookup: @Sendable (String) -> [String] = { key in
            if let parsed = AntigravityAccount.parsePoolInstanceKey(key) {
                if parsed.accountID == primary.id { return primary.poolHistoryKeys(for: parsed.allowance) }
                if parsed.accountID == secondary.id { return secondary.poolHistoryKeys(for: parsed.allowance) }
            }
            return [key]
        }

        let store = QuotaHistoryStore(
            databaseURL: dir.appendingPathComponent("history.sqlite3"),
            isTestHost: true,
            instanceKeys: lookup
        )

        let t1 = now.addingTimeInterval(-3600)
        let t2 = now
        let legacySnap = QuotaSnapshot(
            id: "gemini", vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions, metric: .subscription(tierName: "Ultra", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: t1, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.15, label: "5H"))
        var primarySnap = QuotaSnapshot(
            id: primary.poolInstanceID(for: .gemini), vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions, metric: .subscription(tierName: "Ultra", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: t2, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.35, label: "5H"))
        primarySnap.antigravityAccount = primary
        var secondarySnap = QuotaSnapshot(
            id: secondary.poolInstanceID(for: .gemini), vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: t2, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.85, label: "5H"))
        secondarySnap.antigravityAccount = secondary

        try await store.record([legacySnap], now: t1)
        try await store.record([primarySnap, secondarySnap], now: t2)

        let primaryReadings = try await store.fetchReadings(instanceID: primary.poolInstanceID(for: .gemini))
        #expect(primaryReadings.count == 2)
        #expect(primaryReadings.compactMap(\.fraction) == [0.15, 0.35])

        let secondaryReadings = try await store.fetchReadings(instanceID: secondary.poolInstanceID(for: .gemini))
        #expect(secondaryReadings.count == 1)
        #expect(secondaryReadings[0].vendor == secondary.poolInstanceID(for: .gemini))

        // Vendor-level query finds both legacy and agy-account: readings for .gemini.
        let allGemini = try await store.fetchReadings(vendor: .gemini)
        #expect(allGemini.count == 3)
    }

    @Test("QuotaManager prunes removed agy-account entries and keeps remaining accounts intact")
    func managerPrunesRemovedAccounts() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        let session = makeSession(fixture: fixture)

        await QuotaHTTP.$session.withValue(session) {
            final class ClockBox: @unchecked Sendable {
                var value: Date
                init(_ value: Date) { self.value = value }
            }
            let clock = ClockBox(now)
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suiteName,
                proxyConfig: { proxyConfig },
                directCredential: { directToken }
            )
            let manager = QuotaManager(
                cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 300, perProviderTimeout: 10, minPollInterval: 0),
                providerFactory: { [] },
                antigravityProviderFactory: { await discovery.providers(now: clock.value) }
            )
            let first = await manager.forceRefresh()
            #expect(first.count == 6)

            // Disable the secondary account in CLIProxyAPI and refresh the SAME manager after cache TTL.
            fixture.disableSecondary = true
            clock.value = now.addingTimeInterval(60)
            let second = await manager.forceRefresh()
            #expect(second.count == 3)
            #expect(second.values.allSatisfy { $0.antigravityAccount?.isPrimary == true })
        }
    }

    @Test("discovery honours FRUGALBAR_GEMINI_API_BASE and makes no production calls when invalid")
    func discoveryHonoursConfiguredAPIBase() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        let session = makeSession(fixture: fixture)

        try await QuotaHTTP.$session.withValue(session) {
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suiteName,
                proxyConfig: { nil },
                directCredential: { directToken },
                environment: ["FRUGALBAR_GEMINI_API_BASE": "http://evil.example.com"]
            )
            let providers = await discovery.providers(now: now)
            // Invalid override must make zero production calls during discovery.
            #expect(fixture.calls().isEmpty)
            let gemini = try #require(providers.first { $0.vendorId == .gemini })
            let snap = try await gemini.fetchSnapshot()
            #expect(snap.status.confidence == .unavailable)
            if case .unavailable(.unsupported(let msg)) = snap.status {
                #expect(msg.contains("FRUGALBAR_GEMINI_API_BASE"))
            } else {
                Issue.record("Expected .unsupported for invalid FRUGALBAR_GEMINI_API_BASE, got \(snap.status)")
            }
        }
    }

    @Test("a previously verified proxy binding is isolated if its probe later fails verification")
    func priorBindingNeverMergesUnverifiedRoute() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.duplicateDirect = true
        // The proxy holds a copy of this Mac's own Google account.
        fixture.directEmail = "secondary@example.test"
        let session = makeSession(fixture: fixture)

        await QuotaHTTP.$session.withValue(session) {
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suiteName,
                proxyConfig: { proxyConfig },
                directCredential: { directToken },
                environment: [:]
            )
            // Pass 1: direct and proxy are the same account → merged into 1 account.
            let pass1 = await discovery.providers(now: now)
            #expect(pass1.count == 3)

            // Pass 2: proxy credential now fails with VALIDATION_REQUIRED (unverified).
            // Must isolate under its own source-scoped ID rather than staying merged with primary.
            fixture.secondaryErrorReason = "VALIDATION_REQUIRED"
            let pass2 = await discovery.providers(now: now.addingTimeInterval(60))
            #expect(pass2.count == 6)
            let accounts = AntigravityAccountStore.all(in: defaults)
            #expect(accounts.count == 2)
        }
    }

    @Test("QuotaManager drops stale measured bars when an account transitions to 403 TOS_VIOLATION or VALIDATION_REQUIRED")
    func managerDropsMeasuredBarsOnAccountRestriction() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        let session = makeSession(fixture: fixture)

        try await QuotaHTTP.$session.withValue(session) {
            final class ClockBox: @unchecked Sendable {
                var value: Date
                init(_ value: Date) { self.value = value }
            }
            let clock = ClockBox(now)
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suiteName,
                proxyConfig: { proxyConfig },
                directCredential: { directToken }
            )
            let manager = QuotaManager(
                cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 300, perProviderTimeout: 10, minPollInterval: 0),
                providerFactory: { [] },
                antigravityProviderFactory: { await discovery.providers(now: clock.value) }
            )
            let first = await manager.forceRefresh()
            let secondaryBefore = try #require(first.values.first {
                $0.vendorId == .gemini && $0.antigravityAccount?.isPrimary == false
            })
            #expect(secondaryBefore.status.confidence == .measured)

            // Transition secondary account to TOS_VIOLATION and re-poll the same manager.
            fixture.secondaryErrorReason = "TOS_VIOLATION"
            clock.value = now.addingTimeInterval(60)
            let second = await manager.forceRefresh()
            let secondaryAfter = try #require(second.values.first {
                $0.vendorId == .gemini && $0.antigravityAccount?.isPrimary == false
            })
            #expect(secondaryAfter.status == .unavailable(.unsupported("Account suspended (TOS violation)")))
            #expect(secondaryAfter.status.confidence == .unavailable)
            #expect(secondaryAfter.staleReading == nil)
        }
    }

    @Test("proxy-only discovery outage placeholder never attaches configured GeminiAPICredit")
    func proxyOnlyFailureDoesNotAttachGeminiCredit() async throws {
        let credit = try #require(GeminiAPICredit(currencyCode: "USD", prepaidBalance: 45, monthlyCredit: 10, configuredAt: now))
        let placeholder = QuotaSnapshot(
            id: "\(AntigravityAccount.instancePrefix)proxy-unavailable:gemini",
            vendorId: .gemini,
            displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "", renewalDate: nil),
            status: .unavailable(.timedOut),
            resetsAt: nil,
            lastUpdated: now,
            auxiliaryInfo: nil
        )
        let attached = QuotaManager.attachingGeminiCredit(to: placeholder, credit: credit)
        #expect(attached.geminiAPICredit == nil)
    }
}
