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
    @State private var hasGrantDate = false
    @State private var grantDay = Date()
    @State private var saved = false

    private var grant: OpenAICreditGrant? {
        guard hasGrant, let amount = OpenAICreditGrant.parseTotal(total) else { return nil }
        let end = hasExpiry ? Calendar.current.date(byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: expiryDay)) : nil
        // A grant date gives the bar its period, so only with an expiry.
        let start = hasExpiry && hasGrantDate ? Calendar.current.startOfDay(for: grantDay) : nil
        return OpenAICreditGrant(total: amount, expiresAt: end, grantedAt: start)
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
                        Toggle("I know when it was granted", isOn: $hasGrantDate)
                        if hasGrantDate {
                            DatePicker("Granted on", selection: $grantDay, displayedComponents: .date)
                            if Calendar.current.startOfDay(for: grantDay) > Calendar.current.startOfDay(for: expiryDay) {
                                Text("The grant date must be before the expiry.")
                                    .font(.caption).foregroundStyle(Theme.error)
                            }
                        }
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
                    if saved { Text("Saved").foregroundStyle(Theme.systemSecondaryText) }
                }
                .task(id: accountKey) { load(accountKey) }
                .onChange(of: proTier) { saved = false }
                .onChange(of: hasGrant) { saved = false }
                .onChange(of: total) { saved = false }
                .onChange(of: hasExpiry) { saved = false }
                .onChange(of: expiryDay) { saved = false }
                .onChange(of: hasGrantDate) { saved = false }
                .onChange(of: grantDay) { saved = false }
            } else {
                Text("Refresh ChatGPT to identify the account before saving its credit grant or plan detail.")
                    .foregroundStyle(Theme.systemSecondaryText)
            }
        } header: {
            Text("ChatGPT account details")
        } footer: {
            Text("Enter the original credit allowance and expiry from your grant. With the date it was granted, the bar marks where even use would be. The balance stays live; these details apply only to this account. Pro detail refines a reported Pro plan and does not override a different plan.")
                .font(.caption).foregroundStyle(Theme.systemSecondaryText)
        }
    }

    private func load(_ key: String) {
        let value = OpenAIAccountPreferences.load(accountKey: key)
        proTier = value?.proTier
        hasGrant = value?.creditGrant != nil
        total = value?.creditGrant.map { NSDecimalNumber(decimal: $0.total).stringValue } ?? ""
        hasExpiry = value?.creditGrant?.expiresAt != nil
        if let end = value?.creditGrant?.expiresAt { expiryDay = end.addingTimeInterval(-1) }
        hasGrantDate = value?.creditGrant?.grantedAt != nil
        if let start = value?.creditGrant?.grantedAt { grantDay = start }
        saved = false
    }
}
