import CryptoKit
import Darwin
import Foundation
import Security
import Synchronization
import Testing
@testable import QuotaBarCore

/// A listener the test answers by hand; it records whether it was closed.
final class FakeCallbackListener: SyncCallbackListener {
    private struct State {
        var closed = false
        var waiter: CheckedContinuation<[String: String], Error>?
        var pending: [String: String]?
    }

    private let state = Mutex(State())
    let redirectURI = "http://127.0.0.1:49152"

    var isClosed: Bool { state.withLock { $0.closed } }
    var isWaiting: Bool { state.withLock { $0.waiter != nil } }

    func answer(_ parameters: [String: String]) {
        let waiter = state.withLock { s -> CheckedContinuation<[String: String], Error>? in
            if let waiter = s.waiter {
                s.waiter = nil
                return waiter
            }
            s.pending = parameters
            return nil
        }
        waiter?.resume(returning: parameters)
    }

    func awaitCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { s -> [String: String]? in
                    if let pending = s.pending { return pending }
                    s.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<[String: String], Error>? in
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func close() { state.withLock { $0.closed = true } }
}

/// The URL the flow presented.
final class PresentedURL: Sendable {
    private let value = Mutex<URL?>(nil)
    var url: URL? { value.withLock { $0 } }
    func set(_ url: URL) { value.withLock { $0 = url } }
}

private func query(_ url: URL?) -> [String: String] {
    var out: [String: String] = [:]
    for item in url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?.queryItems ?? [] {
        out[item.name] = item.value ?? ""
    }
    return out
}

private func flow(_ google: FakeGoogle, _ secrets: InMemorySyncSecrets, _ clock: FakeSyncClock) -> SyncSignInFlow {
    SyncSignInFlow(configuration: SyncFakes.configuration, transport: google, secrets: secrets, clock: clock)
}

@Suite("Sync sign-in (REQ-MAC-OAUTH a, b)")
struct SyncSignInTests {

    @Test("the consent URL carries this sign-in's random state, an S256 PKCE challenge and the loopback redirect")
    func consentURLCarriesStateAndS256Challenge() async throws {
        let clock = FakeSyncClock()
        let google = FakeGoogle(clock: clock)
        let secrets = InMemorySyncSecrets()
        let listener = FakeCallbackListener()
        let presented = PresentedURL()
        let pkce = SyncPKCE.generate()
        let state = SyncOAuth.randomToken()

        let result = try await flow(google, secrets, clock).run(
            listener: listener, loginHint: nil, expectedPermissionId: nil, state: state, pkce: pkce
        ) { url in
            presented.set(url)
            listener.answer(["state": state, "code": "fake-auth-code"])
        }

        let q = query(presented.url)
        #expect(q["state"] == state)
        #expect(q["code_challenge_method"] == "S256")
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncodedString()
        #expect(q["code_challenge"] == expected)
        #expect(pkce.verifier.count == 43)
        #expect(q["redirect_uri"] == listener.redirectURI)
        #expect(q["scope"] == "https://www.googleapis.com/auth/drive.appdata")
        #expect(result.account == SyncFakes.account)
        // The exchange sends the verifier the challenge was made from.
        let exchange = try #require(await google.requests.first { $0.url.host == "oauth2.googleapis.com" })
        let form = String(data: exchange.body ?? Data(), encoding: .utf8) ?? ""
        #expect(form.contains("code_verifier=\(pkce.verifier)"))
        // Two sign-ins never share a state or a verifier.
        #expect(SyncOAuth.randomToken() != SyncOAuth.randomToken())
        #expect(SyncPKCE.generate().verifier != SyncPKCE.generate().verifier)
    }

    @Test("a callback whose state is not this sign-in's is rejected before any token request", arguments: [
        ["state": "someone-elses-state", "code": "fake-auth-code"],
        ["code": "fake-auth-code"],
        ["state": "", "code": "fake-auth-code"],
    ])
    func wrongStateIsRejected(_ callback: [String: String]) async throws {
        let clock = FakeSyncClock()
        let google = FakeGoogle(clock: clock)
        let secrets = InMemorySyncSecrets()
        let listener = FakeCallbackListener()
        await #expect(throws: SyncSignInError.stateMismatch) {
            try await flow(google, secrets, clock).run(
                listener: listener, loginHint: nil, expectedPermissionId: nil,
                state: "this-sign-ins-state", pkce: .generate()
            ) { _ in listener.answer(callback) }
        }
        #expect(await google.tokenRequests == 0)
        #expect(try secrets.read(SyncSecretAccount.refreshToken) == nil)
        #expect(listener.isClosed)
    }

