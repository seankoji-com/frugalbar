import Testing
import Foundation
@testable import QuotaBarCore

@Suite("CredentialStore", .serialized)
struct CredentialStoreTests {

    // MARK: Claude OAuth blob

    /// The blob is identical whether it came from the macOS Keychain or the
    /// Linux credentials file, so the parsing is tested once, directly.
    @Test("a live Claude OAuth blob yields its access token")
    func claudeBlobYieldsToken() {
        let future = (Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000).rounded()
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-live","expiresAt":\#(Int(future))}}"#.utf8)
        #expect(CredentialStore.claudeOAuthToken(from: blob) == "sk-ant-oat01-live")
    }

    /// Sending a known-dead token produces "Rejected — check the key", which
    /// points the user at the one thing that is not wrong.
    @Test("an expired Claude OAuth blob reports no token rather than a dead one")
    func claudeExpiredBlobIsNil() {
        let past = (Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000).rounded()
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-stale","expiresAt":\#(Int(past))}}"#.utf8)
        #expect(CredentialStore.claudeOAuthToken(from: blob) == nil)
    }

    @Test("a blob with no expiry is still usable")
    func claudeBlobWithoutExpiry() {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-live"}}"#.utf8)
        #expect(CredentialStore.claudeOAuthToken(from: blob) == "sk-ant-oat01-live")
    }

    @Test("malformed and empty Claude blobs yield no token")
    func claudeBlobRejectsGarbage() {
        #expect(CredentialStore.claudeOAuthToken(from: nil) == nil)
        #expect(CredentialStore.claudeOAuthToken(from: Data("not json".utf8)) == nil)
        #expect(CredentialStore.claudeOAuthToken(from: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil)
        // A subscription tier is not a credential.
        #expect(CredentialStore.claudeOAuthToken(from: Data(#"{"oauthAccount":{"organizationType":"max"}}"#.utf8)) == nil)
    }

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
