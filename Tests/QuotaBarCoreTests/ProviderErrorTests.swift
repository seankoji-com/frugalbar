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
