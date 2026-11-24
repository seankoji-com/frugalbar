import AppKit
import SwiftUI
import QuotaBarCore

/// Settings for individual services and for FrugalBar as a whole.
public struct SettingsView: View {

    public enum Pane: CaseIterable, Identifiable, Sendable, Hashable {
        case services, service(VendorIdentifier), connections, display, notifications, sync, data, guide, about

        public var id: Self { self }

        private static let appPanes: [Pane] = [
            .services, .connections, .display, .notifications, .sync, .data, .guide, .about,
        ]

        public static var allCases: [Pane] {
            appPanes + ProviderOrderEditing.services(in: ProviderDisplayPreferences.defaultOrder).map(Self.service)
        }

        static func appPanes(syncAvailable: Bool) -> [Pane] {
            appPanes.filter { $0 != .sync || syncAvailable }
        }

        /// The panes the sidebar lists. Phone & Watch only exists in a build
        /// with a sync client: without one there is nothing to turn on.
        public static func visible(syncAvailable: Bool) -> [Pane] {
            allCases.filter { $0 != .sync || syncAvailable }
        }

        public var title: String {
            switch self {
            case .services: "Services"
            case .service(let vendor): GlancePresentation.serviceName(for: vendor)
            case .connections: "Connections"
            case .display: "Display"
            case .notifications: "Notifications"
            case .sync: "Phone & Watch"
            case .data: "History & Data"
            case .guide: "How to read"
            case .about: "About"
            }
        }

        public var symbol: String {
            switch self {
            case .services: "list.bullet"
            case .service(let vendor): vendor.iconSymbol
            case .connections: "key"
            case .display: "paintbrush"
            case .notifications: "bell.badge"
            case .sync: "arrow.triangle.2.circlepath"
            case .data: "cylinder.split.1x2"
            case .guide: "questionmark.circle"
            case .about: "info.circle"
            }
        }
    }

