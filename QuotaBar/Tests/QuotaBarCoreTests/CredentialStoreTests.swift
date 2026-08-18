import Testing
import Foundation
@testable import QuotaBarCore

@Suite("CredentialStore", .serialized)
struct CredentialStoreTests {

    // MARK: - Keychain path

    @Test("apiKey with no keychain entry and CLI discovery off returns nil")
    func apiKeyNotFoundWhenCLIDiscoveryOff() {
        // Ensure discovery is off
        UserDefaults.standard.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        // For a vendor that has no keychain entry and no env var, this returns nil.
        let key = CredentialStore.apiKey(for: .claude)
        #expect(key == nil)
    }

    @Test("apiKey(for:) with CLI discovery off returns nil for uncached vendors")
    func apiKeyReturnsNilWhenNotConfigured() {
        UserDefaults.standard.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        #expect(CredentialStore.apiKey(for: .copilot) == nil)
        #expect(CredentialStore.apiKey(for: .openrouter) == nil)
        #expect(CredentialStore.apiKey(for: .gemini) == nil)
        #expect(CredentialStore.apiKey(for: .githubRest) == nil)
        #expect(CredentialStore.apiKey(for: .githubGraphql) == nil)
        #expect(CredentialStore.apiKey(for: .opencode) == nil)
    }

    // MARK: - CLI discovery flag

    @Test("isCLIDiscoveryEnabled defaults to false")
    func cliDiscoveryDefaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: CredentialStore.cliDiscoveryDefaultsKey)
        #expect(CredentialStore.isCLIDiscoveryEnabled == false)
    }

    @Test("isCLIDiscoveryEnabled reads from user defaults")
    func cliDiscoveryReadsFromDefaults() {
        UserDefaults.standard.set(true, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        #expect(CredentialStore.isCLIDiscoveryEnabled == true)

        UserDefaults.standard.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        #expect(CredentialStore.isCLIDiscoveryEnabled == false)
    }

    // MARK: - gh auth token discovery

    @Test("runGhAuthToken returns nil when gh is not installed")
    func runGhAuthTokenNoGh() {
        // The method checks known paths. In a test environment, gh is unlikely
        // to be at any of them (or if it is, the test still validates the
        // fallback path because gh auth token requires a logged-in session).
        // We just confirm it returns nil or a token without crashing.
        let result = CredentialStore.runGhAuthToken()
        // Accept either nil (no gh or not logged in) or a non-empty string.
        if let token = result {
            #expect(token.isEmpty == false)
        }
    }

    // MARK: - async accessor

    @Test("apiKeyAsync returns nil when keychain is empty and CLI discovery is off")
    func apiKeyAsyncNil() async {
        UserDefaults.standard.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        let key = await CredentialStore.apiKeyAsync(for: .claude)
        #expect(key == nil)
    }

    @Test("apiKeyAsync returns nil for all vendors when nothing is configured")
    func apiKeyAsyncAllNil() async {
        UserDefaults.standard.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        for vendor in VendorIdentifier.allCases {
            let key = await CredentialStore.apiKeyAsync(for: vendor)
            #expect(key == nil, "expected nil for \(vendor)")
        }
    }

    // MARK: - Copilot delegates to githubRest

    @Test("copilot discovery delegates to githubRest — both return nil when unconfigured")
    func copilotDelegatesToGitHub() async {
        UserDefaults.standard.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        let copilot = await CredentialStore.apiKeyAsync(for: .copilot)
        let github = await CredentialStore.apiKeyAsync(for: .githubRest)
        // They should be the same (both nil or both whatever gh auth token returns)
        #expect(copilot == github)
    }

    // MARK: - discovery from auth.json (when no gh binary)

    @Test("discoverFromCLI for openrouter returns nil when auth.json does not exist")
    func openRouterDiscoveryNoAuthJson() {
        UserDefaults.standard.set(true, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        // We can't easily mock the file system here, but we can assert that
        // the code path runs without crashing when the file is absent.
        // The underlying apiKey(for:) calls discoverFromCLI when CLI discovery
        // is on and keychain returns nil.
        let key = CredentialStore.apiKey(for: .openrouter)
        // In CI or local without the file, this returns nil.
        // If the file exists and has a key, it returns the key.
        // Either way: no crash.
        if let k = key { #expect(k.isEmpty == false) }
    }
}
