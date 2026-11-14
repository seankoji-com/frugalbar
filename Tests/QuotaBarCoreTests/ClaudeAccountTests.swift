import Foundation
import Testing
@testable import QuotaBarCore

/// A separate protocol keeps these fixtures independent of other HTTP suites.
private final class ClaudeAccountHTTP: URLProtocol {
    nonisolated(unsafe) static var server: ClaudeAccountFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = Self.server, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = server.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.0,
            httpVersion: nil, headerFields: response.1)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.2)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ClaudeAccountFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var _throttleA = false
    private var _inventoryDown = false
    private var _profileDown = false
    private var _reverse = false
    private var _duplicate = false
    private var _unknown = false
    private var _directOther = false
    private var _rotateIndices = false
    private var _disableA = false
    private var calls: [(String, String)] = []
    var throttleA: Bool { get { lock.withLock { _throttleA } } set { lock.withLock { _throttleA = newValue } } }
    var inventoryDown: Bool { get { lock.withLock { _inventoryDown } } set { lock.withLock { _inventoryDown = newValue } } }
    var profileDown: Bool { get { lock.withLock { _profileDown } } set { lock.withLock { _profileDown = newValue } } }
    var reverse: Bool { get { lock.withLock { _reverse } } set { lock.withLock { _reverse = newValue } } }
    var duplicate: Bool { get { lock.withLock { _duplicate } } set { lock.withLock { _duplicate = newValue } } }
    var unknown: Bool { get { lock.withLock { _unknown } } set { lock.withLock { _unknown = newValue } } }
    var directOther: Bool { get { lock.withLock { _directOther } } set { lock.withLock { _directOther = newValue } } }
    var rotateIndices: Bool { get { lock.withLock { _rotateIndices } } set { lock.withLock { _rotateIndices = newValue } } }
    var disableA: Bool { get { lock.withLock { _disableA } } set { lock.withLock { _disableA = newValue } } }
    func count(_ index: String, containing path: String) -> Int {
        lock.withLock { calls.filter { $0.0 == index && $0.1.contains(path) }.count }
    }
    static let accountA = "00000000-0000-4000-8000-000000000001"
    static let accountB = "00000000-0000-4000-8000-000000000002"
    static let org = "00000000-0000-4000-8000-000000000003"
    static let accountC = "00000000-0000-4000-8000-000000000004"
    static func id(_ uuid: String) -> String {
        ClaudeAccount.instanceID(identity: "account|\(uuid)|\(org)")
    }
    func respond(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
            if request.url!.path.hasSuffix("auth-files") {
                calls.append(("inventory", "auth-files"))
                if _inventoryDown { return (503, [:], Data()) }
                var files: [[String: Any]] = [
                    ["id": "file-b", "auth_index": "b", "provider": "claude", "email": "b@example.test"],
                    ["id": "file-a", "auth_index": "a", "provider": "claude", "email": "a@example.test"],
                    ["id": "off", "auth_index": "off", "provider": "claude", "disabled": true],
                    ["id": "codex", "auth_index": "codex", "provider": "codex"]
                ]
                if _duplicate { files.append(["id": "file-a2", "auth_index": "a2", "provider": "claude"]) }
                if _disableA {
                    files = files.map { file in
                        var copy = file
                        if (file["auth_index"] as? String)?.hasPrefix("a") == true { copy["disabled"] = true }
                        return copy
                    }
                }
                if _rotateIndices {
                    files = files.map { file in
                        var copy = file
                        copy["auth_index"] = (file["auth_index"] as? String).map { $0 + "-new" }
                        return copy
                    }
                }
                if _reverse { files.reverse() }
                return (200, [:], json(["files": files]))
            }
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(buffer, count: count)
                }
            }
            let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
            let index = payload["auth_index"] as? String ?? "direct"
            let path = payload["url"] as? String ?? request.url!.absoluteString
            calls.append((index, path))
            let isA = !index.hasPrefix("b")
            if path.contains("/profile") {
                if _profileDown || _unknown { return (200, [:], json(["status_code": 404, "body": "{}"])) }
                let uuid = index == "direct" && _directOther ? Self.accountC : isA ? Self.accountA : Self.accountB
                let profile: [String: Any] = ["account": ["uuid": uuid],
                    "organization": ["uuid": Self.org, "rate_limit_tier": isA ? "default_claude_max_5x" : "default_claude_pro"]]
                if index == "direct" { return (200, [:], json(profile)) }
                return (200, [:], json(["status_code": 200, "body": String(data: json(profile), encoding: .utf8)!]))
            }
            if _throttleA && isA && index != "direct" {
                return (200, [:], json(["status_code": 429, "header": ["Retry-After": ["300"]], "body": "{}"]))
            }
            var usage: [String: Any] = [
                "five_hour": ["utilization": isA ? 21 : 72, "resets_at": "2027-01-15T06:00:00Z"],
                "seven_day": ["utilization": isA ? 35 : 84, "resets_at": "2027-01-20T00:00:00Z"],
                "limits": [["kind": "weekly_scoped", "percent": isA ? 13 : 61,
                            "scope": ["model": ["display_name": "Fable"]], "resets_at": "2027-01-20T00:00:00Z"]],
                "extra_usage": ["is_enabled": true, "used_credits": isA ? 100 : 500, "monthly_limit": 1000, "currency": "USD"]
            ]
            if path.contains("cedar_ember") {
                usage["cedar_ember"] = ["eligible": true, "grants": [["id": "general", "resets_left": isA ? 1 : 3,
                    "clears": ["five_hour", "seven_day"], "ends_at": "2027-03-01T00:00:00Z"]]]
            }
            if index == "direct" { return (200, [:], json(usage)) }
            return (200, [:], json(["status_code": 200, "body": String(data: json(usage), encoding: .utf8)!]))
        }
    }
}

