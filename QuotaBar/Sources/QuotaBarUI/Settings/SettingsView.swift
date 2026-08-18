import SwiftUI
import QuotaBarCore

/// Tabbed preferences view for API keys and refresh interval.
public struct SettingsView: View {
    @State private var selectedTab = "API Keys"
    @State private var claudeKey = ""
    @State private var geminiKey = ""
    @State private var openRouterKey = ""
    @State private var githubPat = ""
    @State private var openCodeToken = ""
    @State private var refreshInterval: Double = 120
    @State private var launchAtLogin = true
    @State private var compactDensity = true
    @State private var statusMessage: String?

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            keysTab
                .tabItem { Label("API Keys", systemImage: "key") }
                .tag("API Keys")

            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("General")
        }
        .frame(width: 400, height: 300)
        .padding()
        .onAppear(perform: loadKeys)
    }

    // MARK: - Keys Tab

    private var keysTab: some View {
        Form {
            KeyField(label: "Claude API Key", placeholder: "sk-ant-...", text: $claudeKey)
            KeyField(label: "Gemini API Key", placeholder: "AIzaSy...", text: $geminiKey)
            KeyField(label: "OpenRouter API Key", placeholder: "sk-or-v1-...", text: $openRouterKey)
            KeyField(label: "GitHub PAT", placeholder: "ghp_... or gho_...", text: $githubPat)
            KeyField(label: "OpenCode Go Token", placeholder: "oc_live_...", text: $openCodeToken)

            HStack {
                Button("Save Keys") {
                    saveKeys()
                }

                if let msg = statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Refresh interval: \(Int(refreshInterval))s")
                        .font(.caption)
                    Slider(value: $refreshInterval, in: 15...600, step: 15) {
                        Text("Refresh interval")
                    }
                }

                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Compact density", isOn: $compactDensity)

                Divider()

                Text("CLI Discovery")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Keys from gh auth, ~/.claude.json, and auth.json are auto-detected.")
                    .font(.caption2)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
        }
    }

    // MARK: - Helpers

    private func loadKeys() {
        Task {
            claudeKey = (try? KeychainManager.shared.get(label: VendorIdentifier.claude.rawValue)) ?? ""
            geminiKey = (try? KeychainManager.shared.get(label: VendorIdentifier.gemini.rawValue)) ?? ""
            openRouterKey = (try? KeychainManager.shared.get(label: VendorIdentifier.openrouter.rawValue)) ?? ""
            githubPat = (try? KeychainManager.shared.get(label: VendorIdentifier.githubRest.rawValue)) ?? ""
            openCodeToken = (try? KeychainManager.shared.get(label: VendorIdentifier.opencode.rawValue)) ?? ""
        }
    }

    private func saveKeys() {
        Task {
            do {
                try KeychainManager.shared.set(key: claudeKey, label: VendorIdentifier.claude.rawValue)
                try KeychainManager.shared.set(key: geminiKey, label: VendorIdentifier.gemini.rawValue)
                try KeychainManager.shared.set(key: openRouterKey, label: VendorIdentifier.openrouter.rawValue)
                try KeychainManager.shared.set(key: githubPat, label: VendorIdentifier.githubRest.rawValue)
                try KeychainManager.shared.set(key: openCodeToken, label: VendorIdentifier.opencode.rawValue)
                await MainActor.run { statusMessage = "Keys saved to Keychain" }
            } catch {
                await MainActor.run { statusMessage = "Error: \(error.localizedDescription)" }
            }
        }
    }
}

// MARK: - Reusable key field

struct KeyField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @State private var showKey = false

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 140, alignment: .leading)
                .font(.caption)

            HStack {
                if showKey {
                    TextField(placeholder, text: $text)
                        .font(.system(.caption, design: .monospaced))
                } else {
                    SecureField(placeholder, text: $text)
                        .font(.system(.caption, design: .monospaced))
                }
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
    }
}
