import SwiftUI
import QuotaBarCore

/// Edits safe display names for accounts the core already discovered.
struct ClaudeAccountSettingsView: View {
    @State private var accounts: [ClaudeAccount]

    private let load: (() -> [ClaudeAccount])?
    private let saveNickname: (String, String) -> Void

    init(
        accounts: [ClaudeAccount] = ClaudeAccountStore.all(),
        load: (() -> [ClaudeAccount])? = { ClaudeAccountStore.all() },
        saveNickname: @escaping (String, String) -> Void = { name, id in
            ClaudeAccountStore.setNickname(name, for: id)
        }
    ) {
        _accounts = State(initialValue: accounts)
        self.load = load
        self.saveNickname = saveNickname
    }

    var body: some View {
        Section {
            if accounts.isEmpty {
                Text("No Claude accounts discovered yet. Enable CLI discovery for this Mac's Claude Code login, or configure your existing CLI Proxy hub. Refresh Claude to discover its enabled accounts.")
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            }
            ForEach(accounts) { account in
                ClaudeAccountNicknameView(account: account) { name in
                    saveNickname(name, account.id)
                }
            }
        } header: {
            Text("Claude accounts")
        } footer: {
            Text("Accounts come from CLI discovery and your configured CLI Proxy hub. Each account keeps its own usage, reset credits and model limits. Nicknames change labels only; account numbers stay the same. Clear a nickname to use its fallback name.")
                .font(.caption).foregroundStyle(Theme.systemSecondaryText)
            Text("Linked Console monthly credit is not attached to named accounts because its billing session does not identify the Claude OAuth account.")
                .font(.caption).foregroundStyle(Theme.systemSecondaryText)
        }
        .onReceive(NotificationCenter.default.publisher(for: .frugalbarProviderPreferencesDidChange)) { _ in reload() }
    }

    private func reload() {
        guard let load else { return }
        accounts = load()
    }
}

private struct ClaudeAccountNicknameView: View {
    let account: ClaudeAccount
    let save: (String) -> Void
    @State private var nickname = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Account \(account.badge) · \(account.fallbackName)")
            Text(account.sourceLabel).font(.caption).foregroundStyle(Theme.systemSecondaryText)
            HStack {
                TextField("Nickname for account \(account.badge)", text: $nickname,
                          prompt: Text(account.fallbackName))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save(nickname) }
                Button("Save nickname") { save(nickname) }
                    .accessibilityLabel("Save nickname for account \(account.badge)")
            }
        }
        .onAppear { nickname = account.nickname ?? "" }
        .onChange(of: account.nickname) { _, value in nickname = value ?? "" }
    }
}
