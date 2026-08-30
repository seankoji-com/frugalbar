import Testing
import Foundation
@testable import QuotaBarCore

@Suite("ProviderError")
struct ProviderErrorTests {

    @Test("init with UnavailableReason stores it")
    func initStoresReason() {
        let err = ProviderError(.notConfigured)
        #expect(err.reason == .notConfigured)
    }

    @Test("static notConfigured")
    func staticNotConfigured() {
        #expect(ProviderError.notConfigured.reason == .notConfigured)
    }

    @Test("static credentialRejected")
    func staticCredentialRejected() {
        #expect(ProviderError.credentialRejected.reason == .credentialRejected)
    }

    @Test("static badResponse")
    func staticBadResponse() {
        #expect(ProviderError.badResponse.reason == .badResponse)
    }

    @Test("equality by reason")
    func equality() {
        #expect(ProviderError.notConfigured == ProviderError.notConfigured)
        #expect(ProviderError.notConfigured != ProviderError.credentialRejected)
        #expect(ProviderError.badResponse == ProviderError(.badResponse))
    }

    @Test("all static constructors are distinct")
    func allDistinct() {
        let errors = [
            ProviderError.notConfigured,
            ProviderError.credentialRejected,
            ProviderError.badResponse,
        ]
        #expect(errors.count == 3)
        #expect(errors[0] != errors[1])
        #expect(errors[1] != errors[2])
        #expect(errors[0] != errors[2])
    }
}

@Suite("Gemini OAuth client configuration")
struct GeminiOAuthClientTests {

    // These tests deliberately never touch the Keychain. An earlier version
    // exercised `saveClientConfiguration` against the production labels and
    // deleted the developer's real, working client secret on the first run.
    // Test code must not be able to destroy a live credential.

    /// The secret field is always blank on open, because it is never read back
    /// for display. Saving a blank must therefore keep what is stored, or
    /// simply reopening Settings would wipe it.
    @Test("a blank secret field means keep the stored one")
    func blankSecretIsNotDestructive() {
        #expect(GeminiOAuthLogin.secretToStore(entered: "") == nil)
        #expect(GeminiOAuthLogin.secretToStore(entered: "   \n ") == nil)
        #expect(GeminiOAuthLogin.secretToStore(entered: "  GOCSPX-example  ") == "GOCSPX-example")
    }