    @Test("the listener closes on success")
    func listenerClosesOnSuccess() async throws {
        let clock = FakeSyncClock()
        let listener = FakeCallbackListener()
        _ = try await flow(FakeGoogle(clock: clock), InMemorySyncSecrets(), clock).run(
            listener: listener, loginHint: nil, expectedPermissionId: nil, state: "s", pkce: .generate()
        ) { _ in listener.answer(["state": "s", "code": "c"]) }
        #expect(listener.isClosed)
    }

    @Test("the listener closes on cancel")
    func listenerClosesOnCancel() async throws {
        let clock = FakeSyncClock()
        let listener = FakeCallbackListener()
        let task = Task {
            try await flow(FakeGoogle(clock: clock), InMemorySyncSecrets(), clock).run(
                listener: listener, loginHint: nil, expectedPermissionId: nil, state: "s", pkce: .generate()
            ) { _ in }
        }
        #expect(await eventually { listener.isWaiting })
        task.cancel()
        await #expect(throws: SyncSignInError.cancelled) { try await task.value }
        #expect(listener.isClosed)
    }

    @Test("the listener closes after 5 minutes, and the sign-in reports a timeout")
    func listenerClosesAfterFiveMinutes() async throws {
        let clock = FakeSyncClock()
        let listener = FakeCallbackListener()
        let task = Task {
            try await flow(FakeGoogle(clock: clock), InMemorySyncSecrets(), clock).run(
                listener: listener, loginHint: nil, expectedPermissionId: nil, state: "s", pkce: .generate()
            ) { _ in }
        }
        #expect(await eventually { listener.isWaiting && clock.sleeperCount == 1 })
        clock.advance(by: 299)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!listener.isClosed)
        clock.advance(by: 1)
        await #expect(throws: SyncSignInError.timedOut) { try await task.value }
        #expect(listener.isClosed)
    }

    @Test("the real listener binds 127.0.0.1 on a random port and closes once the callback arrives")
    func loopbackListenerBindsLoopbackOnly() async throws {
        let first = try SyncLoopbackListener()
        let second = try SyncLoopbackListener()
        defer { first.close(); second.close() }
        #expect(first.port != 0)
        #expect(first.port != second.port)
        #expect(first.boundAddress == "127.0.0.1")
        #expect(first.redirectURI == "http://127.0.0.1:\(first.port)")

        let waiting = Task { try await first.awaitCallback() }
        let port = first.port
        let reply = try await Task.detached { try Self.get("/?state=s&code=c", port: port) }.value
        #expect(reply.hasPrefix("HTTP/1.1 200"))
        #expect(try await waiting.value == ["state": "s", "code": "c"])
        #expect(first.isClosed)
    }

    @Test("the real listener answers other paths with 404 and keeps waiting; cancel closes it")
    func loopbackListenerIgnoresOtherPathsAndCloses() async throws {
        let listener = try SyncLoopbackListener()
        let waiting = Task { try await listener.awaitCallback() }
        let port = listener.port
        let reply = try await Task.detached { try Self.get("/favicon.ico", port: port) }.value
        #expect(reply.hasPrefix("HTTP/1.1 404"))
        #expect(!listener.isClosed)
        waiting.cancel()
        await #expect(throws: SyncSignInError.cancelled) { try await waiting.value }
        #expect(listener.isClosed)
    }

    /// One GET to this process's own loopback listener.
    private static func get(_ target: String, port: UInt16) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw SyncSignInError.listenerFailed }
        let request = Array("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        return String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
    }

    // MARK: (b)

    @Test("the flow asks for offline access with prompt=consent")
    func requestsOfflineAccessAndConsent() {
        let url = SyncOAuth.authorizationURL(
            clientID: "fake-client-id.apps.example.test", redirectURI: "http://127.0.0.1:1",
            state: "s", pkce: .generate())
        let q = query(url)
        #expect(q["access_type"] == "offline")
        #expect(q["prompt"] == "consent")
        #expect(q["response_type"] == "code")
    }

    @Test("sign-in succeeds only once the refresh token is in the Keychain and reads back")
    func succeedsOnlyWhenRefreshTokenReadsBack() async throws {
        let clock = FakeSyncClock()
        let dropping = InMemorySyncSecrets(dropsWrites: true)
        let listener = FakeCallbackListener()
        await #expect(throws: SyncSignInError.notPersisted) {
            try await flow(FakeGoogle(clock: clock), dropping, clock).run(
                listener: listener, loginHint: nil, expectedPermissionId: nil, state: "s", pkce: .generate()
            ) { _ in listener.answer(["state": "s", "code": "c"]) }
        }

        let secrets = InMemorySyncSecrets()
        let again = FakeCallbackListener()
        _ = try await flow(FakeGoogle(clock: clock), secrets, clock).run(
            listener: again, loginHint: nil, expectedPermissionId: nil, state: "s", pkce: .generate()
        ) { _ in again.answer(["state": "s", "code": "c"]) }
        #expect(try secrets.read(SyncSecretAccount.refreshToken) == SyncFakes.refreshToken)
    }

    @Test("a token response with no refresh token is not a sign-in")
    func noRefreshTokenFails() async throws {
        let clock = FakeSyncClock()
        let google = FakeGoogle(clock: clock)
        await google.configure {
            $0.tokenResponses = [SyncHTTPResponse(status: 200, body: Data(#"{"access_token":"fake-access-token"}"#.utf8))]
        }
        let secrets = InMemorySyncSecrets()
        let listener = FakeCallbackListener()
        await #expect(throws: SyncSignInError.noRefreshToken) {
            try await flow(google, secrets, clock).run(
                listener: listener, loginHint: nil, expectedPermissionId: nil, state: "s", pkce: .generate()
            ) { _ in listener.answer(["state": "s", "code": "c"]) }
        }
        #expect(try secrets.read(SyncSecretAccount.refreshToken) == nil)
    }

    @Test("the Keychain item is a non-synchronizable generic password written AfterFirstUnlockThisDeviceOnly")
    func keychainItemAttributes() {
        let attributes = KeychainSyncSecretStore.addAttributes(
            service: "com.quotabar.sync", account: SyncSecretAccount.refreshToken, value: "fake-refresh-token-for-tests")
        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecUseDataProtectionKeychain as String] == nil)
        #expect(attributes[kSecValueData as String] as? Data == Data("fake-refresh-token-for-tests".utf8))
    }

    @Test("the Keychain store writes and reads back under a randomised service",
          .enabled(if: KeychainAvailability.isUsable))
    func keychainRoundTrip() throws {
        // Never the production service: a test must not touch the real item.
        let store = KeychainSyncSecretStore(service: "com.quotabar.sync.test-\(UUID().uuidString)")
        defer { try? store.delete(SyncSecretAccount.refreshToken) }
        try store.write("fake-refresh-token-for-tests", account: SyncSecretAccount.refreshToken)
        #expect(try store.read(SyncSecretAccount.refreshToken) == "fake-refresh-token-for-tests")
        try store.write("fake-refresh-token-replaced", account: SyncSecretAccount.refreshToken)
        #expect(try store.read(SyncSecretAccount.refreshToken) == "fake-refresh-token-replaced")
        try store.delete(SyncSecretAccount.refreshToken)
        #expect(try store.read(SyncSecretAccount.refreshToken) == nil)
    }

    @Test("a sign-in that must be the same account rejects another one before storing its token")
    func wrongAccountIsRejectedBeforeStoring() async throws {
        let clock = FakeSyncClock()
        let google = FakeGoogle(clock: clock)
        await google.configure { $0.aboutAccount = SyncFakes.otherAccount }
        let secrets = InMemorySyncSecrets(initial: [SyncSecretAccount.refreshToken: "fake-refresh-token-original"])
        let listener = FakeCallbackListener()
        let presented = PresentedURL()
        await #expect(throws: SyncSignInError.wrongAccount) {
            try await flow(google, secrets, clock).run(
                listener: listener, loginHint: SyncFakes.account.email,
                expectedPermissionId: SyncFakes.account.permissionId, state: "s", pkce: .generate()
            ) { url in
                presented.set(url)
                listener.answer(["state": "s", "code": "c"])
            }
        }
        #expect(query(presented.url)["login_hint"] == SyncFakes.account.email)
        #expect(try secrets.read(SyncSecretAccount.refreshToken) == "fake-refresh-token-original")
    }
}

