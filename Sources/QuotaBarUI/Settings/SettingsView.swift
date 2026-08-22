import SwiftUI
import QuotaBarCore

/// Tabbed preferences: credentials and general behaviour.
public struct SettingsView: View {

    private enum Tab: String { case keys = "API Keys", general = "General" }

    /// Only vendors we can actually do something with are offered. Claude is
    /// absent because Anthropic publishes no quota API, so a key field there
    /// would imply a capability that does not exist.
    private struct KeySlot: Identifiable {
        let id: VendorIdentifier
        let label: String
        let placeholder: String
        let note: String?
    }

    private static let slots: [KeySlot] = [
        .init(id: .claude, label: "Claude session",
              placeholder: "Claude OAuth access token",
              note: "Discovered from the Claude Code login when CLI discovery is on."),
        .init(id: .openai, label: "ChatGPT session",
              placeholder: "Codex ChatGPT access token",
              note: "Discovered from ~/.codex/auth.json when CLI discovery is on."),
        .init(id: .githubRest, label: "GitHub PAT",
              placeholder: "ghp_… or gho_…",
              note: "Used for REST, GraphQL and Copilot."),
        .init(id: .openrouter, label: "OpenRouter key",
              placeholder: "sk-or-v1-…",
              note: "Gauge shown only when the key has a spend cap."),
        .init(id: .opencode, label: "OpenCode token",
              placeholder: "oc_live_…",
              note: "Enables OpenCode Go monitoring."),
    ]

