import SwiftUI
import QuotaBarCore

/// Pure list edits behind the Providers tab, kept out of the view so they can
/// be tested.
enum ProviderOrderEditing {

    /// Moves `vendor` one place up or down. A move past either end, or of a
    /// vendor not in the list, changes nothing.
    static func move(_ vendor: VendorIdentifier, by offset: Int, in order: [VendorIdentifier]) -> [VendorIdentifier] {
        guard let index = order.firstIndex(of: vendor) else { return order }
        let target = index + offset
        guard order.indices.contains(target) else { return order }
        var result = order
        result.swapAt(index, target)
        return result
    }

    /// Flips one vendor's visibility.
    static func setShown(_ shown: Bool, _ vendor: VendorIdentifier, hidden: Set<VendorIdentifier>) -> Set<VendorIdentifier> {
        var result = hidden
        if shown { result.remove(vendor) } else { result.insert(vendor) }
        return result
    }
}

/// Preferences → Providers: each provider's connection, which providers
/// appear, and in what order — OpenCode Go workspaces included.
///
/// Every change is written at once, as on the Cycles tab. Writing posts
/// `frugalbarProviderPreferencesDidChange`, which the app uses to drop a
/// hidden provider and fetch a newly shown one without waiting for a poll.
struct ProviderOrderSettings: View {

    /// The running app's store, for each provider's connection state. nil in
    /// the standalone Settings scene, which then says only what it knows.
    let store: QuotaStore?
    var onManageWorkspaces: () -> Void = {}

    @State private var ordering = CredentialStore.providerOrdering
    @State private var order = CredentialStore.providerOrder
    @State private var hidden = CredentialStore.hiddenProviders
    @State private var workspaces = OpenCodeGoWorkspaceStore.resolved()

    var body: some View {
        Form {
            Section {
                Picker("Order", selection: $ordering) {
                    Text("Soonest deadline first").tag(ProviderOrdering.automatic)
                    Text("Custom order").tag(ProviderOrdering.custom)
                }
                .onChange(of: ordering) { CredentialStore.providerOrdering = ordering }
                Text(ordering == .automatic
                     ? """
                       Service blocks are placed by the soonest longest-window \
                       reset among their usable members. The list below breaks \
                       ties and sets the order inside Antigravity and OpenCode Go \
                       blocks. A block moves last only when every member has a spent or blocked window.
                       """
                     : """
                       Antigravity pools and OpenCode Go workspaces each stay \
                       together in their saved order. The first visible member \
                       places its block in the list below. A block moves last \
                       only when every member has a spent or blocked window.
                       """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Order")
            }

            Section {
                ForEach(order, id: \.self) { vendor in
                    row(vendor)
                    if vendor == .opencode, !hidden.contains(.opencode) {
                        ForEach(workspaces) { workspace in
                            workspaceRow(workspace)
                        }
                    }
                }
                Button("Reset to default order") {
                    CredentialStore.resetProviderOrder()
                    order = CredentialStore.providerOrder
                }
                .disabled(order == ProviderDisplayPreferences.defaultOrder)
            } header: {
                Text("Providers")
            } footer: {
                Text("""
                     A hidden provider is not polled, and does not appear in the \
                     popover, menu bar, advice, desktop widget or notifications. \
                     Its key stays where it is, so showing it again is instant.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .onAppear { workspaces = OpenCodeGoWorkspaceStore.resolved() }
    }

    private var now: Date { Date() }

    private func snapshots(for vendor: VendorIdentifier) -> [QuotaSnapshot] {
        store?.snapshots.filter { $0.vendorId == vendor } ?? []
    }

    private func row(_ vendor: VendorIdentifier) -> some View {
        let isShown = !hidden.contains(vendor)
        let index = order.firstIndex(of: vendor) ?? 0
        let status = ProviderConnectionPresentation.status(
            vendorSnapshots: snapshots(for: vendor), isHidden: !isShown,
            hasPolled: store?.hasLoaded ?? false, now: now)
        return HStack(spacing: 8) {
            VendorAvatarView(vendorId: vendor, status: .healthy, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(vendor.displayName)
                    .foregroundStyle(isShown ? .primary : .secondary)
                ConnectionStatusLine(status: status)
            }
            Spacer()
            Button { move(vendor, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .accessibilityLabel("Move \(vendor.displayName) up")
            Button { move(vendor, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == order.count - 1)
                .accessibilityLabel("Move \(vendor.displayName) down")
            Toggle("Shown", isOn: Binding(
                get: { isShown },
                set: { on in
                    hidden = ProviderOrderEditing.setShown(on, vendor, hidden: hidden)
                    CredentialStore.hiddenProviders = hidden
                }
            ))
            .labelsHidden()
            .accessibilityLabel("Show \(vendor.displayName)")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(vendor.displayName), \(isShown ? "shown" : "hidden"), position \(index + 1) of \(order.count), \(status.accessibilityText)")
    }

    /// One OpenCode Go workspace, indented under its vendor. Its arrows move
    /// it among the workspaces only; the vendor's own arrows move the block.
    private func workspaceRow(_ workspace: OpenCodeGoWorkspace) -> some View {
        let index = workspaces.firstIndex { $0.id == workspace.id } ?? 0
        let snapshot = snapshots(for: .opencode).first { $0.id == workspace.instanceID }
        let status: ProviderConnectionPresentation.Status = if !workspace.isEnabled {
            .init(symbol: "pause.circle", title: "Not monitored", detail: nil, tone: .inactive)
        } else if let snapshot {
            ProviderConnectionPresentation.status(for: snapshot, now: now)
        } else {
            ProviderConnectionPresentation.status(
                vendorSnapshots: [], isHidden: false, hasPolled: store?.hasLoaded ?? false, now: now)
        }
        return HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .foregroundStyle(workspace.isEnabled ? .primary : .secondary)
                ConnectionStatusLine(status: status)
            }
            Spacer()
            Button("Manage…", action: onManageWorkspaces)
                .font(.caption)
            Button { moveWorkspace(workspace.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .accessibilityLabel("Move workspace \(workspace.name) up")
            Button { moveWorkspace(workspace.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == workspaces.count - 1)
                .accessibilityLabel("Move workspace \(workspace.name) down")
        }
        .padding(.leading, 18)
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "OpenCode Go workspace \(workspace.name), position \(index + 1) of \(workspaces.count), \(status.accessibilityText)")
    }

    private func move(_ vendor: VendorIdentifier, by offset: Int) {
        order = ProviderOrderEditing.move(vendor, by: offset, in: order)
        CredentialStore.providerOrder = order
        // Arranging the list is a request for that order.
        if ordering != .custom {
            ordering = .custom
            CredentialStore.providerOrdering = .custom
        }
    }

    /// Workspace order holds in either ordering mode, so moving one does not
    /// switch the provider list to a custom order.
    private func moveWorkspace(_ id: String, by offset: Int) {
        workspaces = OpenCodeGoWorkspaceStore.moved(workspaces, id: id, by: offset)
        OpenCodeGoWorkspaceStore.set(workspaces)
    }
}

/// A provider's connection state as a symbol and words.
struct ConnectionStatusLine: View {
    let status: ProviderConnectionPresentation.Status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: status.symbol)
                .foregroundStyle(color)
            Text(status.title)
                .foregroundStyle(status.tone == .attention ? color : .secondary)
            if let detail = status.detail {
                Text("· \(detail)")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityText)
    }

    private var color: Color {
        switch status.tone {
        case .connected: .green
        case .attention: .orange
        case .inactive: .secondary
        }
    }
}