@Suite("Sync refresh failures (REQ-MAC-OAUTH c)")
struct SyncRefreshFailureTests {

    private static func body(_ error: String?) -> Data {
        Data((error.map { #"{"error":"\#($0)"}"# } ?? "{}").utf8)
    }

    @Test("429 and 5xx are transient; every other 4xx is terminal", arguments: [
        (429, "rate_limit_exceeded", false), (429, nil, false),
        (500, nil, false), (502, "server_error", false), (503, nil, false),
        (400, "invalid_grant", true), (401, "invalid_client", true), (400, "unauthorized_client", true),
        (400, "invalid_scope", true), (401, "deleted_client", true), (403, "org_internal", true),
        (400, "something_new", true), (404, nil, true),
    ] as [(Int, String?, Bool)])
    func classification(status: Int, error: String?, terminal: Bool) throws {
        let failure = try #require(SyncRefreshFailure.classify(status: status, body: Self.body(error)))
        #expect(failure.isTerminal == terminal)
    }

    @Test("network errors and timeouts are transient")
    func networkAndTimeoutAreTransient() {
        #expect(SyncRefreshFailure.classify(transportError: URLError(.notConnectedToInternet)) == .transient(.network))
        #expect(SyncRefreshFailure.classify(transportError: URLError(.timedOut)) == .transient(.timeout))
        #expect(SyncRefreshFailure.classify(transportError: SyncTimeoutError()) == .transient(.timeout))
        #expect(SyncRefreshFailure.classify(status: 200, body: Data()) == nil)
    }

    @Test("a 429 with a JSON error field leaves the publish scheduled, with backoff")
    func rateLimitedRefreshStaysScheduledWithBackoff() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure {
            $0.tokenResponses = [SyncHTTPResponse(status: 429, body: Self.body("rate_limit_exceeded"))]
        }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        let status = await harness.publisher.status()
        #expect(!status.needsSignIn)
        #expect(status.lastError == "Google is rate-limiting sign-in; retrying")
        let next = try #require(await harness.publisher.nextWakeup())
        #expect(next == harness.clock.now().addingTimeInterval(SyncPublisher.backoff(1)))
        #expect(await harness.google.uploads.isEmpty)

        // The retry goes out when the backoff ends, and publishes.
        harness.clock.set(next)
        await harness.publisher.tick()
        #expect(await harness.google.uploads.count == 1)
    }

    @Test("transient refresh failures back off, longer each time", arguments: [
        SyncHTTPResponse(status: 503), SyncHTTPResponse(status: 500, body: Data(#"{"error":"internal_failure"}"#.utf8)),
    ])
    func transientFailuresBackOff(_ response: SyncHTTPResponse) async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.tokenResponses = [response, response] }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let first = try #require(await harness.publisher.nextWakeup())
        harness.clock.set(first)
        await harness.publisher.tick()
        let second = try #require(await harness.publisher.nextWakeup())
        #expect(first.timeIntervalSince(SyncFakes.start) == SyncPublisher.backoff(1))
        #expect(second.timeIntervalSince(first) == SyncPublisher.backoff(2))
        #expect(SyncPublisher.backoff(2) > SyncPublisher.backoff(1))
        #expect(!(await harness.publisher.status().needsSignIn))
        // Only a terminal answer removes the token.
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == SyncFakes.refreshToken)
    }

    @Test("a network error at the token endpoint backs off")
    func networkErrorBacksOff() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure { $0.tokenFailure = URLError(.notConnectedToInternet) }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        #expect(await harness.publisher.nextWakeup() != nil)
        #expect(!(await harness.publisher.status().needsSignIn))
    }

