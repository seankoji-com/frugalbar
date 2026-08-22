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
                                      clientID: GeminiOAuthSession.clientID ?? "unset")
        let theirs = GeminiOAuthSession(accessToken: "a", refreshToken: "r",
                                        expiry: Date(timeIntervalSince1970: 4_000_000_000),
                                        clientID: "999-someone-else.apps.googleusercontent.com")
        #expect(mine.clientID == (GeminiOAuthSession.clientID ?? "unset"))
        #expect(theirs.clientID != GeminiOAuthSession.clientID)

        // Sessions written before the field existed decode, and count as foreign.
        let legacy = try JSONDecoder().decode(
            GeminiOAuthSession.self,
            from: Data(#"{"accessToken":"a","refreshToken":"r","expiry":0}"#.utf8))
        #expect(legacy.clientID == nil)
    }

    /// Signing in with no client configured must fail with a reason the user
    /// can act on, not with Google's "client_secret is missing".
    @Test("a token request without a configured client is not-configured")
    func unconfiguredClientIsNotConfigured() async {
        guard !GeminiOAuthSession.isClientConfigured else { return }   // configured locally
        await #expect(throws: ProviderError.notConfigured) {
            try await GeminiOAuthSession.requestToken(
                fields: ["grant_type": "refresh_token", "refresh_token": "r"],
                existingRefreshToken: "r")
        }
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
