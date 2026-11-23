import SwiftUI
import QuotaBarCore

/// Maps saved vendor positions to the service pages and edits their order.
enum ProviderOrderEditing {

    static func service(for vendor: VendorIdentifier) -> VendorIdentifier {
        switch vendor {
        case .antigravityClaude, .antigravityArgon: .gemini
        case .githubGraphql: .githubRest
        default: vendor
        }
    }

    static func services(in order: [VendorIdentifier]) -> [VendorIdentifier] {
        var seen: Set<VendorIdentifier> = []
        return order.map(service(for:)).filter { seen.insert($0).inserted }
    }

    static func members(of serviceID: VendorIdentifier, in order: [VendorIdentifier]) -> [VendorIdentifier] {
        order.filter { service(for: $0) == serviceID }
    }

    static func moveService(_ serviceID: VendorIdentifier, by offset: Int,
                            in order: [VendorIdentifier]) -> [VendorIdentifier] {
        let current = services(in: order)
        let moved = move(serviceID, by: offset, in: current)
        guard moved != current else { return order }
        return moved.flatMap { members(of: $0, in: order) }
    }

    static func moveMember(_ vendor: VendorIdentifier, by offset: Int,
                           in order: [VendorIdentifier]) -> [VendorIdentifier] {
        let current = members(of: service(for: vendor), in: order)
        let moved = move(vendor, by: offset, in: current)
        var members = moved.makeIterator()
        return order.map { service(for: $0) == service(for: vendor) ? (members.next() ?? $0) : $0 }
    }

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

/// Settings → Services. Service order is stored using the existing vendor list.
struct ProviderOrderSettings: View {
    let store: QuotaStore?
    @Binding var order: [VendorIdentifier]
    let hidden: Set<VendorIdentifier>
    let onManage: (VendorIdentifier) -> Void

    var body: some View {
        let services = ProviderOrderEditing.services(in: order)
        Form {
            Section {
                ForEach(Array(services.enumerated()), id: \.element) { index, service in
                    row(service, at: index, count: services.count)
                }
                Button("Reset to default order") {
                    CredentialStore.resetProviderOrder()
                    order = CredentialStore.providerOrder
                }
                .disabled(order == ProviderDisplayPreferences.defaultOrder)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Service order")
                    Text("The arrows set the order here and in the popover's provider list and Wallet.")
                        .font(.callout)
                        .foregroundStyle(Theme.systemSecondaryText)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ service: VendorIdentifier, at index: Int, count: Int) -> some View {
        let title = GlancePresentation.serviceName(for: service)
        let visible = ProviderOrderEditing.members(of: service, in: order).filter { !hidden.contains($0) }
        let status = ProviderConnectionPresentation.status(
            vendorSnapshots: store?.snapshots.filter { visible.contains($0.vendorId) } ?? [],
            isHidden: visible.isEmpty, hasPolled: store?.hasLoaded ?? false, now: Date())
        return HStack(spacing: 10) {
            Button { onManage(service) } label: {
                HStack(spacing: 10) {
                    VendorAvatarView(vendorId: service, status: .healthy, size: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).fontWeight(.medium)
                        ConnectionStatusLine(status: status)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(title) settings")
            .accessibilityValue(status.accessibilityText)

            ServiceOrderButtons(title: title, canMoveUp: index > 0, canMoveDown: index < count - 1) { offset in
                order = ProviderOrderEditing.moveService(service, by: offset, in: order)
                CredentialStore.providerOrder = order
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }
}

struct ServiceOrderButtons: View {
    let title: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!canMoveUp)
                .accessibilityLabel("Move \(title) up")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!canMoveDown)
                .accessibilityLabel("Move \(title) down")
        }
        .buttonStyle(.borderless)
    }
}

/// A provider's connection state as a symbol and words.
struct ConnectionStatusLine: View {
    let status: ProviderConnectionPresentation.Status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: status.symbol)
                .foregroundStyle(color)
            // The symbol carries the tone in colour and shape. The words stay
            // in text colours: system orange on a light form is about 2.2:1.
            Text(status.title)
                .foregroundStyle(status.tone == .attention ? Color.primary : Theme.systemSecondaryText)
            if let detail = status.detail {
                Text("· \(detail)")
                    .foregroundStyle(Theme.systemSecondaryText)
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
