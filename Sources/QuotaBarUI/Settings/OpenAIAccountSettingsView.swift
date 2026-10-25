import SwiftUI
import QuotaBarCore

struct OpenAIAccountSettingsView: View {
    let accountKey: String?
    var onSave: () -> Void = {}
    @State private var proTier: OpenAIAccountPreferences.ProTier?
    @State private var hasGrant = false
    @State private var total = ""
    @State private var hasExpiry = false
    @State private var expiryDay = Date()
    @State private var saved = false

    private var grant: OpenAICreditGrant? {
        guard hasGrant, let amount = OpenAICreditGrant.parseTotal(total) else { return nil }
        let end = hasExpiry ? Calendar.current.date(byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: expiryDay)) : nil
        return OpenAICreditGrant(total: amount, expiresAt: end)
    }

    var body: some View {
        Section {
            if let accountKey {
                Picker("Pro plan detail", selection: $proTier) {
                    Text("Reported plan").tag(OpenAIAccountPreferences.ProTier?.none)
                    ForEach(OpenAIAccountPreferences.ProTier.allCases, id: \.self) { tier in
                        Text(tier.rawValue).tag(Optional(tier))
                    }
                }
                Toggle("Show usage credit bar", isOn: $hasGrant)
                if hasGrant {
                    TextField("Original credits", text: $total)
                    Toggle("Credits have an expiry", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker("Expires at end of", selection: $expiryDay, displayedComponents: .date)
                    }
                }
                HStack {
                    Button("Save account details") {
                        OpenAIAccountPreferences.save(
                            OpenAIAccountPreferences(proTier: proTier, creditGrant: grant), accountKey: accountKey)
                        saved = true
                        onSave()
                    }
                    .disabled(hasGrant && grant == nil)
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                }
                .task(id: accountKey) { load(accountKey) }
                .onChange(of: proTier) { saved = false }
                .onChange(of: hasGrant) { saved = false }
                .onChange(of: total) { saved = false }
                .onChange(of: hasExpiry) { saved = false }
                .onChange(of: expiryDay) { saved = false }
            } else {
                Text("Refresh ChatGPT to identify the account before saving its credit grant or plan detail.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("ChatGPT account details")
        } footer: {
            Text("Enter the original credit allowance and expiry from your grant. The balance stays live; these details apply only to this account. Pro detail refines a reported Pro plan and does not override a different plan.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load(_ key: String) {
        let value = OpenAIAccountPreferences.load(accountKey: key)
        proTier = value?.proTier
        hasGrant = value?.creditGrant != nil
        total = value?.creditGrant.map { NSDecimalNumber(decimal: $0.total).stringValue } ?? ""
        hasExpiry = value?.creditGrant?.expiresAt != nil
        if let end = value?.creditGrant?.expiresAt { expiryDay = end.addingTimeInterval(-1) }
        saved = false
    }
}
