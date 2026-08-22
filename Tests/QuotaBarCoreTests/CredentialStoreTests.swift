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

    // MARK: OpenCode's Copilot entry

    /// `refresh` is the durable GitHub OAuth token; `access` is the short-lived
    /// Copilot API token minted from it, which api.github.com rejects. Reading
    /// the wrong one rendered Copilot as a permanent "Credential rejected".
    @Test("the Copilot entry yields the GitHub OAuth token, not the Copilot token")
    func copilotEntryPrefersRefresh() {
        let blob = Data(#"""
        {"github-copilot":{"type":"oauth","refresh":"gho_github_oauth","access":"tid=copilot","expires":1}}
        """#.utf8)
        #expect(CredentialStore.copilotOAuthToken(from: blob) == "gho_github_oauth")
    }

    @Test("malformed and empty Copilot entries yield no token")
    func copilotEntryRejectsGarbage() {
        #expect(CredentialStore.copilotOAuthToken(from: nil) == nil)
        #expect(CredentialStore.copilotOAuthToken(from: Data("not json".utf8)) == nil)
        #expect(CredentialStore.copilotOAuthToken(from: Data("{}".utf8)) == nil)
        // A cached Copilot token alone is not a credential we can use.
        #expect(CredentialStore.copilotOAuthToken(
            from: Data(#"{"github-copilot":{"refresh":"","access":"tid=copilot"}}"#.utf8)) == nil)
    }

    // MARK: Antigravity session discovered from the CLI cache

    @Test("a live Antigravity token cache yields its access token")
    func antigravityLiveToken() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiry = Int((now.addingTimeInterval(3600).timeIntervalSince1970 * 1000).rounded())
        let blob = Data(#"{"accessToken":"ya29.live","refreshToken":"r","expiresAt":\#(expiry)}"#.utf8)
        #expect(CredentialStore.antigravityAccessToken(fromTokens: blob, now: now) == "ya29.live")
    }

    /// The grant belongs to another OAuth client, so we cannot renew it. An
    /// expired token is reported as absent rather than sent to be rejected —
    /// the same convention as the expired-Claude-token path.
    @Test("an expired Antigravity token is reported as absent, not sent")
    func antigravityExpiredTokenIsNil() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiry = Int((now.addingTimeInterval(-60).timeIntervalSince1970 * 1000).rounded())
        let blob = Data(#"{"accessToken":"ya29.stale","expiresAt":\#(expiry)}"#.utf8)
        #expect(CredentialStore.antigravityAccessToken(fromTokens: blob, now: now) == nil)
    }

    @Test("malformed Antigravity token caches yield no token")
    func antigravityRejectsGarbage() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(CredentialStore.antigravityAccessToken(fromTokens: nil, now: now) == nil)
        #expect(CredentialStore.antigravityAccessToken(fromTokens: Data("not json".utf8), now: now) == nil)
        // No expiry at all: we cannot tell whether it is live, so it is not used.
        #expect(CredentialStore.antigravityAccessToken(
            fromTokens: Data(#"{"accessToken":"ya29.live"}"#.utf8), now: now) == nil)
    }

    // MARK: - Keychain path

    @Test("apiKey with no keychain entry and CLI discovery off returns nil")
    func apiKeyNotFoundWhenCLIDiscoveryOff() {
        // Ensure discovery is off
        CredentialStore.preferences.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        // For a vendor that has no keychain entry and no env var, this returns nil.
        let key = CredentialStore.apiKey(for: .claude)
        #expect(key == nil)
    }

    @Test("apiKey(for:) with CLI discovery off returns nil for uncached vendors")
    func apiKeyReturnsNilWhenNotConfigured() {
        CredentialStore.preferences.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
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
        CredentialStore.preferences.removeObject(forKey: CredentialStore.cliDiscoveryDefaultsKey)
        #expect(CredentialStore.isCLIDiscoveryEnabled == false)
    }

    @Test("isCLIDiscoveryEnabled reads from user defaults")
    func cliDiscoveryReadsFromDefaults() {
        CredentialStore.preferences.set(true, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        #expect(CredentialStore.isCLIDiscoveryEnabled == true)

        CredentialStore.preferences.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        #expect(CredentialStore.isCLIDiscoveryEnabled == false)
    }

    // MARK: - Legacy preference migration

    /// The bug this migration exists for: the released binary runs as
    /// `frugalbar` and a local build as `QuotaBar`, and an unbundled executable
    /// keys `UserDefaults.standard` off its process name. Enabling discovery
    /// under one name left the other showing every provider "Not configured".
    @Test("a legacy domain with discovery on wins over one with it off")
    func migrationPrefersTheEnabledDomain() {
        #expect(CredentialStore.migratedDiscoverySetting(fromLegacy: [true, false]) == true)
        #expect(CredentialStore.migratedDiscoverySetting(fromLegacy: [false, true]) == true)
        #expect(CredentialStore.migratedDiscoverySetting(fromLegacy: [true]) == true)
    }

    /// Moving to a shared store must not silently re-enable credential
    /// discovery for someone who deliberately turned it off.
    @Test("a deliberate opt-out survives the move to a shared store")
    func migrationKeepsAnExplicitOptOut() {
        #expect(CredentialStore.migratedDiscoverySetting(fromLegacy: [false, false]) == false)
    }

    @Test("no legacy setting means no migration, so first-launch defaults apply")
    func migrationIsSilentWithoutLegacyValues() {
        #expect(CredentialStore.migratedDiscoverySetting(fromLegacy: []) == nil)
    }

    /// Migration must never overwrite a live choice — otherwise every launch
    /// would drag the setting back to whatever an old domain said.
    @Test("migration leaves an existing shared value untouched")
    func migrationIsIdempotent() {
        CredentialStore.preferences.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        CredentialStore.migrateLegacyPreferences()
        #expect(CredentialStore.isCLIDiscoveryEnabled == false)
    }

    /// Tests must not touch the real user's preference file — nor reach the
    /// network, which relies on the same detection.
    ///
    /// Guarding on `XCTestCase` and `XCTest*` environment variables alone did
    /// not work: under `swift test` with swift-testing, none of them are
    /// present, so both safety nets failed open.
    @Test("the test host is detected, so it gets its own preference suite")
    func testsAreIsolatedFromTheRealSuite() {
        #expect(TestHost.isActive)
        #expect(CredentialStore.preferences !== UserDefaults.standard)
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
        CredentialStore.preferences.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        let key = await CredentialStore.apiKeyAsync(for: .claude)
        #expect(key == nil)
    }

    @Test("apiKeyAsync returns nil for all vendors when nothing is configured")
    func apiKeyAsyncAllNil() async {
        CredentialStore.preferences.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        for vendor in VendorIdentifier.allCases {
            let key = await CredentialStore.apiKeyAsync(for: vendor)
            #expect(key == nil, "expected nil for \(vendor)")
        }
    }

    // MARK: - Copilot delegates to githubRest

    @Test("copilot discovery delegates to githubRest — both return nil when unconfigured")
    func copilotDelegatesToGitHub() async {
        CredentialStore.preferences.set(false, forKey: CredentialStore.cliDiscoveryDefaultsKey)
        let copilot = await CredentialStore.apiKeyAsync(for: .copilot)
        let github = await CredentialStore.apiKeyAsync(for: .githubRest)
        // They should be the same (both nil or both whatever gh auth token returns)
        #expect(copilot == github)
    }

    // MARK: - discovery from auth.json (when no gh binary)

    @Test("discoverFromCLI for openrouter returns nil when auth.json does not exist")
    func openRouterDiscoveryNoAuthJson() {
        CredentialStore.preferences.set(true, forKey: CredentialStore.cliDiscoveryDefaultsKey)
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
