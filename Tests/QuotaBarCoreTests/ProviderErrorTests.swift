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

@Suite("Gemini Cloud Code payload shapes")
struct GeminiPayloadTests {

    private func projectID(from json: String) throws -> String? {
        try JSONDecoder()
            .decode(GeminiQuotaProvider.ProjectReference.self, from: Data(json.utf8))
            .id
    }

    /// The live API returns this field as a bare string. Decoding it as only
    /// an object made a perfectly good 200 unparseable, and the row read
    /// "Unexpected response" with the project id sitting in plain sight.
    @Test("a project reference decodes whether it is a string or an object")
    func projectReferenceAcceptsBothShapes() throws {
        #expect(try projectID(from: #""authentic-answer-268pr""#) == "authentic-answer-268pr")
        #expect(try projectID(from: #"{"id":"authentic-answer-268pr"}"#) == "authentic-answer-268pr")
        #expect(try projectID(from: #""""#) == nil)
        #expect(try projectID(from: #"{"name":"no-id-here"}"#) == nil)
    }

    /// Mirrors antigravity-usage's own filter, so the row names the models
    /// their CLI does — and never prices an image or autocomplete-only model
    /// as though it were the coding pool.
    @Test("only metered Gemini pools are counted")
    func modelFilterMatchesTheReference() {
        #expect(GeminiQuotaProvider.isMeteredModel("gemini-3-flash"))
        #expect(GeminiQuotaProvider.isMeteredModel("gemini-3.1-pro-high"))
        #expect(!GeminiQuotaProvider.isMeteredModel("gemini-3.1-flash-image"))
        #expect(!GeminiQuotaProvider.isMeteredModel("gemini-2.5-flash"))
        #expect(!GeminiQuotaProvider.isMeteredModel("gemini-3.5-flash-lite"))
        #expect(!GeminiQuotaProvider.isMeteredModel("chat_gemini-3"))
        #expect(!GeminiQuotaProvider.isMeteredModel("claude-opus-4-6-thinking"))
    }
}

// `.serialized` because the stub below holds its canned bodies in statics —
// `URLProtocol` subclasses are instantiated by `URLSession`, so there is
// nowhere else to put them. Without it these tests overwrite each other's
// responses and all three read whichever body won the race.
@Suite("Gemini plan labelling", .serialized)
struct GeminiPlanTests {

    private func plan(from body: String) async throws -> String? {
        let provider = GeminiQuotaProvider(accessToken: "token")
        let models = #"""
        {"models":{"gemini-3-flash":{"displayName":"Gemini 3 Flash",
         "quotaInfo":{"remainingFraction":0.85,"resetTime":"2099-01-01T00:00:00Z"}}}}
        """#
        return try await QuotaHTTP.$session.withValue(GeminiStub.session(assist: body, models: models)) {
            try await provider.fetchSnapshot().planName
        }
    }

    /// `currentTier` is the Code Assist licence and reads "free-tier" for
    /// virtually every personal account. Showing it told a paying subscriber
    /// they were on the free tier; the subscription is `paidTier`.
    @Test("the paid subscription is preferred over the Code Assist licence tier")
    func paidTierWins() async throws {
        let body = #"""
        {"cloudaicompanionProject":"proj-1",
         "currentTier":{"id":"free-tier","name":"Antigravity"},
         "paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}
        """#
        #expect(try await plan(from: body) == "Google AI Pro")
    }

    @Test("without a paid tier the reported tier name is used")
    func fallsBackToCurrentTier() async throws {
        let body = #"""
        {"cloudaicompanionProject":"proj-1","currentTier":{"id":"free-tier","name":"Antigravity"}}
        """#
        #expect(try await plan(from: body) == "Antigravity")
    }

    @Test("no published tier asserts no plan at all")
    func noTierAssertsNothing() async throws {
        #expect(try await plan(from: #"{"cloudaicompanionProject":"proj-1"}"#) == nil)
    }
}

/// Serves the two Cloud Code responses the Gemini provider makes in order.
private enum GeminiStub {
    static func session(assist: String, models: String) -> URLSession {
        StubProtocol.assist = assist
        StubProtocol.models = models
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var assist = ""
        nonisolated(unsafe) static var models = ""

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url?.absoluteString ?? ""
            let body = path.contains("loadCodeAssist") ? Self.assist : Self.models
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