    @State private var selectedTab: Tab = .keys
    @State private var entered: [VendorIdentifier: String] = [:]
    @State private var loaded: [VendorIdentifier: String] = [:]
    @State private var perKeyStatus: [VendorIdentifier: String] = [:]
    @State private var isVerifying = false
    @State private var isSigningInToGemini = false
    @State private var geminiSignInStatus: String?
    @State private var geminiClientSecret = ""
    @State private var geminiClientID = ""
    @State private var loadedGeminiClientID = ""
    // Bound to the shared suite, not `.standard`: the toggle must apply to the
    // app whatever the executable happens to be named.
    @AppStorage(CredentialStore.cliDiscoveryDefaultsKey, store: CredentialStore.preferences)
    private var cliDiscovery = false

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            keysTab
                .tabItem { Label(Tab.keys.rawValue, systemImage: "key") }
                .tag(Tab.keys)
            generalTab
                .tabItem { Label(Tab.general.rawValue, systemImage: "gearshape") }
                .tag(Tab.general)
        }
        .frame(width: 460, height: 340)
        .padding()
        .onAppear(perform: loadKeys)
    }

    // MARK: - Keys

    private var keysTab: some View {
        Form {
            Section("Gemini") {
                Button("Connect Google account") { Task { await connectGemini() } }
                    .disabled(isSigningInToGemini)
                if isSigningInToGemini { ProgressView().controlSize(.small) }
                Text(geminiSignInStatus ?? "Reads Antigravity quota over Google OAuth. Tokens stay in your Keychain.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                TextField("OAuth client ID", text: $geminiClientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("OAuth client secret", text: $geminiClientSecret)
                    .textFieldStyle(.roundedBorder)
                Text("""
                     Required. The Cloud Code API is private to Google's own \
                     OAuth clients, so a client you create yourself will be \
                     refused — use one whose project Google has allowlisted, \
                     such as the pair the antigravity-usage CLI publishes in \
                     its OAUTH_CONFIG. Leave the secret blank to keep the \
                     stored one.
                     """)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Self.slots) { slot in
                Section {
                    SecureField(
                        slot.label,
                        text: Binding(
                            get: { entered[slot.id] ?? "" },
                            set: { entered[slot.id] = $0 }
                        ),
                        prompt: Text(slot.placeholder)
                    )
                    if let note = slot.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let status = perKeyStatus[slot.id] {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Save & verify") { Task { await saveAndVerify() } }
                    .disabled(isVerifying || !hasChanges)
                if isVerifying { ProgressView().controlSize(.small) }
            }
            .padding(.top, 8)
        }
        .formStyle(.grouped)
    }

    /// The Gemini client fields count too. They did not, so typing a client ID
    /// left "Save & verify" greyed out and the only way to persist it was the
    /// Connect button — which is not where anyone looks for "save".
    private var hasChanges: Bool {
        if Self.slots.contains(where: { (entered[$0.id] ?? "") != (loaded[$0.id] ?? "") }) { return true }
        if geminiClientID != loadedGeminiClientID { return true }
        // Blank means "keep the stored secret", so only a typed one is a change.
        return !geminiClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Read credentials from local CLI tools", isOn: $cliDiscovery)
                Text("""
                     When on, FrugalBar may run `gh auth token` and read \
                     ~/.local/share/opencode/auth.json if the Keychain has no \
                     entry for a provider. Off by default: this reads \
                     credentials you have not explicitly given the app.
                     """)

                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Credential discovery")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func loadKeys() {
        var current: [VendorIdentifier: String] = [:]
        for slot in Self.slots {
            current[slot.id] = (try? KeychainManager.shared.get(label: slot.id.rawValue)) ?? ""
        }
        loaded = current
        entered = current

        geminiClientID = GeminiOAuthLogin.storedClientID() ?? ""
        loadedGeminiClientID = geminiClientID
        // The secret is never read back for display; the field shows only
        // whether one is already stored, so reopening Settings cannot leak it.
        if GeminiOAuthLogin.hasClientSecretOverride(), geminiSignInStatus == nil {
            geminiSignInStatus = "Using your own client secret. Leave the field blank to keep it."
        }
    }

    private var hasGeminiClientEdits: Bool {
        geminiClientID != loadedGeminiClientID
            || !geminiClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connectGemini() async {
        isSigningInToGemini = true
        defer { isSigningInToGemini = false }

        // Persist the client configuration before signing in: the flow reads
        // it from the Keychain, so a secret typed but not yet saved would fail
        // the exchange and look like a rejected sign-in.
        do {
            try GeminiOAuthLogin.saveClientConfiguration(
                clientID: geminiClientID, clientSecret: geminiClientSecret)
        } catch {
            geminiSignInStatus = "Could not save the client configuration to the Keychain"
            return
        }

        do {
            try await GeminiOAuthLogin.shared.signIn()
            geminiSignInStatus = "Connected"
        } catch let error as ProviderError where error.reason == .notConfigured {
            geminiSignInStatus = "Add an OAuth client ID and secret above first"
        } catch let error as GeminiOAuthError {
            // Google names the misconfiguration; passing it through turns a
            // silent failure into one the user can act on.
            geminiSignInStatus = "Google refused the sign-in: \(error.summary)"
        } catch {
            geminiSignInStatus = "Google sign-in did not complete"
        }
    }

    /// Writes only what changed and deletes what was cleared. Where the vendor
    /// has an endpoint to check against, the key is then exercised for real, so
    /// a truncated paste fails here — where the user can fix it — rather than
    /// as an unexplained blank row later. Vendors with no such endpoint report
    /// "Saved — cannot be verified" rather than implying a check happened.
    private func saveAndVerify() async {
        isVerifying = true
        defer { isVerifying = false }

        // Persist the Gemini client alongside the vendor keys. Changing it
        // orphans any stored session — a refresh token belongs to the client
        // that issued it — so say so rather than letting the row quietly read
        // "Not configured" afterwards.
        let clientChanged = geminiClientID != loadedGeminiClientID
        if hasGeminiClientEdits {
            do {
                try GeminiOAuthLogin.saveClientConfiguration(
                    clientID: geminiClientID, clientSecret: geminiClientSecret)
                loadedGeminiClientID = geminiClientID
                geminiClientSecret = ""
                geminiSignInStatus = clientChanged
                    ? "Client saved. Connect Google account again to sign in with it."
                    : "Client secret saved."
            } catch {
                geminiSignInStatus = "Could not save the client configuration to the Keychain"
            }
        }

        var githubPatChanged = false

        for slot in Self.slots {
            let new = (entered[slot.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let old = loaded[slot.id] ?? ""
            guard new != old else { continue }
            
            if slot.id == .githubRest { githubPatChanged = true }

            do {
                if new.isEmpty {
                    // Clearing a field means "forget this", not "store empty".
                    try KeychainManager.shared.delete(label: slot.id.rawValue)
                    perKeyStatus[slot.id] = "Removed"
                } else {
                    try KeychainManager.shared.set(key: new, label: slot.id.rawValue)
                    perKeyStatus[slot.id] = await verify(slot.id, key: new)
                }
                loaded[slot.id] = new
            } catch {
                perKeyStatus[slot.id] = Self.keychainAdvice(for: error)
            }
        }

        // GitHub's PAT backs three providers; keep them in step. A partial
        // sync must be reported — otherwise the GraphQL and Copilot rows keep
        // serving a revoked token with no field to fix it in.
        if githubPatChanged, let pat = loaded[.githubRest] {
            let failures = applyGitHubTokenToLinkedVendors(pat)
            if !failures.isEmpty {
                perKeyStatus[.githubRest] = "Saved, but could not sync to \(failures.joined(separator: ", "))"
            }
        }
    }

    /// Returns the display names of any linked vendors that could not be synced.
    private func applyGitHubTokenToLinkedVendors(_ pat: String) -> [String] {
        var failed: [String] = []
        for vendor in [VendorIdentifier.githubGraphql, .copilot] {
            do {
                if pat.isEmpty {
                    try KeychainManager.shared.delete(label: vendor.rawValue)
                } else {
                    try KeychainManager.shared.set(key: pat, label: vendor.rawValue)
                }
            } catch {
                failed.append(vendor.displayName)   // continue; don't abort the rest
            }
        }
        return failed
    }

    private func verify(_ vendor: VendorIdentifier, key: String) async -> String {
        let provider: any QuotaProvider
        switch vendor {
        case .claude:      provider = ClaudeQuotaProvider(apiKey: key)
        case .openai:      provider = OpenAIQuotaProvider(accessToken: key)
        case .githubRest:  provider = GitHubRestProvider(token: key)
        case .openrouter:  provider = OpenRouterProvider(apiKey: key)
        // Gemini has no key slot — it is connected through the OAuth button
        // above — but the switch must stay exhaustive.
        case .gemini:      provider = GeminiQuotaProvider(accessToken: key)
        case .opencode:    provider = OpenCodeGoProvider(apiKey: key)
        case .copilot:     provider = GitHubCopilotProvider(token: key)
        case .githubGraphql: provider = GitHubGraphQLProvider(token: key)
        }

        guard let snapshot = try? await provider.fetchSnapshot() else {
            return "Could not reach the vendor"
        }
        switch snapshot.status.unavailableReason {
        case .credentialRejected: return "Rejected — check the key"
        case .notConfigured:      return "Empty"
        case .offline, .timedOut: return "Could not reach the vendor"
        case .badResponse:        return "Unexpected response"
        case .rateLimited:        return "Vendor is throttling — try again shortly"
        case .unsupported:        return "Saved — no usage to read"
        case nil:                 return "Key accepted"
        }
    }


    /// Turns an OSStatus into something a user can act on.
    private static func keychainAdvice(for error: Error) -> String {
        guard case let KeychainError.unknown(status) = error else {
            return "Could not save"
        }
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed:
            return "Unlock your Keychain and try again"
        case errSecUserCanceled:
            return "Keychain access was declined"
        case errSecMissingEntitlement:
            return "Requires a signed app bundle — see README"
        default:
            return "Keychain error \(status)"
        }
    }
}
