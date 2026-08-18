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
        .init(id: .githubRest, label: "GitHub PAT",
              placeholder: "ghp_… or gho_…",
              note: "Used for REST, GraphQL and Copilot."),
        .init(id: .openrouter, label: "OpenRouter key",
              placeholder: "sk-or-v1-…",
              note: "Gauge shown only when the key has a spend cap."),
        .init(id: .gemini, label: "Gemini key",
              placeholder: "AIzaSy…",
              note: "Validates the key; Google exposes no usage figure."),
        .init(id: .opencode, label: "OpenCode token",
              placeholder: "oc_live_…",
              note: "Presence only; OpenCode exposes no usage API."),
    ]

    @State private var selectedTab: Tab = .keys
    @State private var entered: [VendorIdentifier: String] = [:]
    @State private var loaded: [VendorIdentifier: String] = [:]
    @State private var perKeyStatus: [VendorIdentifier: String] = [:]
    @State private var isVerifying = false
    @AppStorage(CredentialStore.cliDiscoveryDefaultsKey) private var cliDiscovery = false

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

    private var hasChanges: Bool {
        Self.slots.contains { (entered[$0.id] ?? "") != (loaded[$0.id] ?? "") }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Read credentials from local CLI tools", isOn: $cliDiscovery)
                Text("""
                     When on, QuotaBar may run `gh auth token` and read \
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
    }

    /// Writes only what changed and deletes what was cleared. Where the vendor
    /// has an endpoint to check against, the key is then exercised for real, so
    /// a truncated paste fails here — where the user can fix it — rather than
    /// as an unexplained blank row later. Vendors with no such endpoint report
    /// "Saved — cannot be verified" rather than implying a check happened.
    private func saveAndVerify() async {
        isVerifying = true
        defer { isVerifying = false }

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
        // OpenCode publishes no endpoint to verify against, so its provider
        // makes no call. Reporting "Key accepted" would be a claim we cannot
        // support. Any vendor not listed here is likewise unverifiable — the
        // default must not silently verify against GitHub.
        let provider: any QuotaProvider
        switch vendor {
        case .githubRest:  provider = GitHubRestProvider(token: key)
        case .openrouter:  provider = OpenRouterProvider(apiKey: key)
        case .gemini:      provider = GeminiQuotaProvider(apiKey: key)
        default:           return "Saved — cannot be verified"
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
        case .unsupported:        return "Key accepted"
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