    @Test("each terminal category stops publishing, says Sign in again, and schedules nothing", arguments: [
        (400, "invalid_grant"), (401, "invalid_client"), (400, "unauthorized_client"),
        (400, "invalid_scope"), (401, "deleted_client"), (403, "org_internal"), (400, "brand_new_error"),
    ] as [(Int, String)])
    func terminalFailureStopsPublishing(status: Int, error: String) async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure {
            $0.tokenResponses = [SyncHTTPResponse(status: status, body: Self.body(error))]
        }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()

        #expect(await harness.publisher.status().needsSignIn)
        #expect(await harness.publisher.nextWakeup() == nil)
        // Nothing retries, however long the Mac waits or polls.
        for _ in 0..<5 {
            harness.clock.advance(by: SyncPublisher.heartbeatInterval)
            await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: 0.9)]))
            await harness.publisher.tick()
        }
        #expect(await harness.google.tokenRequests == 1)
        #expect(await harness.google.uploads.isEmpty)
        // The rejected token is deleted, so nothing can send it again.
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == nil)
    }

    @Test("signing in again as the same account resumes publishing with the same session")
    func signInAgainResumes() async throws {
        let harness = try await SyncHarness.active()
        await harness.google.configure {
            $0.tokenResponses = [SyncHTTPResponse(status: 400, body: Self.body("invalid_grant"))]
        }
        await harness.publisher.submit(SyncFakes.source())
        await harness.publisher.tick()
        let publisherId = try harness.secrets.read(SyncSecretAccount.publisherId)
        // The rejected token is gone; the sign-in stores a new one before
        // telling the publisher.
        #expect(try harness.secrets.read(SyncSecretAccount.refreshToken) == nil)
        try harness.secrets.write("fake-refresh-token-after-sign-in", account: SyncSecretAccount.refreshToken)

        await #expect(throws: SyncSignInError.wrongAccount) {
            try await harness.publisher.reauthorized(account: SyncFakes.otherAccount)
        }
        try await harness.publisher.reauthorized(account: SyncFakes.account)
        #expect(!(await harness.publisher.status().needsSignIn))
        harness.clock.advance(by: SyncPublisher.minimumInterval)
        await harness.publisher.tick()
        #expect(await harness.google.uploadedPublisherIds() == [publisherId])
    }
}

