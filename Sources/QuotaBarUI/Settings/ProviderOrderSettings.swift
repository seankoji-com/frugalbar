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

/// Preferences → Providers: which providers appear, and in what order.
///
/// Every change is written at once, as on the Cycles tab. Writing posts
/// `frugalbarProviderPreferencesDidChange`, which the app uses to drop a
/// hidden provider and fetch a newly shown one without waiting for a poll.
struct ProviderOrderSettings: View {

    @State private var ordering = CredentialStore.providerOrdering
    @State private var order = CredentialStore.providerOrder
    @State private var hidden = CredentialStore.hiddenProviders

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
                       The provider whose longest window turns over soonest comes \
                       first and a spent one goes last. The list below only breaks ties.
                       """
                     : "Providers appear exactly in the order below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Order")
            }

            Section {
                ForEach(order, id: \.self) { vendor in
                    row(vendor)
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
    }

    private func row(_ vendor: VendorIdentifier) -> some View {
        let isShown = !hidden.contains(vendor)
        let index = order.firstIndex(of: vendor) ?? 0
        return HStack(spacing: 8) {
            VendorAvatarView(vendorId: vendor, status: .healthy, size: 18)
            Text(vendor.displayName)
                .foregroundStyle(isShown ? .primary : .secondary)
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
        .accessibilityLabel("\(vendor.displayName), \(isShown ? "shown" : "hidden"), position \(index + 1) of \(order.count)")
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
}
