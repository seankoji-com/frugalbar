import SwiftUI
import QuotaBarCore

/// Tabbed preferences: credentials and general behaviour.
public struct SettingsView: View {

    private enum Tab: String {
        case keys = "API Keys", providers = "Providers", cycles = "Cycles", general = "General"
    }

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
        .init(id: .claude, label: "Claude",
              placeholder: "Claude OAuth access token",
              note: "Discovered from CLI Proxy or Claude Code login when CLI discovery is on."),
        .init(id: .openai, label: "ChatGPT",
              placeholder: "Codex ChatGPT access token",
              note: "Discovered from CLI Proxy or ~/.codex/auth.json when CLI discovery is on."),
        .init(id: .githubRest, label: "GitHub",
              placeholder: "ghp_… or gho_…",
              note: "Used for REST, GraphQL and Copilot."),
        .init(id: .openrouter, label: "OpenRouter",
              placeholder: "sk-or-v1-…",
              note: "Gauge shown only when the key has a spend cap."),
        .init(id: .deepseek, label: "DeepSeek",
              placeholder: "sk-…",
              note: "Prepaid credit balance. Discovered from DEEPSEEK_API_KEY "
                  + "or OpenCode auth.json when CLI discovery is on."),
        // OpenCode Go is not a single slot: it is one row per named workspace,
        // each with its own key, managed in the "OpenCode Go workspaces"
        // section below. The first workspace keeps the legacy `opencode`
        // Keychain label, so a key entered before workspaces existed is still
        // the one that is used and never has to be re-entered.
        .init(id: .grok, label: "Grok",
              placeholder: "Grok CLI access token",
              note: "Discovered from ~/.grok/auth.json when CLI discovery is on. "
                  + "Run `grok` to refresh an expired login."),
        .init(id: .devpass, label: "DevPass",
              placeholder: "llmgtwy_…",
              note: "LLM Gateway API key. Monthly plan-credit allowance."),
        .init(id: .commandcode, label: "Command Code",
              placeholder: "user_…",
              note: "Discovered from ~/.commandcode/auth.json when CLI discovery is on. "
                  + "Run `cmd login` to sign in."),
        .init(id: .clinepass, label: "ClinePass",
              placeholder: "Cline API key or account token",
              note: "Discovered from ~/.cline/data/settings/providers.json when CLI discovery is on. "
                  + "Run `cline auth` (or sign in in the Cline extension) to create it."),
    ]

    @State private var selectedTab: Tab = .keys
    @State private var cycles: [VendorIdentifier: SubscriptionCycle] = [:]
    @State private var entered: [VendorIdentifier: String] = [:]
    @State private var loaded: [VendorIdentifier: String] = [:]
    @State private var perKeyStatus: [VendorIdentifier: String] = [:]
    @State private var isVerifying = false
    @State private var sources: [VendorIdentifier: CredentialStore.CredentialSource] = [:]
    @State private var expanded: Set<VendorIdentifier> = []
    @State private var showGeminiClient = false
    @State private var isSigningInToGemini = false
    @State private var geminiSignInStatus: String?
    @State private var geminiClientSecret = ""
    @State private var geminiClientID = ""
    @State private var loadedGeminiClientID = ""
    /// A stored secret is never read back for display, so the field is always
    /// blank. Without an explicit "stored" signal that reads as "it did not
    /// save" — which is exactly how it was reported.
    @State private var geminiSecretIsStored = false
    // Bound to the shared suite, not `.standard`: the toggle must apply to the
    // app whatever the executable happens to be named.
    @AppStorage(CredentialStore.cliDiscoveryDefaultsKey, store: CredentialStore.preferences)
    private var cliDiscovery = false
    // Same shared suite as `cliDiscovery`, so this reads and writes the same
    // preference file whatever the executable happens to be named.
    @AppStorage(CredentialStore.notificationsEnabledDefaultsKey, store: CredentialStore.preferences)
    private var notificationsEnabled = false
    /// Read once from the shared suite; each toggle writes straight back.
    @State private var resetAlertVendors: Set<VendorIdentifier> = CredentialStore.resetAlertVendors
    @AppStorage(CredentialStore.eventTrackingEnabledDefaultsKey, store: CredentialStore.preferences)
    private var eventTracking = true
    @State private var eventNotificationKinds: Set<AIEventKind> = CredentialStore.eventNotificationKinds
    @State private var desktopWidgetMode: DesktopWidgetMode = CredentialStore.desktopWidgetMode
    /// One row per configured OpenCode Go workspace. Its own key is never read
    /// into view state; `workspaceKeys` holds a transient, initially-empty
    /// entry per instance and `workspaceHasKey` records only whether one exists.
    @State private var workspaces: [OpenCodeGoWorkspace] = []
    @State private var workspaceKeys: [String: String] = [:]
    @State private var workspaceStatus: [String: String] = [:]
    @State private var workspaceHasKey: [String: Bool] = [:]
    @State private var newWorkspaceName = ""

    public init() {}

    /// OpenRouter and DeepSeek meter money, not a window, so they never reset.
    private static let resetAlertCandidates =
        VendorIdentifier.allCases.filter { $0 != .openrouter && $0 != .deepseek }

    private func resetAlertBinding(for vendor: VendorIdentifier) -> Binding<Bool> {
        Binding(
            get: { resetAlertVendors.contains(vendor) },
            set: { isOn in
                if isOn { resetAlertVendors.insert(vendor) } else { resetAlertVendors.remove(vendor) }
                CredentialStore.resetAlertVendors = resetAlertVendors
            }
        )
    }

    /// `.usageReset` is absent: the per-vendor "Reset alerts" govern it.
    private static let eventNotificationCandidates: [AIEventKind] = AIEventKind.surfaced

    private func eventNotificationBinding(for kind: AIEventKind) -> Binding<Bool> {
        Binding(
            get: { eventNotificationKinds.contains(kind) },
            set: { isOn in
                if isOn { eventNotificationKinds.insert(kind) } else { eventNotificationKinds.remove(kind) }
                CredentialStore.eventNotificationKinds = eventNotificationKinds
            }
        )
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            keysTab
                .tabItem { Label(Tab.keys.rawValue, systemImage: "key") }
                .tag(Tab.keys)
            ProviderOrderSettings()
                .tabItem { Label(Tab.providers.rawValue, systemImage: "list.bullet") }
                .tag(Tab.providers)
            cyclesTab
                .tabItem { Label(Tab.cycles.rawValue, systemImage: "calendar") }
                .tag(Tab.cycles)
            generalTab
                .tabItem { Label(Tab.general.rawValue, systemImage: "gearshape") }
                .tag(Tab.general)
        }
        // Grown with the rest of the app's density pass: at 460x340 the keys
        // tab scrolled as soon as the notes under each field wrapped.
        .frame(width: 540, height: 520)
        .padding()
        .onAppear(perform: loadKeys)
        .onAppear(perform: loadWorkspaces)
        .onAppear { cycles = SubscriptionCycleStore.all() }
        .task { await refreshSources() }
        // Turning discovery off can strip a row back to "Not configured";
        // saving a key can flip one to "Stored in Keychain". Both have to be
        // reflected, or the status line becomes a lie the moment it matters.
        .onChange(of: cliDiscovery) { Task { await refreshSources() } }
    }

    // MARK: - Keys

    private var keysTab: some View {
        VStack(spacing: 0) {
            keysForm
            Divider()
            saveBar
        }
    }

    private var keysForm: some View {
        Form {
            Section {
                ForEach(Self.slots) { slot in
                    slotRow(slot)
                }
            } header: {
                Text("Credentials")
            } footer: {
                Text("""
                     These fill themselves in from your CLI logins. Expand a \
                     row only to override one, or when it says "Not configured".
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            openCodeWorkspaceSection

            Section("Google (Gemini)") {
                HStack {
                    Button("Connect Google account") { Task { await connectGemini() } }
                        .disabled(isSigningInToGemini)
                    if isSigningInToGemini { ProgressView().controlSize(.small) }
                }
                Text(geminiSignInStatus ?? "Reads Antigravity quota over Google OAuth. Tokens stay in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                // Folded away by default. This is the OAuth *client* identity,
                // not a credential of the user's — it is the one thing here
                // that genuinely has to be typed, and also the thing almost
                // nobody needs to touch twice.
                DisclosureGroup(isExpanded: $showGeminiClient) {
                    TextField("OAuth client ID", text: $geminiClientID)
                        .textFieldStyle(.roundedBorder)
                    SecureField(
                        "OAuth client secret",
                        text: $geminiClientSecret,
                        prompt: Text(geminiSecretIsStored
                                     ? "•••••••• stored — leave blank to keep"
                                     : "OAuth client secret")
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("""
                         The Cloud Code API is private to Google's own OAuth \
                         clients, so one you create yourself will be refused — \
                         use a pair whose project Google has allowlisted, such \
                         as the one the antigravity-usage CLI publishes in its \
                         OAUTH_CONFIG.
                         """)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } label: {
                    HStack(spacing: 6) {
                        Text("OAuth client")
                        Spacer()
                        Label(
                            geminiSecretIsStored ? "Configured" : "Needs a client",
                            systemImage: geminiSecretIsStored ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(geminiSecretIsStored ? .green : .secondary)
                    }
                }
            }

        }
        .formStyle(.grouped)
    }

    /// Pinned below the form rather than appended to it. As the last row of a
    /// scrolling `Form` this was off-screen at the default window height, so
    /// the one commit action in the window looked like it did not exist.
    private var saveBar: some View {
        HStack(spacing: 8) {
            if isVerifying { ProgressView().controlSize(.small) }
            Spacer()
            Button("Save & verify") { Task { await saveAndVerify() } }
                .keyboardShortcut(.defaultAction)
                .disabled(isVerifying || !hasChanges)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    /// One provider: what it is, where its credential is coming from, and — only
    /// when you ask for it — a field to override that.
    @ViewBuilder
    private func slotRow(_ slot: KeySlot) -> some View {
        let source = sources[slot.id] ?? .absent
        DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(slot.id) },
                set: { isOpen in
                    if isOpen { expanded.insert(slot.id) } else { expanded.remove(slot.id) }
                }
            )
        ) {
            SecureField(
                slot.label,
                text: Binding(
                    get: { entered[slot.id] ?? "" },
                    set: { entered[slot.id] = $0 }
                ),
                prompt: Text(slot.placeholder)
            )
            .textFieldStyle(.roundedBorder)

            if let note = slot.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let status = perKeyStatus[slot.id] {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.icon(for: source))
                    .foregroundStyle(Self.tint(for: source))
                Text(slot.label)
                Spacer()
                Text(Self.describe(source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - OpenCode Go workspaces

    /// One OpenCode Go subscription per row: name, enable toggle, its own key,
    /// and reorder/remove. The key is never read back into the field — it starts
    /// blank and a stored key is only ever indicated.
    private var openCodeWorkspaceSection: some View {
        Section {
            ForEach(workspaces) { workspace in
                workspaceRow(workspace)
            }
            HStack(spacing: 8) {
                TextField("New workspace name", text: $newWorkspaceName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWorkspace)
                Button("Add", action: addWorkspace)
                    .disabled(newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("OpenCode Go workspaces")
        } footer: {
            Text("""
                 Each workspace is a separate OpenCode Go subscription with its \
                 own API key, monitored and shown as its own reading. The first \
                 workspace keeps your existing OpenCode key and the CLI \
                 auth.json fallback; later ones are read from their own Keychain \
                 entry only. A key is written to the Keychain and never shown again.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: OpenCodeGoWorkspace) -> some View {
        let instanceID = workspace.instanceID
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: enabledBinding(for: workspace.id))
                    .labelsHidden()
                    .accessibilityLabel("Monitor \(workspace.name)")

                // Renames persist on Return; the whole list is written, so a
                // rename and a toggle cannot fight over which one is current.
                TextField("Name", text: nameBinding(for: workspace.id))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(persistWorkspaces)

                Text(workspaceHasKey[instanceID] == true ? "Stored in Keychain" : "Not configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button { moveWorkspace(workspace.id, by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(workspaces.first?.id == workspace.id)
                .accessibilityLabel("Move \(workspace.name) up")

                Button { moveWorkspace(workspace.id, by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(workspaces.last?.id == workspace.id)
                .accessibilityLabel("Move \(workspace.name) down")

                Button(role: .destructive) { removeWorkspace(workspace.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(workspace.name)")
            }

            HStack(spacing: 8) {
                SecureField(
                    "API key",
                    text: keyBinding(for: instanceID),
                    prompt: Text(workspaceHasKey[instanceID] == true
                                 ? "•••••••• stored — type to replace"
                                 : "oc_live_…")
                )
                .textFieldStyle(.roundedBorder)

                Button("Save") { Task { await saveWorkspaceKey(workspace) } }
                    .disabled((workspaceKeys[instanceID] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let status = workspaceStatus[instanceID] {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func enabledBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { workspaces.first { $0.id == id }?.isEnabled ?? false },
            set: { isOn in
                guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
                workspaces[index].isEnabled = isOn
                persistWorkspaces()
            }
        )
    }

    private func nameBinding(for id: String) -> Binding<String> {
        Binding(
            get: { workspaces.first { $0.id == id }?.name ?? "" },
            set: { name in
                guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
                workspaces[index].name = name
            }
        )
    }

    private func keyBinding(for instanceID: String) -> Binding<String> {
        Binding(
            get: { workspaceKeys[instanceID] ?? "" },
            set: { workspaceKeys[instanceID] = $0 }
        )
    }

    private func loadWorkspaces() {
        workspaces = OpenCodeGoWorkspaceStore.resolved()
        workspaceKeys = [:]
        workspaceStatus = [:]
        refreshWorkspaceHasKey()
    }

    /// Writes the list and refreshes each row's stored/not-stored indicator.
    ///
    /// Names are normalised by `OpenCodeGoWorkspaceStore.set` — a blanked
    /// field falls back to the name last committed for that workspace, so an
    /// accidental select-all-delete leaves it named — and the list is written
    /// back so the field shows the name that was actually stored rather than
    /// the blank the user typed.
    private func persistWorkspaces() {
        OpenCodeGoWorkspaceStore.set(workspaces)
        refreshWorkspaceHasKey()
        workspaces = OpenCodeGoWorkspaceStore.all()
    }

    private func refreshWorkspaceHasKey() {
        var has: [String: Bool] = [:]
        for workspace in workspaces {
            has[workspace.instanceID] = OpenCodeGoWorkspaceStore.hasCredential(for: workspace)
        }
        workspaceHasKey = has
    }

    private func addWorkspace() {
        let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        workspaces.append(OpenCodeGoWorkspace(name: name))
        newWorkspaceName = ""
        persistWorkspaces()
    }

    private func removeWorkspace(_ id: String) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let instanceID = workspace.instanceID
        // A removed workspace must not leave its key behind in the Keychain.
        // If it cannot be deleted, keep the row: dropping it here would orphan
        // the secret with no way left to retry from the UI, and it would hide
        // the failure a moment after it happened.
        do {
            try OpenCodeGoWorkspaceStore.deleteCredential(for: workspace)
        } catch {
            workspaceStatus[instanceID] = "Could not remove: its key could not be deleted from the Keychain"
            return
        }
        workspaces.removeAll { $0.id == id }
        workspaceKeys[instanceID] = nil
        workspaceHasKey[instanceID] = nil
        workspaceStatus[instanceID] = nil
        persistWorkspaces()
    }

    private func moveWorkspace(_ id: String, by offset: Int) {
        workspaces = OpenCodeGoWorkspaceStore.moved(workspaces, id: id, by: offset)
        persistWorkspaces()
    }

    /// Stores one workspace's key and exercises it, so a truncated paste fails
    /// here rather than as an unexplained blank row later.
    private func saveWorkspaceKey(_ workspace: OpenCodeGoWorkspace) async {
        let instanceID = workspace.instanceID
        let key = (workspaceKeys[instanceID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isVerifying = true
        defer { isVerifying = false }
        do {
            try OpenCodeGoWorkspaceStore.setCredential(key, for: workspace)
            workspaceKeys[instanceID] = ""
            workspaceHasKey[instanceID] = true
            workspaceStatus[instanceID] = await verify(.opencode, key: key)
        } catch {
            workspaceStatus[instanceID] = Self.keychainAdvice(for: error)
        }
    }

    static func describe(_ source: CredentialStore.CredentialSource) -> String {
        switch source {
        case .keychain:            "Stored in Keychain"
        case .discovered(let where_): "From \(where_)"
        case .absent:              "Not configured"
        }
    }

    private static func icon(for source: CredentialStore.CredentialSource) -> String {
        switch source {
        case .keychain:   "key.fill"
        case .discovered: "sparkles"
        case .absent:     "circle.dashed"
        }
    }

    private static func tint(for source: CredentialStore.CredentialSource) -> Color {
        switch source {
        case .keychain:   .green
        case .discovered: .blue
        case .absent:     .secondary
        }
    }

    private func refreshSources() async {
        var found: [VendorIdentifier: CredentialStore.CredentialSource] = [:]
        for slot in Self.slots {
            found[slot.id] = await CredentialStore.credentialSourceAsync(for: slot.id)
        }
        sources = found
    }

    /// The Gemini client fields count too. They did not, so typing a client ID
    /// left "Save & verify" greyed out and the only way to persist it was the
    /// Connect button — which is not where anyone looks for "save".
    private var hasChanges: Bool {
        if Self.slots.contains(where: { (entered[$0.id] ?? "") != (loaded[$0.id] ?? "") }) { return true }
        if geminiClientID != loadedGeminiClientID { return true }
        // A workspace key typed but not yet saved.
        if workspaceKeys.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }
        // A workspace renamed in the field but not yet committed with Return.
        let stored = OpenCodeGoWorkspaceStore.all()
        if workspaces.contains(where: { workspace in
            stored.first { $0.id == workspace.id }?.name != workspace.name
        }) { return true }
        // Blank means "keep the stored secret", so only a typed one is a change.
        return !geminiClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - General

    // MARK: - Cycles

    /// Renewal dates the user records for vendors that publish none.
    ///
    /// FrugalBar never fakes a quota, and this does not: a cycle row reports
    /// elapsed time against a period the user stated, never consumption. It is
    /// drawn as a separate `CYCLE` bar so a vendor's own window is never
    /// confused with one typed in here.
    private var cyclesTab: some View {
        Form {
            Section {
                ForEach(Self.cycleVendors, id: \.self) { vendor in
                    CycleEditorRow(
                        vendor: vendor,
                        cycle: Binding(
                            get: { cycles[vendor] },
                            set: { cycles[vendor] = $0 }
                        ),
                        onCommit: { SubscriptionCycleStore.set(cycles[vendor], for: vendor) }
                    )
                }
            } header: {
                Text("Subscription cycles")
            } footer: {
                Text("""
                     For subscriptions whose vendor publishes no billing period. \
                     A cycle adds a CYCLE bar showing how many days of the period \
                     you have paid for remain — it reports no usage, only elapsed \
                     time against the date you entered. A vendor-published window \
                     always wins where one exists.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }

    /// Vendors worth offering a cycle for: every one FrugalBar tracks, since a
    /// renewal date is just as useful for a vendor it cannot read at all.
    private static let cycleVendors: [VendorIdentifier] = [
        .claude, .openai, .gemini, .copilot, .opencode, .openrouter,
        .deepseek, .grok, .kiro,
    ]

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Read credentials from local CLI tools", isOn: $cliDiscovery)
                Text("""
                     When on, FrugalBar may run `gh auth token`; read \
                     CLI Proxy hubs (~/.t3/userdata/settings.json); read \
                     ~/.local/share/opencode/auth.json, ~/.codex/auth.json, \
                     ~/.claude/.credentials.json, \
                     ~/.config/github-copilot/hosts.json, \
                     ~/.commandcode/auth.json, or \
                     ~/.cline/data/settings/providers.json; read the \
                     OPENROUTER_API_KEY environment variable; or read the \
                     Claude Code login Keychain item — if the Keychain has no \
                     entry for a provider. Off by default: this reads \
                     credentials you have not explicitly given the app.
                     """)

                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Credential discovery")
            }

            Section {
                Toggle("Notify when a quota recovers", isOn: $notificationsEnabled)
                Text("""
                     When on, FrugalBar posts a local notification once a \
                     provider goes from critical/exhausted back to having \
                     headroom. Off by default.
                     """)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("""
                     Delivered via a `display notification` AppleScript call, \
                     so macOS attributes the banner to whatever process runs \
                     it, not to "FrugalBar" specifically.
                     """)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Quota-recovery notifications")
            }

            Section {
                ForEach(Self.resetAlertCandidates, id: \.self) { vendor in
                    Toggle(vendor.displayName, isOn: resetAlertBinding(for: vendor))
                }
                Text("""
                     Posts a notification when a provider's quota window \
                     rolls over, judged from the reset time the provider \
                     itself reports. Off for every provider by default.
                     """)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Reset alerts")
            }

            Section {
                Toggle("Track resets, outages and new models",
                       isOn: $eventTracking)
                Text("""
                     Reads the official status pages for Claude, OpenAI and \
                     GitHub every 10 minutes, the community reset trackers \
                     claude-resets.com and whenreset.dev hourly, and each \
                     subscription's own model list hourly with the credential \
                     it already uses. Only past events are recorded, never \
                     forecasts.
                     """)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Notify about")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Self.eventNotificationCandidates) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(kind.title, isOn: eventNotificationBinding(for: kind))
                        Text(kind.notificationCaption)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("AI events")
            }

            Section {
                Picker("Position", selection: $desktopWidgetMode) {
                    Text("Pinned to desktop").tag(DesktopWidgetMode.desktop)
                    Text("Floats above windows").tag(DesktopWidgetMode.floating)
                }
                .onChange(of: desktopWidgetMode) {
                    CredentialStore.desktopWidgetMode = desktopWidgetMode
                    DesktopWidgetWindow.applyMode()
                }
                Text("""
                     A small panel charting every subscription's usage \
                     window over time, with an average of the selected \
                     windows' readings and their current headroom. Open it \
                     from the gear menu. It is a window FrugalBar owns, not a \
                     WidgetKit widget — those need an app bundle this build \
                     does not have.
                     """)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Desktop widget")
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
        geminiSecretIsStored = GeminiOAuthLogin.hasClientSecretOverride()

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

        // Commit any workspace rename the user typed but did not press Return on.
        persistWorkspaces()

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
                geminiSecretIsStored = GeminiOAuthLogin.hasClientSecretOverride()
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

        await refreshSources()
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
        case .deepseek:    provider = DeepSeekProvider(apiKey: key)
        // Gemini has no key slot — it is connected through the OAuth button
        // above — but the switch must stay exhaustive.
        case .gemini:      provider = GeminiQuotaProvider(accessToken: key)
        case .opencode:    provider = OpenCodeGoProvider(apiKey: key)
        case .copilot:     provider = GitHubCopilotProvider(token: key)
        case .grok:        provider = GrokQuotaProvider(accessToken: key)
        // Kiro has no key slot — its token and profile ARN are read together
        // from the CLI state database — but the switch must stay exhaustive.
        case .kiro:        provider = KiroQuotaProvider()
        case .devpass:     provider = DevPassQuotaProvider(apiKey: key)
        case .commandcode: provider = CommandCodeQuotaProvider(apiKey: key)
        case .clinepass:   provider = ClinePassQuotaProvider(apiKey: key)
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
        case .unsupported(let detail): return "Saved — \(detail)"
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
