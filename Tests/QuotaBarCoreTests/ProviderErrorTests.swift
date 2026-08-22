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

@Suite("Gemini OAuth client configuration", .serialized)
struct GeminiOAuthClientTests {

    private func clearStoredClient() {
        try? KeychainManager.shared.delete(label: GeminiOAuthSession.clientSecretKeychainLabel)
        try? KeychainManager.shared.delete(label: GeminiOAuthSession.clientIDKeychainLabel)
    }

    /// Google requires `client_secret` on this client type's token exchange.
    /// Without one every sign-in died at the last step with "client_secret is
    /// missing", surfaced to the user as an unexplained failure — so the flow
    /// now refuses before opening a browser, with a reason it can act on.
    @Test("a token request without a client secret fails as not-configured, not as a bad response")
    func missingSecretIsNotConfigured() async {
        clearStoredClient()
        defer { clearStoredClient() }
        guard GeminiOAuthSession.clientSecret == nil else { return }   // env var set locally

        await #expect(throws: ProviderError.notConfigured) {
            try await GeminiOAuthSession.requestToken(
                fields: ["grant_type": "refresh_token", "refresh_token": "r"],
                existingRefreshToken: "r")
        }
    }

    /// The secret field is always blank on open because it is never read back
    /// for display. Saving a blank must therefore keep what is stored, or
    /// simply reopening Settings would wipe it.
    @Test("saving a blank secret keeps the stored one")
    func blankSecretIsNotDestructive() throws {
        clearStoredClient()
        defer { clearStoredClient() }

        try GeminiOAuthLogin.saveClientConfiguration(clientID: "", clientSecret: "GOCSPX-example")
        #expect(GeminiOAuthLogin.hasClientSecret())

        try GeminiOAuthLogin.saveClientConfiguration(clientID: "", clientSecret: "   ")
        #expect(GeminiOAuthLogin.hasClientSecret())

        try GeminiOAuthLogin.clearClientSecret()
        #expect(GeminiOAuthSession.clientSecret == nil || GeminiOAuthLogin.hasClientSecret())
    }

    /// The ID field *is* shown pre-filled, so clearing it is a deliberate
    /// revert to the built-in client rather than an accident.
    @Test("a stored client ID overrides the built-in one, and clearing it reverts")
    func clientIDOverrideRoundTrips() throws {
        clearStoredClient()
        defer { clearStoredClient() }

        #expect(GeminiOAuthSession.clientID == GeminiOAuthSession.defaultClientID)

        try GeminiOAuthLogin.saveClientConfiguration(
            clientID: "123-custom.apps.googleusercontent.com", clientSecret: "")
        #expect(GeminiOAuthSession.clientID == "123-custom.apps.googleusercontent.com")
        #expect(GeminiOAuthLogin.storedClientID() == "123-custom.apps.googleusercontent.com")

        try GeminiOAuthLogin.saveClientConfiguration(clientID: "", clientSecret: "")
        #expect(GeminiOAuthSession.clientID == GeminiOAuthSession.defaultClientID)
        #expect(GeminiOAuthLogin.storedClientID() == nil)
    }

    /// A public repository must not carry the secret it tells users to paste.
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
            #expect(!text.contains("GOCSPX-"), "client secret literal in \(file.lastPathComponent)")
        }
    }
}