    /// The client ID field *is* shown pre-filled, so clearing it is a
    /// deliberate revert to the built-in client rather than an accident.
    @Test("a blank client ID field means revert to the built-in client")
    func blankClientIDReverts() {
        #expect(GeminiOAuthLogin.clientIDToStore(entered: "") == nil)
        #expect(GeminiOAuthLogin.clientIDToStore(entered: " 123-custom.apps.googleusercontent.com ")
            == "123-custom.apps.googleusercontent.com")
    }

    /// No OAuth client secret belongs in this repository — not FrugalBar's,
    /// and not the first-party one the Cloud Code API requires. GitHub's push
    /// protection rejects both, and the honest place for them is the operator's
    /// Keychain. This guard fails the build before a push ever gets that far.
    @Test("no client secret is compiled into the source tree")
    func noSecretInSource() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuotaBarCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.ranges(of: try Regex("GOCSPX-[A-Za-z0-9_-]+")).isEmpty,
                    "client secret literal in \(file.lastPathComponent)")
            #expect(text.ranges(of: try Regex("[0-9]{9,14}-[a-z0-9]{20,}\\.apps\\.googleusercontent\\.com")).isEmpty,
                    "OAuth client ID literal in \(file.lastPathComponent)")
        }
    }

    /// A refresh token belongs to the client that issued it. Carrying a session
    /// across a client change left users on "Credential rejected" with a stored
    /// session that could never work.
    @Test("a session minted by another OAuth client is not reused")
    func foreignSessionIsDiscarded() throws {
        let mine = GeminiOAuthSession(accessToken: "a", refreshToken: "r",
                                      expiry: Date(timeIntervalSince1970: 4_000_000_000),
                                      clientID: "111-mine.apps.googleusercontent.com")
        let theirs = GeminiOAuthSession(accessToken: "a", refreshToken: "r",
                                        expiry: Date(timeIntervalSince1970: 4_000_000_000),
                                        clientID: "999-someone-else.apps.googleusercontent.com")
        #expect(mine.clientID != theirs.clientID)

        // Sessions written before the field existed decode, and count as foreign.
        let legacy = try JSONDecoder().decode(
            GeminiOAuthSession.self,
            from: Data(#"{"accessToken":"a","refreshToken":"r","expiry":0}"#.utf8))
        #expect(legacy.clientID == nil)
    }

}

@Suite("Gemini OAuth callback parsing")
struct GeminiOAuthCallbackOutcomeTests {

    private static let expectedState = "xyz-expected-state"

    private func request(target: String) -> String {
        "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nConnection: close\r\n\r\n"
    }

    /// Browsers speculatively request /favicon.ico on the callback's origin.
    /// It carries no matching code or state, so it must be classified as a
    /// failed callback — never mistaken for a successful sign-in. (The
    /// caller, `handleCallback`, is what keeps this from aborting an
    /// in-progress sign-in: it checks the path before ever calling
    /// `callbackOutcome` and answers a bare 404 without touching the
    /// continuation.)
    @Test("a /favicon.ico probe is never treated as a successful callback")
    func faviconProbeIsRejected() {
        let outcome = GeminiOAuthLogin.callbackOutcome(
            request: request(target: "/favicon.ico"),
            expectedState: Self.expectedState)
        guard case .failure(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error.reason == .badResponse)
    }

    /// The CSRF protection: a callback whose `state` does not match the one
    /// we generated for this sign-in must be rejected outright. This must
    /// never be relaxed, even to make some other test easier to satisfy.
    @Test("a state-param mismatch is rejected")
    func stateMismatchIsRejected() {
        let outcome = GeminiOAuthLogin.callbackOutcome(
            request: request(target: "/callback?code=abc123&state=someone-elses-state"),
            expectedState: Self.expectedState)
        guard case .failure(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error.reason == .badResponse)
    }

    /// Google reports consent failures via an `error` query parameter rather
    /// than omitting `code` — that must still fail the callback even when
    /// `state` matches.
    @Test("an error param present fails the callback")
    func errorParamIsRejected() {
        let outcome = GeminiOAuthLogin.callbackOutcome(
            request: request(target: "/callback?error=access_denied&state=\(Self.expectedState)"),
            expectedState: Self.expectedState)
        guard case .failure(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error.reason == .badResponse)
    }

    /// No `code` means nothing to exchange, regardless of `state` matching.
    @Test("a missing code param fails the callback")
    func missingCodeIsRejected() {
        let outcome = GeminiOAuthLogin.callbackOutcome(
            request: request(target: "/callback?state=\(Self.expectedState)"),
            expectedState: Self.expectedState)
        guard case .failure(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error.reason == .badResponse)
    }

    /// Matching state, no error, and a code present: the code is returned so
    /// the exchange step can run.
    @Test("a well-formed callback with matching state succeeds")
    func happyPathSucceeds() {
        let outcome = GeminiOAuthLogin.callbackOutcome(
            request: request(target: "/callback?code=abc123&state=\(Self.expectedState)"),
            expectedState: Self.expectedState)
        guard case .success(let code) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(code == "abc123")
    }
}

@Suite("Gemini OAuth token errors")
struct GeminiOAuthErrorTests {

    /// Three rounds of debugging were spent on "sign-in did not complete"
    /// because Google's own explanation was discarded as a bare badResponse.
    @Test("Google's error code and description are carried through")
    func googleErrorIsSurfaced() {
        let body = Data(#"{"error":"invalid_client","error_description":"Unauthorized"}"#.utf8)
        let error = GeminiOAuthError(from: body, statusCode: 401)
        #expect(error.code == "invalid_client")
        #expect(error.detail == "Unauthorized")
        #expect(error.summary == "invalid_client — Unauthorized")
    }

    /// A body that is not the documented error shape still has to say
    /// something more useful than nothing.
    @Test("an unparseable error body falls back to the status code")
    func unparseableErrorFallsBack() {
        let error = GeminiOAuthError(from: Data("<html>gateway timeout</html>".utf8), statusCode: 504)
        #expect(error.code == "http_504")
        #expect(error.summary == "http_504")
    }
}

@Suite("Gemini plan labelling", .serialized)
struct GeminiPlanTests {

    private static let summary = #"""
    {"groups":[{"displayName":"Gemini Models","buckets":[
      {"bucketId":"gemini-5h","window":"5h","resetTime":"2099-01-01T00:00:00Z","remainingFraction":0.85}]}]}
    """#

    private func plan(from body: String) async throws -> String? {
        let provider = GeminiQuotaProvider(accessToken: "token")
        return try await QuotaHTTP.$session.withValue(
            GeminiStub.session(assist: body, summary: Self.summary)
        ) {
            try await provider.fetchSnapshot().planName
        }
    }

    /// `currentTier` is the Code Assist licence and reads "free-tier" for
    /// virtually every personal account. Showing it told a paying subscriber
    /// they were on the free tier; the subscription is `paidTier`.
    @Test("the paid subscription is preferred over the Code Assist licence tier")
    func paidTierWins() async throws {
        let body = #"""
        {"currentTier":{"id":"free-tier","name":"Antigravity"},
         "paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}
        """#
        #expect(try await plan(from: body) == "Google AI Pro")
    }

    @Test("without a paid tier the reported tier name is used")
    func fallsBackToCurrentTier() async throws {
        let body = #"{"currentTier":{"id":"free-tier","name":"Antigravity"}}"#
        #expect(try await plan(from: body) == "Antigravity")
    }

    @Test("no published tier asserts no plan at all")
    func noTierAssertsNothing() async throws {
        #expect(try await plan(from: "{}") == nil)
    }
}

/// Serves the two Cloud Code responses the Gemini provider makes.
private enum GeminiStub {
    static func session(assist: String, summary: String) -> URLSession {
        StubProtocol.assist = assist
        StubProtocol.summary = summary
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var assist = ""
        nonisolated(unsafe) static var summary = ""

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url?.absoluteString ?? ""
            let body = path.contains("loadCodeAssist") ? Self.assist : Self.summary
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