@Suite("Sync opt-in and client values (REQ-MAC-OPTIN, REQ-MAC-SECRETS)")
struct SyncOptInTests {

    private static let placeholderID = "__FRUGALBAR_SYNC_CLIENT_ID__"
    private static let placeholderSecret = "__FRUGALBAR_SYNC_CLIENT_SECRET__"

    @Test("a build without the client values has no sync client, so the setting is hidden")
    func noClientValuesMeansNoSync() {
        #expect(SyncClientConfiguration.resolve(
            stampedID: Self.placeholderID, stampedSecret: Self.placeholderSecret, environment: [:]) == nil)
        // Half a client is no client.
        #expect(SyncClientConfiguration.resolve(
            stampedID: Self.placeholderID, stampedSecret: Self.placeholderSecret,
            environment: [SyncClientConfiguration.clientIDEnvironmentKey: "fake-client-id.apps.example.test"]) == nil)
        #expect(SyncClientConfiguration.resolve(
            stampedID: Self.placeholderID, stampedSecret: Self.placeholderSecret,
            environment: [SyncClientConfiguration.clientIDEnvironmentKey: " ",
                          SyncClientConfiguration.clientSecretEnvironmentKey: "fake-client-secret-for-tests"]) == nil)
    }

    @Test("a source build reads FRUGALBAR_GOOGLE_SYNC_CLIENT_ID and FRUGALBAR_GOOGLE_SYNC_CLIENT_SECRET")
    func sourceBuildReadsEnvironment() throws {
        let configuration = try #require(SyncClientConfiguration.resolve(
            stampedID: Self.placeholderID, stampedSecret: Self.placeholderSecret,
            environment: [
                "FRUGALBAR_GOOGLE_SYNC_CLIENT_ID": "fake-client-id.apps.example.test",
                "FRUGALBAR_GOOGLE_SYNC_CLIENT_SECRET": "fake-client-secret-for-tests",
            ]))
        #expect(configuration.clientID == "fake-client-id.apps.example.test")
        #expect(configuration.clientSecret == "fake-client-secret-for-tests")
        #expect(!String(describing: configuration).contains("fake-client-secret"))
    }

    @Test("release-stamped values win over the environment")
    func stampedValuesWin() throws {
        let configuration = try #require(SyncClientConfiguration.resolve(
            stampedID: "fake-stamped-id.apps.example.test", stampedSecret: "fake-stamped-secret",
            environment: [
                "FRUGALBAR_GOOGLE_SYNC_CLIENT_ID": "fake-client-id.apps.example.test",
                "FRUGALBAR_GOOGLE_SYNC_CLIENT_SECRET": "fake-client-secret-for-tests",
            ]))
        #expect(configuration.clientID == "fake-stamped-id.apps.example.test")
    }

    @Test("with the values present, sync is off by default and nothing contacts Google while it is off")
    func offByDefaultAndSilent() async throws {
        let harness = SyncHarness(secrets: InMemorySyncSecrets())
        let status = await harness.publisher.status()
        #expect(status.phase == .off)
        #expect(status.canStart)

        await harness.publisher.resume()
        for minute in 0..<120 {
            await harness.publisher.submit(SyncFakes.source([SyncFakes.snapshot(used: Double(minute % 10) / 10)]))
            await harness.publisher.clockDidChange()
            await harness.publisher.tick()
            harness.clock.advance(by: 60)
        }
        #expect(await harness.publisher.nextWakeup() == nil)
        #expect(await harness.google.requests.isEmpty)
    }
}
