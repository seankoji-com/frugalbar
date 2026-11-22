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
                        "email": "secondary@example.test",
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

    @Test("deduplicates direct and proxy sources only when verified project identity matches")
    func deduplicationVerifiedVsUnverified() async throws {
        let (suiteName, defaults) = freshSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = AntigravityAccountFixture()
        fixture.duplicateDirect = true
        let session = makeSession(fixture: fixture)

        await QuotaHTTP.$session.withValue(session) {
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suiteName,
                proxyConfig: { proxyConfig },
                directCredential: { directToken }
            )
            let mergedProviders = await discovery.providers(now: now)
            // Same verified cloudaicompanionProject → merged into 1 account (3 pool providers).
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
        let session = makeSession(fixture: fixture)

        await QuotaHTTP.$session.withValue(session) {
            let discovery = AntigravityAccountDiscovery(
                defaultsSuiteName: suiteName,
                proxyConfig: { proxyConfig },
                directCredential: { directToken }
            )
            // Pass 1: direct and proxy verify the same project → merged into 1 account.
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
