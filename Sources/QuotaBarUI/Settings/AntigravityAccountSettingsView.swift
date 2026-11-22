import SwiftUI
import QuotaBarCore

/// Edits safe display names for Antigravity accounts the core already discovered.
struct AntigravityAccountSettingsView: View {
    @State private var accounts: [AntigravityAccount]

    private let load: (() -> [AntigravityAccount])?
    private let saveNickname: (String, String) -> Void

    init(
        accounts: [AntigravityAccount] = AntigravityAccountStore.all(),
        load: (() -> [AntigravityAccount])? = { AntigravityAccountStore.all() },
        saveNickname: @escaping (String, String) -> Void = { name, id in
            AntigravityAccountStore.setNickname(name, for: id)
        }
    ) {
        _accounts = State(initialValue: accounts)
        self.load = load
        self.saveNickname = saveNickname
    }

    var body: some View {
        Section {
            if accounts.isEmpty {
                Text("No Antigravity accounts discovered yet. Sign in to Google OAuth on this Mac, or configure your existing CLI Proxy hub with enabled Antigravity accounts. Refresh to discover them.")
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            }
            ForEach(accounts) { account in
                AntigravityAccountNicknameView(account: account) { name in
                    saveNickname(name, account.id)
                }
            }
        } header: {
            Text("Antigravity accounts")
        } footer: {
            Text("Accounts come from this Mac's Google OAuth login and your configured CLI Proxy hub. Each account shows its own published Gemini, Claude/GPT and Argon pools. Nicknames change labels only; account numbers stay the same. Clear a nickname to use its fallback name.")
                .font(.caption)
                .foregroundStyle(Theme.systemSecondaryText)
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .frugalbarProviderPreferencesDidChange)) { _ in reload() }
        .onReceive(
            NotificationCenter.default.publisher(for: .frugalbarAntigravityAccountsDidChange)
                .receive(on: RunLoop.main)
        ) { _ in reload() }
    }

    private func reload() {
        guard let load else { return }
        accounts = load()
    }
}

private struct AntigravityAccountNicknameView: View {
    let account: AntigravityAccount
    let save: (String) -> Void
    @State private var nickname = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(account.fallbackName == "Account \(account.badge)"
                ? account.fallbackName : "Account \(account.badge) · \(account.fallbackName)")
            Text(account.sourceLabel).font(.caption).foregroundStyle(Theme.systemSecondaryText)
            HStack {
                TextField("Nickname for Antigravity account \(account.badge)", text: $nickname,
                          prompt: Text(account.fallbackName))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save(nickname) }
                Button("Save nickname") { save(nickname) }
                    .accessibilityLabel("Save nickname for Antigravity account \(account.badge)")
            }
        }
        .onAppear { nickname = account.nickname ?? "" }
        .onChange(of: account.nickname) { _, value in nickname = value ?? "" }
    }
}