@Suite("Independent Claude accounts", .serialized)
struct ClaudeAccountTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let config = CLIProxyConfig(url: URL(string: "https://proxy.example.test")!, managementKey: "fixture-management")

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "ClaudeAccountTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
    private func withServer<T: Sendable>(_ fixture: ClaudeAccountFixture,
                                         operation: () async throws -> T) async rethrows -> T {
        ClaudeAccountHTTP.server = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeAccountHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ClaudeAccountHTTP.server = nil }
        return try await QuotaHTTP.$session.withValue(session) { try await operation() }
    }
    private func read(_ providers: [any QuotaProvider]) async throws -> [String: QuotaSnapshot] {
        var result: [String: QuotaSnapshot] = [:]
        for provider in providers { result[provider.instanceID] = try await provider.fetchSnapshot() }
        return result
    }

    @Test("enabled auth files produce stable independent windows, grants, plans and credit identities")
    func discoveryIsolationAndRestart() async throws {
        let (defaults, suite) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ClaudeAccountFixture()
        let grants = ClaudeGrantSchedule()
        let discovery = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil }, grants: grants)
        try await withServer(fixture) {
            let providers = await discovery.providers(now: now)
            #expect(providers.count == 2)
            let first = try await read(providers)
            let a = try #require(first[ClaudeAccountFixture.id(ClaudeAccountFixture.accountA)])
            let b = try #require(first[ClaudeAccountFixture.id(ClaudeAccountFixture.accountB)])
            #expect(a.row1?.primaryFraction == 0.21 && b.row1?.primaryFraction == 0.72)
            #expect(a.scopedBars.first?.primaryFraction == 0.13 && b.scopedBars.first?.primaryFraction == 0.61)
            #expect(a.resetCreditsAvailable == 1 && b.resetCreditsAvailable == 3)
            #expect(a.planName == "Max (5x)" && b.planName == "Pro")
            #expect(a.apiCredits.first?.id != b.apiCredits.first?.id)
            #expect(a.monthlyAPICredit == nil && b.monthlyAPICredit == nil)
            #expect(fixture.count("off", containing: "usage") == 0)
            #expect(fixture.count("codex", containing: "usage") == 0)
            ClaudeAccountStore.setNickname("  Work  ", for: a.id, in: defaults)
            fixture.reverse = true
            let restarted = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil }, grants: grants)
            let nextProviders = await restarted.providers(now: now.addingTimeInterval(120))
            #expect(nextProviders.map(\.instanceID) == providers.map(\.instanceID))
            let second = try await read(nextProviders)
            #expect(second[a.id]?.displayName == "Work")
            #expect(second[a.id]?.claudeAccount?.badge == a.claudeAccount?.badge)
            #expect(second[b.id]?.row1?.primaryFraction == 0.72)
            #expect(fixture.count("a", containing: "cedar_ember") == 1)
            #expect(fixture.count("b", containing: "cedar_ember") == 1)
            #expect(second[a.id]?.resetCreditsAvailable == 1 && second[b.id]?.resetCreditsAvailable == 3)
        }
    }

    @Test("only matching published account AND organization merge direct and proxy routes")
    func verifiedDedupAndUnknownSeparation() async throws {
        let (defaults, suite) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ClaudeAccountFixture(); fixture.duplicate = true
        await withServer(fixture) {
            let discovery = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config },
                directCredential: { "fixture-direct" }, directPlan: { "Max (5x)" })
            let providers = await discovery.providers(now: now)
            #expect(providers.count == 2)
            #expect(Set(providers.map(\.instanceID)).count == 2)
            fixture.unknown = true
            let (unknownDefaults, unknownSuite) = isolatedDefaults()
            defer { unknownDefaults.removePersistentDomain(forName: unknownSuite) }
            let unknown = ClaudeAccountDiscovery(defaultsSuiteName: unknownSuite, proxyConfig: { config },
                directCredential: { "fixture-direct" }, directPlan: { nil })
            let separate = await unknown.providers(now: now)
            #expect(separate.count == 4)
            #expect(Set(separate.map(\.instanceID)).count == 4)
        }
        let a = try ClaudeAccountProfile.decode(Data("{\"account\":{\"uuid\":\"\(ClaudeAccountFixture.accountA)\"},\"organization\":{\"uuid\":\"\(ClaudeAccountFixture.org)\"}}".utf8))
        let otherOrg = try ClaudeAccountProfile.decode(Data("{\"account\":{\"uuid\":\"\(ClaudeAccountFixture.accountA)\"},\"organization\":{\"uuid\":\"\(ClaudeAccountFixture.accountB)\"}}".utf8))
        #expect(a.instanceID != otherOrg.instanceID)
    }

    @Test("a named proxy throttle is account scoped and never borrows an unrelated direct reading")
    func throttleAndGrantIsolation() async throws {
        let (defaults, suite) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ClaudeAccountFixture()
        let discovery = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
        try await withServer(fixture) {
            let providers = await discovery.providers(now: now)
            fixture.throttleA = true
            let snapshots = try await read(providers)
            let aid = ClaudeAccountFixture.id(ClaudeAccountFixture.accountA)
            let bid = ClaudeAccountFixture.id(ClaudeAccountFixture.accountB)
            #expect(snapshots[aid]?.status.confidence == .unavailable)
            #expect(snapshots[aid]?.row1 == nil)
            #expect(snapshots[bid]?.row1?.primaryFraction == 0.72)
            let before = fixture.count("a", containing: "usage")
            let automatic = try await QuotaFetchContext.$isUserInitiated.withValue(false) { try await read(providers) }
            #expect(automatic[bid]?.status.confidence == .measured)
            #expect(fixture.count("a", containing: "usage") == before)
            _ = try await read(providers)
            #expect(fixture.count("a", containing: "usage") == before + 1)
            #expect(fixture.count("b", containing: "cedar_ember") == 1)
        }
    }

    @Test("later identity verification preserves the first source's nickname and proven duplicate history")
    func identityPromotionPreservesHistory() async throws {
        let (defaults, suite) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ClaudeAccountFixture(); fixture.duplicate = true; fixture.unknown = true
        try await withServer(fixture) {
            let discovery = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
            let first = await discovery.providers(now: now)
            let old = try await read(first)
            let aIDs = Set(old.values.filter { $0.row1?.primaryFraction == 0.21 }.map(\.id))
            let winner = try #require(first.first { aIDs.contains($0.instanceID) }?.instanceID)
            let alias = try #require(aIDs.first { $0 != winner })
            ClaudeAccountStore.setNickname("Personal", for: winner, in: defaults)
            fixture.unknown = false
            let promoted = await discovery.providers(now: now.addingTimeInterval(120))
            #expect(promoted.count == 2)
            let current = try await read(promoted)
            let account = try #require(current[winner]?.claudeAccount)
            #expect(account.name == "Personal")
            #expect(account.historyKeys == [winner, alias])
            #expect(account.historyKeys.allSatisfy { $0 != "claude" })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudePromotion-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let keys = account.historyKeys
            let store = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"), isTestHost: true,
                instanceKeys: { $0 == winner ? keys : [$0] })
            try await store.record(Array(old.values), now: now)
            let history = try await store.fetchReadings(instanceID: winner)
            #expect(history.count == 4)
            #expect(history.allSatisfy { $0.vendor == winner })
            #expect(Set(history.compactMap(\.fraction)) == [0.21, 0.35])
            fixture.disableA = true
            let disabled = await discovery.providers(now: now.addingTimeInterval(240))
            #expect(disabled.count == 1 && !disabled.contains { $0.instanceID == winner })
            fixture.disableA = false
            let restarted = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
            let restored = try await read(await restarted.providers(now: now.addingTimeInterval(360)))
            #expect(restored[winner]?.displayName == "Personal")
            #expect(restored[winner]?.claudeAccount?.historyKeys == [winner, alias])
        }
    }

    @Test("unknown identities keep stable file ids when a restarted hub regenerates auth indexes")
    func stableFileIdentityWithoutProfile() async throws {
        let (defaults, suite) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ClaudeAccountFixture(); fixture.unknown = true
        try await withServer(fixture) {
            let first = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
            let original = await first.providers(now: now)
            fixture.rotateIndices = true
            let restart = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
            let next = await restart.providers(now: now.addingTimeInterval(120))
            #expect(next.map(\.instanceID) == original.map(\.instanceID))
            let readings = try await read(next)
            #expect(readings.count == 2)
            #expect(Set(readings.values.compactMap { $0.row1?.primaryFraction }) == [0.21, 0.72])
            #expect(fixture.count("a-new", containing: "usage") == 1)
            #expect(fixture.count("b-new", containing: "usage") == 1)
        }
    }

    @Test("an inventory outage preserves named identities across restart without reselecting another account")
    func inventoryFailurePreservesNames() async throws {
        let (defaults, suite) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ClaudeAccountFixture()
        try await withServer(fixture) {
            let discovery = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
            let first = await discovery.providers(now: now)
            let firstID = try #require(first.first?.instanceID)
            ClaudeAccountStore.setNickname("Work", for: firstID, in: defaults)
            fixture.inventoryDown = true
            let restarted = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
            let failed = await restarted.providers(now: now.addingTimeInterval(120))
            #expect(failed.map(\.instanceID) == first.map(\.instanceID))
            let snapshots = try await read(failed)
            #expect(snapshots.values.allSatisfy { $0.status.confidence == .unavailable && $0.bars.isEmpty })
            #expect(snapshots[firstID]?.displayName == "Work")
            ClaudeAccountStore.setNickname("", for: firstID, in: defaults)
            #expect(ClaudeAccountStore.all(in: defaults).first { $0.id == firstID }?.name != "Work")
        }
    }

    @Test("direct fallback is used only for the same verified account")
    func directFallbackNeedsIdentityMatch() async throws {
        let fixture = ClaudeAccountFixture(); fixture.throttleA = true
        try await withServer(fixture) {
            let (sameDefaults, sameSuite) = isolatedDefaults()
            defer { sameDefaults.removePersistentDomain(forName: sameSuite) }
            let same = ClaudeAccountDiscovery(defaultsSuiteName: sameSuite, proxyConfig: { config },
                directCredential: { "fixture-direct" }, directPlan: { nil })
            let sameRead = try await read(await same.providers(now: now))
            #expect(sameRead.count == 2)
            #expect(sameRead[ClaudeAccountFixture.id(ClaudeAccountFixture.accountA)]?.status.confidence == .measured)
            fixture.directOther = true
            let (otherDefaults, otherSuite) = isolatedDefaults()
            defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
            let other = ClaudeAccountDiscovery(defaultsSuiteName: otherSuite, proxyConfig: { config },
                directCredential: { "fixture-direct" }, directPlan: { nil })
            let otherRead = try await read(await other.providers(now: now))
            #expect(otherRead.count == 3)
            #expect(otherRead[ClaudeAccountFixture.id(ClaudeAccountFixture.accountA)]?.status.confidence == .unavailable)
            #expect(otherRead[ClaudeAccountFixture.id(ClaudeAccountFixture.accountB)]?.status.confidence == .measured)
            #expect(otherRead[ClaudeAccountFixture.id(ClaudeAccountFixture.accountC)]?.status.confidence == .measured)
            #expect(fixture.count("direct", containing: "usage") == 2)
        }
    }

    @Test("hiding Claude prevents inventory, profile and quota reads")
    func hiddenVendorSkipsDiscovery() async {
        let fixture = ClaudeAccountFixture()
        await withServer(fixture) {
            let manager = QuotaManager(providerFactory: { [] },
                displayPreferences: { ProviderDisplayPreferences(hidden: [.claude]) },
                claudeProviderFactory: {
                    _ = try? await CLIProxyClient.fetchAuthFiles(config: config)
                    return []
                })
            #expect(await manager.forceRefresh().isEmpty)
            #expect(fixture.count("inventory", containing: "auth-files") == 0)
        }
    }

    @Test("manager keeps only the failed account stale and a nickname survives its backoff")
    func managerRetentionAndNickname() async throws {
        let (defaults, suite) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ClaudeAccountFixture()
        let discovery = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
        await withServer(fixture) {
            let manager = QuotaManager(cachePolicy: CachePolicy(cacheTTL: 0, backgroundRefreshInterval: 120, minPollInterval: 0),
                providerFactory: { [] }, claudeProviderFactory: { await discovery.providers(now: now) })
            let initial = await manager.forceRefresh()
            let aid = ClaudeAccountFixture.id(ClaudeAccountFixture.accountA)
            let bid = ClaudeAccountFixture.id(ClaudeAccountFixture.accountB)
            #expect(initial[aid]?.row1?.primaryFraction == 0.21)
            fixture.throttleA = true
            let failed = await manager.forceRefresh()
            #expect(failed[aid]?.staleReading != nil)
            #expect(failed[aid]?.row1?.primaryFraction == 0.21)
            #expect(failed[bid]?.staleReading == nil && failed[bid]?.row1?.primaryFraction == 0.72)
            ClaudeAccountStore.setNickname("Work", for: aid, in: defaults)
            let aRequests = fixture.count("a", containing: "usage")
            let retained = await manager.refresh()
            #expect(retained[aid]?.displayName == "Work")
            #expect(retained[aid]?.row1?.primaryFraction == 0.21)
            #expect(fixture.count("a", containing: "usage") == aRequests)
            #expect(retained[bid]?.staleReading == nil)
        }
    }

    @Test("an identity outage never republishes a previous account's quota as a fresh reading")
    func identityFailureIsUnavailable() async throws {
        let (defaults, suite) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ClaudeAccountFixture()
        try await withServer(fixture) {
            let discovery = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
            let first = await discovery.providers(now: now)
            _ = try await read(first)
            fixture.profileDown = true
            let next = await discovery.providers(now: now.addingTimeInterval(120))
            let unavailable = try await read(next)
            #expect(Set(unavailable.keys) == Set(first.map(\.instanceID)))
            #expect(unavailable.values.allSatisfy { $0.status.confidence == .unavailable && $0.bars.isEmpty })
            #expect(fixture.count("a", containing: "usage") == 1)
            #expect(fixture.count("b", containing: "usage") == 1)
        }
    }

    @Test("Claude vendor history includes all accounts but instance history and events stay separate")
    func historyAndExportIsolation() async throws {
        let (defaults, suite) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ClaudeAccountFixture()
        try await withServer(fixture) {
            let discovery = ClaudeAccountDiscovery(defaultsSuiteName: suite, proxyConfig: { config }, directCredential: { nil })
            let snapshots = try await read(await discovery.providers(now: now))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeHistory-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3"), isTestHost: true)
            try await store.record(Array(snapshots.values), now: now)
            let all = try await store.fetchReadings(vendor: .claude)
            #expect(Set(all.map(\.vendor)) == Set(snapshots.keys))
            let aid = ClaudeAccountFixture.id(ClaudeAccountFixture.accountA)
            let bid = ClaudeAccountFixture.id(ClaudeAccountFixture.accountB)
            let onlyA = try await store.fetchReadings(vendor: .claude, instanceID: aid)
            #expect(!onlyA.isEmpty && onlyA.allSatisfy { $0.vendor == aid })
            let events = [AIEvent(id: "a", kind: .resetCreditGranted, vendorId: .claude, instanceId: aid,
                title: "Account A credit", detail: nil, occurredAt: now, observedAt: now, source: .quotaPoll),
                AIEvent(id: "b", kind: .resetCreditGranted, vendorId: .claude, instanceId: bid,
                title: "Account B credit", detail: nil, occurredAt: now, observedAt: now, source: .quotaPoll),
                AIEvent(id: "legacy", kind: .resetCreditGranted, vendorId: .claude,
                title: "Unbound old credit", detail: nil, occurredAt: now, observedAt: now, source: .quotaPoll)]
            _ = try await store.recordEvents(events)
            #expect(try await store.fetchEvents(vendor: .claude, instanceID: aid).map(\.id) == ["a"])
            let document = try SnapshotExporter.export(SnapshotExportInput(
                publisherId: "00000000-0000-4000-8000-000000000010", publisherLabel: "Fixture Mac",
                publishedAt: now, snapshots: Array(snapshots.values), events: Array(events.prefix(2)))).get()
            let json = try #require(try JSONSerialization.jsonObject(with: document.data) as? [String: Any])
            let providers = try #require(json["providers"] as? [[String: Any]])
            let providerIDs = Set(providers.compactMap { $0["instanceId"] as? String })
            #expect(providerIDs.count == 2)
            let exportedEvents = try #require(json["events"] as? [[String: Any]])
            #expect(Set(exportedEvents.compactMap { $0["instanceId"] as? String }) == providerIDs)
            let encoded = String(data: document.data, encoding: .utf8)!
            #expect(!encoded.contains("fixture-management"))
            #expect(!encoded.contains("proxy.example.test"))
        }
    }
}