    /// Manual credential overrides, including OAuth tokens for Claude and Codex.
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
        // section below. The original workspace keeps the legacy `opencode`
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
        .init(id: .muse, label: "Muse",
              placeholder: "Muse OAuth access token",
              note: "Discovered from the Muse CLI login in the macOS Keychain when CLI discovery is on. "
                  + "Paste the OAuth access token — the minted api_key is rejected. "
                  + "Run `muse login` if the row stops reading."),
    ]

    @State private var selection: Pane?
    @State private var providerOrder = CredentialStore.providerOrder
    @State private var hiddenProviders = CredentialStore.hiddenProviders
    /// The running app's store, for live connection states. nil in the
    /// standalone Settings scene.
    private let store: QuotaStore?
    /// Sync to phone & watch; nil when this build has no sync client.
    private let sync: SyncController?
    @State private var cycles: [VendorIdentifier: SubscriptionCycle] = [:]
    @State private var entered: [VendorIdentifier: String] = [:]
    @State private var loaded: [VendorIdentifier: String] = [:]
    @State private var perKeyStatus: [VendorIdentifier: String] = [:]
    @State private var verifyingVendor: VendorIdentifier?
    @State private var busyWorkspaceIDs: Set<String> = []
    @State private var sources: [VendorIdentifier: CredentialStore.CredentialSource] = [:]
    @State private var expanded: Set<VendorIdentifier> = []
    @State private var showClaudeMonthlyCredit = false
    @State private var claudeCreditRows: [ClaudeMonthlyCreditBinding.Row] = []
    @State private var openDesignEnabled = false
    @State private var showOpenDesign = false

    /// Which Claude row the linked monthly credit is drawn under, or why it is
    /// drawn under none. Nil when Claude has no named account rows: the single
    /// unnamed row is then the only place it can go.
    ///
    /// "Shown under" is read from the snapshots the popover is displaying, not
    /// from the billing session, so the sentence can never name a row the
    /// popover does not show the credit under (a cached poll can lag a new
    /// sign-in by up to a refresh).
    nonisolated static func claudeCreditPlacement(snapshots: [QuotaSnapshot], webIdentities: Set<String>?,
                                                  rows: [ClaudeMonthlyCreditBinding.Row]) -> String? {
        guard !rows.isEmpty else { return nil }
        if let shown = snapshots.first(where: { $0.vendorId == .claude && $0.monthlyAPICredit != nil }),
           let account = shown.claudeAccount {
            return "Shown under \(account.name)."
        }
        let binding = ClaudeMonthlyCreditBinding.resolve(webIdentities: webIdentities, rows: rows)
        if case .bound(let id) = binding {
            let name = ClaudeAccountStore.displayName(forInstanceKey: id) ?? "the matching Claude account"
            return "Matched to \(name); the line appears there after the next refresh."
        }
        return binding.explanation { ClaudeAccountStore.displayName(forInstanceKey: $0) }
    }
    @State private var claudeMonthlyEnabled = false
    @State private var showOpenAIMonthlyCredit = false
    @State private var openAIMonthlyEnabled = false
    @State private var showMusePortal = false
    @ObservedObject private var musePortal = MusePortalSession.shared
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
    /// Read from the system when the Notifications pane appears; nil when this
    /// process has no notification identity to ask about.
    @State private var notificationPermission: LocalNotificationPermission?
    @State private var desktopWidgetMode: DesktopWidgetMode = CredentialStore.desktopWidgetMode
    /// One row per configured OpenCode Go workspace. Its own key is never read
    /// into view state; `workspaceKeys` holds a transient, initially-empty
    /// entry per instance and `workspaceHasKey` records only whether one exists.
    @State private var workspaces: [OpenCodeGoWorkspace] = []
    @State private var workspaceKeys: [String: String] = [:]
    @State private var workspaceStatus: [String: String] = [:]
    @State private var workspaceHasKey: [String: Bool] = [:]
    @State private var newWorkspaceName = ""

    /// False only in the test render harness: the panes are drawn without
    /// reading a single Keychain item, so a render can never touch the
    /// user's real credentials.
    private let readsCredentials: Bool
    @State private var vaultStatus: VaultStatusSnapshot = VaultStatusSnapshot(state: .unloaded)
    @State private var isUnlockingVault = false

    public init(store: QuotaStore? = nil, sync: SyncController? = nil, initialPane: Pane = .services) {
        self.init(store: store, sync: sync, initialPane: initialPane, readsCredentials: true)
    }

    init(store: QuotaStore?, sync: SyncController? = nil, initialPane: Pane, readsCredentials: Bool) {
        self.store = store
        self.sync = sync
        self.readsCredentials = readsCredentials
        _selection = State(initialValue: initialPane)
    }

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
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Pane.appPanes(syncAvailable: sync != nil)) { pane in
                    Label {
                        Text(pane.title)
                    } icon: {
                        Image(systemName: pane.symbol)
                            .foregroundStyle(.secondary)
                    }
                    .tag(pane)
                }
                Section("Service setup") {
                    ForEach(ProviderOrderEditing.services(in: providerOrder), id: \.self) { vendor in
                        HStack(spacing: 7) {
                            VendorAvatarView(vendorId: vendor, status: .healthy, size: 17)
                                .accessibilityHidden(true)
                            Text(Pane.service(vendor).title)
                            Spacer(minLength: 0)
                            if hasChanges(for: vendor) {
                                Image(systemName: "pencil.circle")
                                    .font(.caption)
                                    .help("Unsaved credential changes")
                                    .accessibilityLabel("Unsaved credential changes")
                            }
                            if ProviderOrderEditing.members(of: vendor, in: providerOrder)
                                .allSatisfy(hiddenProviders.contains) {
                                Image(systemName: "eye.slash")
                                    .font(.caption)
                                    .accessibilityLabel("Hidden")
                            }
                        }
                        .tag(Pane.service(vendor))
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            .accessibilityLabel("Settings sections")

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                paneHeader(selection ?? .services)
                if readsCredentials, showsVaultBanner, let banner = SettingsVaultBannerPresentation.make(from: vaultStatus) {
                    SettingsVaultBannerView(
                        presentation: banner,
                        isBusy: isUnlockingVault,
                        onAction: { Task { await unlockVault() } }
                    )
                }
                pane(selection ?? .services)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 780, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if readsCredentials { loadKeysFromCache() } }
        .onAppear(perform: loadWorkspaces)
        .onAppear { cycles = SubscriptionCycleStore.all() }
        .task {
            if readsCredentials {
                await loadVaultAsyncAndRefreshSources()
            }
        }
        // Turning discovery off can strip a row back to "Not configured";
        // saving a key can flip one to "Stored in Keychain". Both have to be
        // reflected, or the status line becomes a lie the moment it matters.
        .onChange(of: cliDiscovery) {
            if readsCredentials { Task { await refreshSources() } }
        }
        // A rename typed into the workspace list but never committed with
        // Return is kept when the user moves to another section.
        .onChange(of: selection) { old, _ in
            if old == .service(.opencode) { commitWorkspaceRenames() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .frugalbarProviderPreferencesDidChange, object: CredentialStore.preferencesChangeSender
        )) { _ in
            providerOrder = CredentialStore.providerOrder
            hiddenProviders = CredentialStore.hiddenProviders
        }
        .onReceive(NotificationCenter.default.publisher(for: KeychainVault.statusDidChangeNotification)) { _ in
            guard readsCredentials else { return }
            let previous = vaultStatus
            let current = KeychainVault.shared.statusSnapshot()
            vaultStatus = current
            // A vault unlocked elsewhere (e.g. a popover refresh) must also
            // reload the fields, sources and key indicators, or the banner
            // clears while the controls still show the locked vault. The
            // merge keeps any edits the user has typed.
            if SettingsVaultReload.shouldReloadCredentials(previous: previous, current: current) {
                loadKeysFromCache()
                refreshWorkspaceHasKey()
                Task { await refreshSources() }
            }
        }
    }

    private func paneHeader(_ pane: Pane) -> some View {
        HStack(spacing: 9) {
            if case .service(let vendor) = pane {
                VendorAvatarView(vendorId: vendor, status: .healthy, size: 24)
                    .accessibilityHidden(true)
            }
            Text(pane.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func pane(_ pane: Pane) -> some View {
        switch pane {
        case .services:
            ProviderOrderSettings(
                store: store, order: $providerOrder, hidden: hiddenProviders,
                onManage: { selection = .service($0) }
            )
        case .service(let vendor):
            servicePane(vendor)
        case .connections:
            Form { credentialDiscoverySection }
                .formStyle(.grouped)
        case .display:
            displayPane
        case .notifications:
            notificationsPane
        case .guide:
            readingGuide
        case .sync:
            if let sync { SyncSettingsPane(controller: sync) }
        case .data:
            dataPane
        case .about:
            // The dark identity card sits inset under the pane header with the
            // same rounded, outlined container the grouped forms use, rather
            // than as a bare black rectangle floating in the light pane.
            ScrollView {
                AboutView()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Service setup

    private var showsVaultBanner: Bool {
        switch selection ?? .services {
        case .services, .connections, .service, .sync: true
        default: false
        }
    }

    private func servicePane(_ vendor: VendorIdentifier) -> some View {
        let slot = Self.slots.first { $0.id == vendor }
        let members = ProviderOrderEditing.members(of: vendor, in: providerOrder)
        return VStack(spacing: 0) {
            Form {
                monitoringSection(vendor, members: members)
                if let slot {
                    Section("Credential") { slotRow(slot) }
                }
                serviceConnections(vendor)
                if Self.cycleVendors.contains(vendor) {
                    cycleSection(vendor)
                }
                let alertVendors = members.filter(Self.resetAlertCandidates.contains)
                if !alertVendors.isEmpty {
                    Section("Reset alerts") {
                        ForEach(alertVendors, id: \.self) { member in
                            Toggle(alertVendors.count == 1 ? "Notify when quota resets" : member.displayName,
                                   isOn: resetAlertBinding(for: member))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .id(vendor)

            if hasChanges(for: vendor) || verifyingVendor == vendor {
                Divider()
                saveBar(for: vendor)
            }
        }
        .onAppear {
            guard readsCredentials else { return }
            claudeMonthlyEnabled = ClaudeMonthlyCreditSession.shared.isEnabled
            openAIMonthlyEnabled = OpenAIMonthlyCreditSession.shared.isEnabled
            openDesignEnabled = OpenDesignWebSession.shared.isEnabled
            claudeCreditRows = ClaudeMonthlyCreditBinding.storedRows()
        }
        .sheet(isPresented: $showClaudeMonthlyCredit, onDismiss: {
            Task {
                _ = await ClaudeMonthlyCreditSession.shared.read(now: Date())
                claudeCreditRows = ClaudeMonthlyCreditBinding.storedRows()
                await store?.load()
            }
        }) { ClaudeMonthlyCreditConnectionView() }
        .sheet(isPresented: $showOpenDesign, onDismiss: {
            Task { await store?.forceRefresh() }
        }) { OpenDesignConnectionView() }
        .sheet(isPresented: $showOpenAIMonthlyCredit, onDismiss: {
            Task { await store?.forceRefresh() }
        }) { OpenAIMonthlyCreditConnectionView() }
        .sheet(isPresented: $showMusePortal, onDismiss: {
            Task { await store?.forceRefresh() }
        }) { MusePortalConnectionView() }
    }

    @ViewBuilder
    private func serviceConnections(_ vendor: VendorIdentifier) -> some View {
        switch vendor {
        case .claude:
            ClaudeAccountSettingsView()
            claudeCreditSection
        case .openai:
            OpenAIAccountSettingsView(
                accountKey: store?.snapshots.first(where: { $0.vendorId == .openai })?.openAIAccountKey
            ) {
                Task { await store?.forceRefresh() }
            }
            openAICreditSection
        case .gemini:
            AntigravityAccountSettingsView()
            googleConnectionSection
            Section("API billing") {
                // One credit per Google account: each AI Studio key bills to
                // its own Cloud Billing account (owner, 24 Nov 2026).
                let accounts = AntigravityAccountStore.all()
                if accounts.isEmpty {
                    GeminiAPICreditSettingsView {
                        Task { await store?.reloadConfiguredCredit() }
                    }
                } else {
                    ForEach(accounts) { account in
                        GeminiAPICreditSettingsView(account: account) {
                            Task { await store?.reloadConfiguredCredit() }
                        }
                    }
                }
            }
        case .opencode:
            openCodeWorkspaceSection
        case .muse:
            musePortalSection
        case .opendesign:
            openDesignSection
        case .kiro:
            Section("Connection") {
                Text("Sign in to the Kiro CLI or IDE on this Mac, then turn on CLI discovery.")
                Button("Open Connections") { selection = .connections }
            }
        case .copilot:
            Section("Connection") {
                Text("Copilot can use the token saved in GitHub settings or a local CLI login.")
                Button("Open GitHub settings") { selection = .service(.githubRest) }
            }
        default:
            EmptyView()
        }
    }

    private func monitoringSection(_ service: VendorIdentifier, members: [VendorIdentifier]) -> some View {
        Section {
            ForEach(Array(members.enumerated()), id: \.element) { index, vendor in
                let title = members.count == 1 ? Pane.service(service).title : vendor.displayName
                let status = ProviderConnectionPresentation.status(
                    vendorSnapshots: store?.snapshots.filter { $0.vendorId == vendor } ?? [],
                    isHidden: hiddenProviders.contains(vendor), hasPolled: store?.hasLoaded ?? false,
                    credentialSource: sources[vendor], now: Date())
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(members.count == 1 ? "Show in FrugalBar" : title)
                        ConnectionStatusLine(status: status)
                    }
                    Spacer(minLength: 8)
                    if service == .gemini {
                        ServiceOrderButtons(
                            title: title, canMoveUp: index > 0, canMoveDown: index < members.count - 1
                        ) { offset in
                            providerOrder = ProviderOrderEditing.moveMember(vendor, by: offset, in: providerOrder)
                            CredentialStore.providerOrder = providerOrder
                        }
                    }
                    Toggle("Monitor \(title)", isOn: Binding(
                        get: { !hiddenProviders.contains(vendor) },
                        set: { shown in
                            hiddenProviders = ProviderOrderEditing.setShown(shown, vendor, hidden: hiddenProviders)
                            CredentialStore.hiddenProviders = hiddenProviders
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        } header: {
            Text("Monitoring")
        } footer: {
            Text("Turning off monitoring stops polling and keeps your credentials.")
                .font(.caption)
                .foregroundStyle(Theme.systemSecondaryText)
        }
    }

    private var musePortalSection: some View {
        Section("Muse portal quota") {
            Text("If the CLI response omits usage, connect Meta and select your subscription team. This app retains its own sign-in and team across restarts until you disconnect. Its account and plan must match Muse CLI. Your browser's cookies are never imported.")
                .font(.caption)
            Button(musePortal.isEnabled ? "Open Muse portal connection" : "Connect Muse portal quota") {
                musePortal.connect()
                showMusePortal = true
            }.disabled(musePortal.isDisconnecting)
            if musePortal.isEnabled {
                Button("Disconnect Muse portal") {
                    Task {
                        await musePortal.disconnect()
                        await store?.load()
                    }
                }
            }
            if musePortal.isDisconnecting {
                Text("Clearing this app's Meta sign-in…").font(.caption)
            }
        }
    }

    private var openDesignSection: some View {
        Section("OpenDesign Go usage") {
            Text("Sign in to OpenDesign to read your current workspace's 5-hour and weekly coding-plan usage, and its monthly window when OpenDesign publishes one. An OpenDesign API key cannot read usage, so there is no key slot.")
                .font(.caption)
            Button(openDesignEnabled ? "Open OpenDesign sign-in" : "Connect OpenDesign") {
                OpenDesignWebSession.shared.connect()
                openDesignEnabled = true
                showOpenDesign = true
            }
            if openDesignEnabled {
                Button("Disconnect OpenDesign") {
                    OpenDesignWebSession.shared.disconnect()
                    openDesignEnabled = false
                    Task { await store?.forgetReadings(of: .opendesign) }
                }
            }
        }
    }

    private var claudeCreditSection: some View {
        Section("Claude monthly API credit") {
            Text("Connect Claude's billing page to read the linked Console monthly allowance and next credit date. This is separate from extra usage and is never shown as a remaining balance.")
                .font(.caption)
            Button(claudeMonthlyEnabled ? "Open Claude billing connection" : "Connect Claude billing") {
                ClaudeMonthlyCreditSession.shared.connect()
                claudeMonthlyEnabled = true
                showClaudeMonthlyCredit = true
            }
            if claudeMonthlyEnabled, let placement = Self.claudeCreditPlacement(
                snapshots: store?.snapshots ?? [],
                webIdentities: ClaudeMonthlyCreditSession.shared.webIdentities,
                rows: claudeCreditRows) {
                Label(placement, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if claudeMonthlyEnabled {
                Button("Disconnect monthly credit") {
                    ClaudeMonthlyCreditSession.shared.disconnect()
                    claudeMonthlyEnabled = false
                    Task { await store?.clearMonthlyCredit() }
                }
            }
        }
    }

    private var openAICreditSection: some View {
        Section("OpenAI monthly API credit") {
            Text("Connect the OpenAI Platform billing page to read the linked organization's monthly API credit. This is the Pro/Business API-credits benefit, not the ChatGPT usage credit count, and it is never shown as a quota.")
                .font(.caption)
            Button(openAIMonthlyEnabled ? "Open OpenAI billing connection" : "Connect OpenAI billing") {
                OpenAIMonthlyCreditSession.shared.connect()
                openAIMonthlyEnabled = true
                showOpenAIMonthlyCredit = true
            }
            if openAIMonthlyEnabled {
                Button("Disconnect OpenAI monthly credit") {
                    OpenAIMonthlyCreditSession.shared.disconnect()
                    openAIMonthlyEnabled = false
                    Task { await store?.clearOpenAIMonthlyCredit() }
                }
            }
        }
    }

    private var googleConnectionSection: some View {
        Section("Google sign-in") {
            HStack {
                Button("Connect Google account") { Task { await connectGemini() } }
                    .disabled(isSigningInToGemini || verifyingVendor != nil)
                if isSigningInToGemini { ProgressView().controlSize(.small) }
            }
            Text(geminiSignInStatus ?? "Reads Antigravity quota over Google OAuth. Tokens stay in your Keychain.")
                .font(.caption)
                .foregroundStyle(Theme.systemSecondaryText)

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
                    .foregroundStyle(Theme.systemSecondaryText)
            } label: {
                HStack(spacing: 6) {
                    Text("OAuth client")
                    Spacer()
                    // The symbol carries the tone; the words stay in a text
                    // colour. System green text on the light form measured
                    // 1.8:1 (design-loop sol-15).
                    HStack(spacing: 4) {
                        Image(systemName: geminiSecretIsStored ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(geminiSecretIsStored ? Color.green : Theme.systemSecondaryText)
                        Text(geminiSecretIsStored ? "Configured" : "Needs a client")
                            .foregroundStyle(Theme.systemSecondaryText)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Pinned below the form rather than appended to it. As the last row of a
    /// scrolling `Form` this was off-screen at the default window height, so
    /// the one commit action in the window looked like it did not exist.
    private func saveBar(for vendor: VendorIdentifier) -> some View {
        HStack(spacing: 8) {
            if verifyingVendor == vendor { ProgressView().controlSize(.small) }
            Spacer()
            Button("Save & verify") { Task { await saveAndVerify(vendor) } }
                .keyboardShortcut(.defaultAction)
                .disabled(verifyingVendor != nil || isSigningInToGemini)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    /// One provider: what it is, where its credential is coming from, and — only
    /// when you ask for it — a field to override that.
    @ViewBuilder
    private func slotRow(_ slot: KeySlot) -> some View {
        let source = sources[slot.id]
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
                    .foregroundStyle(Theme.systemSecondaryText)
            }
            if let status = perKeyStatus[slot.id] {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            }
        } label: {
            HStack(spacing: 8) {
                if let source {
                    Image(systemName: Self.icon(for: source))
                        .foregroundStyle(Self.tint(for: source))
                        .accessibilityHidden(true)
                }
                Text(slot.label)
                Spacer()
                if let source {
                    Text(Self.describe(source))
                        .font(.caption)
                        .foregroundStyle(Theme.systemSecondaryText)
                }
            }
            .accessibilityElement(children: .combine)
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
            // Drag a row to reorder, as well as the arrows on each row.
            .onMove { source, destination in
                workspaces = OpenCodeGoWorkspaceStore.moved(workspaces, fromOffsets: source, toOffset: destination)
                persistWorkspaces()
            }
            HStack(spacing: 8) {
                TextField("New workspace name", text: $newWorkspaceName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWorkspace)
                Button("Add", action: addWorkspace)
                    .disabled(newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Workspaces")
        } footer: {
            Text("""
                 Each workspace is a separate OpenCode Go subscription with its \
                 own API key, monitored and shown as its own reading. Drag a row \
                 or use its arrows to set the order the popover, History and the \
                 desktop widget list them in; renaming or reordering never moves \
                 a key or its history. The original workspace, marked below \
                 its key field, keeps your existing OpenCode key and the CLI \
                 auth.json fallback wherever it sits in the list; every other \
                 workspace is read from its own Keychain entry only. A key is \
                 written to the Keychain and never shown again.
                 """)
                .font(.caption)
                .foregroundStyle(Theme.systemSecondaryText)
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

                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Theme.systemSecondaryText)
                    .help("Drag to reorder")
                    .accessibilityHidden(true)

                // Only where the Keychain itself says so. "Not configured" here
                // contradicted a workspace that reads fine from the CLI login.
                if let hasKey = workspaceHasKey[instanceID] {
                    Text(hasKey ? "Stored in Keychain" : "No key in Keychain")
                        .font(.caption)
                        .foregroundStyle(Theme.systemSecondaryText)
                }

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

                Button(role: .destructive) { Task { await removeWorkspace(workspace.id) } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(busyWorkspaceIDs.contains(workspace.id))
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
                    .disabled(busyWorkspaceIDs.contains(workspace.id)
                        || (workspaceKeys[instanceID] ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Credential ownership follows the workspace, not its position:
            // this one inherited the pre-workspace key wherever it is moved.
            if workspace.id == OpenCodeGoWorkspaceStore.legacyID {
                Label("Original workspace: uses your existing OpenCode key and the CLI login",
                      systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            }

            if let status = workspaceStatus[instanceID] {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            } else if let live = liveWorkspaceStatus(workspace) {
                ConnectionStatusLine(status: live)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Workspace \(workspace.name), position \((workspaces.firstIndex { $0.id == workspace.id } ?? 0) + 1) of \(workspaces.count)")
    }

    private func liveWorkspaceStatus(_ workspace: OpenCodeGoWorkspace) -> ProviderConnectionPresentation.Status? {
        guard workspace.isEnabled, let store, store.hasLoaded,
              let snapshot = store.snapshots.first(where: { $0.id == workspace.instanceID })
        else { return nil }
        return ProviderConnectionPresentation.status(for: snapshot, now: Date())
    }

    /// Writes a name typed but not committed with Return, and nothing else.
    ///
    /// The names are applied to the stored list rather than writing this
    /// view's copy: the Providers section may have reordered the workspaces
    /// since this copy was read, and writing it back would undo that. Nothing
    /// is written when no name changed, so leaving the section does not post
    /// a change (and a refresh) for nothing.
    private func commitWorkspaceRenames() {
        let stored = OpenCodeGoWorkspaceStore.resolved()
        let names = Dictionary(workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let renamed = stored.contains { workspace in
            names[workspace.id].map { $0 != workspace.name } ?? false
        }
        guard renamed else { return }
        workspaces = stored.map { workspace in
            var copy = workspace
            if let name = names[workspace.id] { copy.name = name }
            return copy
        }
        persistWorkspaces()
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
        guard readsCredentials else { return }
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

    private func removeWorkspace(_ id: String) async {
        guard !busyWorkspaceIDs.contains(id),
              let workspace = workspaces.first(where: { $0.id == id })
        else { return }
        busyWorkspaceIDs.insert(id)
        defer { busyWorkspaceIDs.remove(id) }
        let instanceID = workspace.instanceID
        // A removed workspace must not leave its key behind in the Keychain.
        // If it cannot be deleted, keep the row: dropping it here would orphan
        // the secret with no way left to retry from the UI, and it would hide
        // the failure a moment after it happened. Run off MainActor so an
        // unanswered startup Keychain prompt never freezes Settings.
        do {
            try await Self.runKeychainOffMainActor {
                try OpenCodeGoWorkspaceStore.deleteCredential(for: workspace)
            }
        } catch {
            workspaceStatus[instanceID] = "Could not remove: its key could not be deleted from the Keychain"
            return
        }
        workspaces.removeAll { $0.id == id }
        workspaceKeys[instanceID] = nil
        workspaceHasKey[instanceID] = nil
        workspaceStatus[instanceID] = nil
        vaultStatus = KeychainVault.shared.statusSnapshot()
        persistWorkspaces()
    }

    private func moveWorkspace(_ id: String, by offset: Int) {
        workspaces = OpenCodeGoWorkspaceStore.moved(workspaces, id: id, by: offset)
        persistWorkspaces()
    }

    /// Stores one workspace's key and exercises it, so a truncated paste fails
    /// here rather than as an unexplained blank row later.
    private func saveWorkspaceKey(_ workspace: OpenCodeGoWorkspace) async {
        guard !busyWorkspaceIDs.contains(workspace.id) else { return }
        let instanceID = workspace.instanceID
        let key = (workspaceKeys[instanceID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        busyWorkspaceIDs.insert(workspace.id)
        defer { busyWorkspaceIDs.remove(workspace.id) }
        do {
            try await Self.runKeychainOffMainActor {
                try OpenCodeGoWorkspaceStore.setCredential(key, for: workspace)
            }
            if (workspaceKeys[instanceID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == key {
                workspaceKeys[instanceID] = ""
            }
            workspaceHasKey[instanceID] = true
            vaultStatus = KeychainVault.shared.statusSnapshot()
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

    private func hasChanges(for vendor: VendorIdentifier) -> Bool {
        if vendor == .gemini { return hasGeminiClientEdits }
        return entered[vendor, default: ""].trimmingCharacters(in: .whitespacesAndNewlines) != loaded[vendor, default: ""]
    }

    private func cycleSection(_ vendor: VendorIdentifier) -> some View {
        Section {
            CycleEditorRow(
                vendor: vendor,
                cycle: Binding(get: { cycles[vendor] }, set: { cycles[vendor] = $0 }),
                onCommit: { SubscriptionCycleStore.set(cycles[vendor], for: vendor) }
            )
        } header: {
            Text("Renewal cycle")
        } footer: {
            Text("Enter a renewal date to see how much time is left in the billing period when the service leaves it out.")
                .font(.caption)
                .foregroundStyle(Theme.systemSecondaryText)
        }
    }

    /// Vendors worth offering a cycle for: every one FrugalBar tracks, since a
    /// renewal date is just as useful for a vendor it cannot read at all.
    private static let cycleVendors: [VendorIdentifier] = [
        .claude, .openai, .gemini, .copilot, .opencode, .openrouter,
        .deepseek, .grok, .kiro, .muse,
    ]

    private var credentialDiscoverySection: some View {
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
                 Claude Code or Muse Code login Keychain item — if the \
                 Keychain has no entry for a provider. Off by default: this reads \
                 credentials you have not explicitly given the app.
                 """)
                .font(.caption)
                .foregroundStyle(Theme.systemSecondaryText)
        } header: {
            Text("Credential discovery")
        }
    }

    // MARK: - Notifications

    private var notificationsPane: some View {
        Form {
            if notificationPermission == .denied {
                Section {
                    Label("""
                          Notifications are turned off for FrugalBar in System \
                          Settings, so none of the banners below will appear.
                          """, systemImage: "bell.slash")
                    Button("Open Notification Settings", action: openNotificationSettings)
                }
            }

            Section {
                Toggle("Notify when a quota recovers", isOn: $notificationsEnabled)
                Text("""
                     When on, FrugalBar posts a local notification once a \
                     provider goes from critical/exhausted back to having \
                     headroom. Off by default.
                     """)
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            } header: {
                Text("Quota-recovery notifications")
            }

            Section {
                Text("Set reset alerts on each service's page. FrugalBar uses the reset time the service reports.")
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
                Button("Open Services") { selection = .services }
            } header: {
                Text("Reset alerts")
            }

            Section {
                ForEach(Self.eventNotificationCandidates) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(kind.title, isOn: eventNotificationBinding(for: kind))
                        Text(kind.notificationCaption)
                            .font(.caption)
                            .foregroundStyle(Theme.systemSecondaryText)
                    }
                    .disabled(!eventTracking)
                }
                if !eventTracking {
                    Label("Event tracking is off in History & Data, so there is nothing to notify about.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.systemSecondaryText)
                }
            } header: {
                Text("AI events")
            }

            if !LocalNotificationIdentity.isAppBundle {
                Section {
                    Text("""
                         This install runs as the bare `frugalbar` executable. \
                         macOS has no app identity to attribute its banners to, \
                         so they are posted through AppleScript and appear as \
                         Script Editor.
                         """)
                        .font(.caption)
                        .foregroundStyle(Theme.systemSecondaryText)
                }
            }
        }
        .formStyle(.grouped)
        .task { notificationPermission = await LocalNotificationIdentity.authorizationStatus() }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Display

    private var displayPane: some View {
        Form {
            Section {
                Picker("Position", selection: $desktopWidgetMode) {
                    Text("Pinned to desktop").tag(DesktopWidgetMode.desktop)
                    Text("Floats above windows").tag(DesktopWidgetMode.floating)
                }
                .onChange(of: desktopWidgetMode) {
                    CredentialStore.desktopWidgetMode = desktopWidgetMode
                    DesktopWidgetWindow.applyMode()
                }
                if store != nil {
                    Button(desktopWidgetVisibility.isVisible ? "Hide desktop widget" : "Show desktop widget") {
                        DesktopWidgetWindow.toggle()
                    }
                }
                Text("Story follows the menu bar's suggested pool or a pool you pin. Tokens shows usage recorded on this Mac.")
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            } header: {
                Text("Desktop widget")
            }
        }
        .formStyle(.grouped)
    }

    private var readingGuide: some View {
        Form {
            Section("Popover") {
                guideRow("Subscriptions", "Expand a provider to see its pools. Select a pool for details.")
                guideRow("Averages", "Each reported window counts once. The count shows how many pools supplied a figure.")
                guideRow("Bars and resets", "Bars show the share used. The tick marks even pace. Red bars and badges show spent or blocked windows and their published reset times.")
                guideRow("Wallet", "One line per credit, balance or plan reset ticket. Credit bars show the share used; blue bars show time through the month. Balances show their recent trend.")
            }

            Section("Status symbols") {
                DisclosureGroup("Usage details") {
                    legendRows(Self.detailLegend)
                }
                DisclosureGroup("Provider logos") {
                    legendRows(Self.popoverLegend)
                }
                DisclosureGroup("Window bar symbols") {
                    legendRows(Self.windowLegend)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func guideRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.medium)
            Text(description)
                .font(.callout)
                .foregroundStyle(Theme.systemSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func legendRows(_ entries: [LegendEntry]) -> some View {
        ForEach(entries, id: \.title) { entry in
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.systemSecondaryText)
                }
            } icon: {
                Image(systemName: entry.symbol)
                    .foregroundStyle(entry.tint)
            }
            .accessibilityElement(children: .combine)
        }
    }

    struct LegendEntry {
        let symbol: String
        let title: String
        let detail: String
        let tint: Color
    }

    /// The mark on each provider's logo in the popover, each built from
    /// `VendorAvatarView.overlay(status:isExhausted:)` for a provider in that
    /// state, so the legend cannot show a mark the avatar does not draw. No
    /// threshold is quoted: providers set their own (a share of a window at
    /// different levels, or an absolute credit balance), so any single figure
    /// here would be wrong for some of them.
    static let popoverLegend: [LegendEntry] = {
        func entry(_ status: ProviderStatus, isExhausted: Bool = false, title: String,
                   _ detail: String) -> LegendEntry {
            switch VendorAvatarView.overlay(status: status, isExhausted: isExhausted, showsResetOverlay: true) {
            case .none:
                return .init(symbol: noMarkSymbol, title: title, detail: detail, tint: Theme.outline)
            case .exhausted:
                return .init(symbol: VendorAvatarView.Overlay.exhaustedSymbol, title: title, detail: detail,
                             tint: VendorAvatarView.Overlay.exhaustedTint)
            case .struckThrough:
                return .init(symbol: VendorAvatarView.Overlay.strikeSymbol, title: title, detail: detail,
                             tint: VendorAvatarView.Overlay.strikeTint)
            case .badge(let symbol, let tint):
                return .init(symbol: symbol, title: title, detail: detail, tint: tint)
            }
        }
        return [
            entry(.healthy, title: "No mark",
                  "Read, and short of the provider's own warning level: the logo alone."),
            entry(.warning, title: "Running low", "Past the provider's own warning level."),
            entry(.critical, title: "Critically low",
                  "Past the provider's own critical level. Some providers also go critical when the vendor blocks a window; its bar says which."),
            entry(.healthy, isExhausted: true, title: "Exhausted",
                  "A window is used up, or the vendor blocked every window without a figure. The logo turns grey inside a red ring, with its reset countdown in a red tag at the top-left corner; this sign replaces the countdown when no reset date was published."),
            entry(.unavailable(.notConfigured), title: "Could not be read",
                  "No figure is shown; the row names the reason instead."),
        ]
    }()

    /// Stands in for a logo with nothing drawn over it.
    nonisolated static let noMarkSymbol = "app"

    /// The states a provider's usage details lead with, in the inspector's
    /// own words, shapes and colours.
    static let detailLegend: [LegendEntry] = {
        func entry(_ state: MetricDetailPresentation.State, title: String? = nil,
                   _ detail: String) -> LegendEntry {
            let label = MetricDetailPresentation.headlineAndSymbol(for: state)
            return .init(symbol: label.symbol, title: title ?? label.headline, detail: detail,
                         tint: MetricDetailModalView.color(for: state))
        }
        return [
            entry(.healthy, "Read, and short of the provider's own warning level."),
            entry(.runningLow, "Past the provider's own warning level."),
            entry(.critical, "Past the provider's own critical level."),
            entry(.exhausted, "A window is used up."),
            entry(.blocked, "The vendor says a window cannot be used right now."),
            entry(.lastPollFailed(at: .distantPast), title: "Last poll could not be read",
                  "The figures shown are from the reading before it, and may be out of date."),
            entry(.unavailable(.notConfigured), title: "Could not be read",
                  "No figure is shown; the reason and what to do are."),
        ]
    }()

    /// A bar's fill, which carries no shape of its own.
    nonisolated static let fillSymbol = "capsule.fill"
    /// The even-pace tick, an upright capsule across the bar.
    nonisolated static let tickSymbol = "capsule.portrait.fill"

    /// One window bar per state, its swatch taken from
    /// `DualBarProgressView.stateColor` for a window in that state, so the
    /// legend cannot show a colour the bar would not draw. Its only glyphs
    /// are ones the bar's cell draws.
    static let windowLegend: [LegendEntry] = {
        func swatch(_ metrics: DualBarMetrics) -> Color { DualBarProgressView.stateColor(for: metrics) }
        return [
            .init(symbol: fillSymbol, title: "Not ahead of pace",
                  detail: "Not spent, and not meaningfully ahead of an even pace, or no pace was published.",
                  tint: swatch(LegendSample.onPace)),
            .init(symbol: fillSymbol, title: "Ahead of pace",
                  detail: "Used meaningfully more than an even spread would have by now.",
                  tint: swatch(LegendSample.aheadOfPace)),
            .init(symbol: fillSymbol, title: "Spent",
                  detail: "A full bar: nothing left in the window until it resets. In the popover, diagonal stripes and the blocked-or-spent sign replace the redundant percentage label.",
                  tint: swatch(LegendSample.spent)),
            .init(symbol: BlockedGlyph.symbolName, title: "Blocked",
                  detail: "In the vendor's own colour when it gives one, whatever the percentage says, with this sign beside its figure, or a dashed outline in place of a fill when there is no figure. The popover also uses this sign for a spent window.",
                  tint: swatch(LegendSample.blocked)),
            .init(symbol: "minus", title: "Not published",
                  detail: "A faint dash, never an empty bar, which would read as nothing used.",
                  tint: Theme.outline),
            .init(symbol: tickSymbol, title: "Even-pace tick",
                  detail: "A short white mark across the bar, where usage would be if spread evenly over the window. Drawn only when the vendor publishes the window's length and reset, and never on a spent window.",
                  tint: .secondary),
        ]
    }()

    /// Windows in each state the bar legend describes, so its swatches are
    /// computed by the code that colours the bars.
    enum LegendSample {
        private static let now = Date(timeIntervalSinceReferenceDate: 0)
        private static func window(used: Double, pace: Double) -> DualBarMetrics {
            DualBarMetrics(primaryFraction: used, expectedPaceFraction: pace, label: "WK",
                           resetsAt: now.addingTimeInterval(86_400), windowLength: 7 * 86_400)
        }
        static let onPace = window(used: 0.5, pace: 0.5)
        static let aheadOfPace = window(used: 0.8, pace: 0.4)
        static let spent = window(used: 1, pace: 0.5)
        static let blocked = DualBarMetrics(primaryFraction: 0.4, label: "WK", isBlocked: true)
    }

    @State private var desktopWidgetVisibility = DesktopWidgetVisibility.shared

    // MARK: - History & data

    private var dataPane: some View {
        Form {
            Section {
                Toggle("Track resets, outages and new models", isOn: $eventTracking)
                Text("""
                     Reads the official status pages for Claude, OpenAI and \
                     GitHub every 10 minutes, the community reset trackers \
                     claude-resets.com and whenreset.dev hourly, and each \
                     subscription's own model list hourly with the credential \
                     it already uses. Only past events are recorded, never \
                     forecasts.
                     """)
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            } header: {
                Text("AI events")
            }

            Section {
                // A form row's value is drawn in the system secondary label
                // (3.8:1 on this ground) unless styled; these are facts the
                // user came here to read, so they take the readable style.
                LabeledContent("Kept for") {
                    Text("\(Int(QuotaHistoryStore.defaultRetentionInterval / 86_400)) days")
                        .foregroundStyle(Theme.systemSecondaryText)
                }
                LabeledContent("Location") {
                    Text(QuotaHistoryStore.databaseURL().path(percentEncoded: false))
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.systemSecondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open History") { HistoryWindow.show() }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([QuotaHistoryStore.databaseURL()])
                    }
                }
                Text("""
                     Each poll records the reading every visible provider \
                     returned — or that it returned none — on this Mac only. \
                     Nothing is uploaded. The History window and the inspector \
                     chart these readings; a hidden provider records nothing.
                     """)
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            } header: {
                Text("Quota history")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    /// Populates credential fields from the in-memory vault cache only.
    /// Never blocks the main thread or prompts macOS Keychain.
    private func loadKeysFromCache() {
        // One coherent read: status and values from the same vault state.
        let clientLabel = GeminiOAuthSession.clientIDKeychainLabel
        let snapshot = KeychainVault.shared.cachedSnapshot(
            namespace: .keys,
            accounts: Self.slots.map(\.id.rawValue) + [clientLabel]
        )
        let status = snapshot.status
        var current: [VendorIdentifier: String] = [:]
        var unreadable: Set<VendorIdentifier> = []
        for slot in Self.slots {
            if let fresh = SettingsVaultReload.freshValue(
                label: slot.id.rawValue,
                cached: snapshot.values[slot.id.rawValue],
                in: status
            ) {
                current[slot.id] = fresh
            } else {
                unreadable.insert(slot.id)
            }
        }
        let storedClient = snapshot.values[clientLabel].flatMap { $0.isEmpty ? nil : $0 }
        let freshGeminiClientID = SettingsVaultReload.freshValue(
            label: clientLabel,
            cached: storedClient,
            in: status
        )
        let merged = SettingsCredentialMerge.merge(
            slots: Self.slots.map(\.id),
            currentLoaded: loaded,
            currentEntered: entered,
            freshLoaded: current,
            currentLoadedGeminiClientID: loadedGeminiClientID,
            currentEnteredGeminiClientID: geminiClientID,
            freshGeminiClientID: freshGeminiClientID ?? "",
            unreadableSlots: unreadable,
            geminiClientIDUnreadable: freshGeminiClientID == nil
        )
        loaded = merged.loaded
        entered = merged.entered
        loadedGeminiClientID = merged.loadedGeminiClientID
        geminiClientID = merged.enteredGeminiClientID
        geminiSecretIsStored = GeminiOAuthLogin.hasClientSecretOverride()
        vaultStatus = status
    }

    /// Runs a non-interactive vault warm-up off the main thread when the vault
    /// is still unloaded, merges freshly cached values while preserving dirty
    /// user edits, and refreshes non-interactive credential provenance.
    private func loadVaultAsyncAndRefreshSources() async {
        let current = KeychainVault.shared.statusSnapshot()
        if current.state == .unloaded {
            vaultStatus = await KeychainVault.shared.warmUp(interactive: false)
        } else {
            vaultStatus = current
        }
        loadKeysFromCache()
        refreshWorkspaceHasKey()
        await refreshSources()
    }

    /// Explicit interactive Unlock / Save pending changes / Retry action from
    /// the inline Settings banner.
    private func unlockVault() async {
        isUnlockingVault = true
        defer { isUnlockingVault = false }
        vaultStatus = await KeychainVault.shared.unlock()
        loadKeysFromCache()
        refreshWorkspaceHasKey()
        await refreshSources()
        if vaultStatus.state == .loaded || vaultStatus.state == .empty {
            sync?.vaultDidUnlock()
        }
        Task { await store?.forceRefresh(allowInteractiveUnlock: false) }
    }

    private var hasGeminiClientEdits: Bool {
        geminiClientID != loadedGeminiClientID
            || !geminiClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connectGemini() async {
        guard !isSigningInToGemini && verifyingVendor == nil else { return }
        isSigningInToGemini = true
        defer { isSigningInToGemini = false }

        // Persist any unsaved client configuration edits before signing in:
        // the flow reads from the Keychain, so a secret typed but not yet saved
        // would fail the exchange. Skip writing untouched fields so clicking
        // Connect (or typing only a secret) before the vault finishes loading
        // cannot overwrite or delete an already-stored client ID.
        if hasGeminiClientEdits {
            let clientChanged = geminiClientID != loadedGeminiClientID
            let clientIDToSave = geminiClientID
            let clientSecretToSave = geminiClientSecret
            do {
                try await Self.runKeychainOffMainActor {
                    try GeminiOAuthLogin.saveClientConfiguration(
                        clientID: clientIDToSave,
                        clientSecret: clientSecretToSave,
                        updateClientID: clientChanged
                    )
                }
                if clientChanged {
                    loadedGeminiClientID = clientIDToSave
                }
                if geminiClientSecret == clientSecretToSave {
                    geminiClientSecret = ""
                }
                geminiSecretIsStored = GeminiOAuthLogin.hasClientSecretOverride()
            } catch {
                geminiSignInStatus = "Could not save the client configuration to the Keychain"
                return
            }
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
    private func saveAndVerify(_ vendor: VendorIdentifier) async {
        guard verifyingVendor == nil && !isSigningInToGemini else { return }
        verifyingVendor = vendor
        defer { verifyingVendor = nil }

        // Persist the Gemini client alongside the vendor keys. Changing it
        // orphans any stored session — a refresh token belongs to the client
        // that issued it — so say so rather than letting the row quietly read
        // "Not configured" afterwards.
        let clientChanged = geminiClientID != loadedGeminiClientID
        if vendor == .gemini && hasGeminiClientEdits {
            let clientIDToSave = geminiClientID
            let clientSecretToSave = geminiClientSecret
            do {
                try await Self.runKeychainOffMainActor {
                    try GeminiOAuthLogin.saveClientConfiguration(
                        clientID: clientIDToSave,
                        clientSecret: clientSecretToSave,
                        updateClientID: clientChanged
                    )
                }
                if clientChanged {
                    loadedGeminiClientID = clientIDToSave
                }
                if geminiClientSecret == clientSecretToSave {
                    geminiClientSecret = ""
                }
                geminiSecretIsStored = GeminiOAuthLogin.hasClientSecretOverride()
                geminiSignInStatus = clientChanged
                    ? "Client saved. Connect Google account again to sign in with it."
                    : "Client secret saved."
            } catch {
                geminiSignInStatus = "Could not save the client configuration to the Keychain"
            }
        }

        var githubPatChanged = false

        for slot in Self.slots where slot.id == vendor {
            let new = (entered[slot.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let old = loaded[slot.id] ?? ""
            guard new != old else { continue }

            let label = slot.id.rawValue
            do {
                if new.isEmpty {
                    // Clearing a field means "forget this", not "store empty".
                    try await Self.runKeychainOffMainActor {
                        try KeychainManager.shared.delete(label: label)
                    }
                    perKeyStatus[slot.id] = "Removed"
                } else {
                    try await Self.runKeychainOffMainActor {
                        try KeychainManager.shared.set(key: new, label: label)
                    }
                    perKeyStatus[slot.id] = await verify(slot.id, key: new)
                }
                loaded[slot.id] = new
                githubPatChanged = slot.id == .githubRest
            } catch {
                perKeyStatus[slot.id] = Self.keychainAdvice(for: error)
            }
        }

        // GitHub's PAT backs three providers; keep them in step. A partial
        // sync must be reported — otherwise the GraphQL and Copilot rows keep
        // serving a revoked token with no field to fix it in.
        if githubPatChanged, let pat = loaded[.githubRest] {
            let failures = await applyGitHubTokenToLinkedVendors(pat)
            if !failures.isEmpty {
                perKeyStatus[.githubRest] = "Saved, but could not sync to \(failures.joined(separator: ", "))"
            }
        }

        vaultStatus = KeychainVault.shared.statusSnapshot()
        await refreshSources()
    }

    /// Runs a blocking Keychain mutation off MainActor so an in-flight startup
    /// SecurityAgent prompt holding the vault lock never freezes Settings.
    private static func runKeychainOffMainActor<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try operation()
        }.value
    }

    /// Returns the display names of any linked vendors that could not be synced.
    private func applyGitHubTokenToLinkedVendors(_ pat: String) async -> [String] {
        var failed: [String] = []
        for vendor in [VendorIdentifier.githubGraphql, .copilot] {
            let label = vendor.rawValue
            do {
                try await Self.runKeychainOffMainActor {
                    if pat.isEmpty {
                        try KeychainManager.shared.delete(label: label)
                    } else {
                        try KeychainManager.shared.set(key: pat, label: label)
                    }
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
        case .antigravityClaude: provider = GeminiQuotaProvider(accessToken: key, allowance: .claude)
        case .antigravityArgon: provider = GeminiQuotaProvider(accessToken: key, allowance: .argon)
        case .opencode:    provider = OpenCodeGoProvider(apiKey: key)
        case .copilot:     provider = GitHubCopilotProvider(token: key)
        case .grok:        provider = GrokQuotaProvider(accessToken: key)
        // Kiro has no key slot — its token and profile ARN are read together
        // from the CLI state database — but the switch must stay exhaustive.
        case .kiro:        provider = KiroQuotaProvider()
        case .devpass:     provider = DevPassQuotaProvider(apiKey: key)
        case .commandcode: provider = CommandCodeQuotaProvider(apiKey: key)
        case .clinepass:   provider = ClinePassQuotaProvider(apiKey: key)
        case .muse:        provider = MuseQuotaProvider(apiKey: key)
        // OpenDesign has no key slot: an inference key cannot read usage, so
        // it connects through its web sign-in. The switch must stay exhaustive.
        case .opendesign:  provider = OpenDesignQuotaProvider()
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
