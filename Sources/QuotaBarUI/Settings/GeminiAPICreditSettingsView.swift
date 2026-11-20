import SwiftUI
import QuotaBarCore

/// Editor for the prepaid Gemini API credit on a Google AI Studio key.
///
/// Every figure is typed by the account holder because Google publishes no
/// documented API for it: AI Studio shows the Prepay balance only in its
/// Billing tab, and a Gemini API key cannot read billing. This view therefore
/// says *configured* on the field, the row and the spoken label — it never
/// presents these amounts as a vendor reading, and it saves no quota, bar or
/// history point from them.
struct GeminiAPICreditSettingsView: View {

    /// Called after a save so the popover redraws the configured line.
    var onSaved: () -> Void = {}

    @State private var currencyCode = Locale.current.currency?.identifier ?? "USD"
    @State private var balanceText = ""
    @State private var monthlyText = ""
    @State private var capText = ""
    @State private var loaded = false
    @State private var saved = false
    @State private var configured = false

    var body: some View {
        DisclosureGroup {
            TextField("Currency (ISO code)", text: $currencyCode)
                .textFieldStyle(.roundedBorder)
            TextField("Prepaid balance", text: $balanceText)
                .textFieldStyle(.roundedBorder)
            TextField("Monthly Developer Program credit", text: $monthlyText)
                .textFieldStyle(.roundedBorder)
            TextField("Monthly spend cap", text: $capText)
                .textFieldStyle(.roundedBorder)

            if !draft.valid {
                Text("Use a three-letter currency code and whole amounts (12 or 1,234.50). The monthly credit cannot be negative, and the spend cap must be above zero.")
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            } else if draft.credit == nil {
                Text("Enter a prepaid balance, a monthly credit, or both.")
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            }

            HStack(spacing: 10) {
                Button("Save configured credit") { save() }
                    .disabled(!draft.valid || draft.credit == nil)
                if configured {
                    Button("Remove") { remove() }
                }
                if saved {
                    Text("Saved")
                        .foregroundStyle(Theme.systemSecondaryText)
                }
            }

            Text("""
                 Google publishes the AI Studio Prepay balance only in its \
                 Billing tab, and no documented Gemini API endpoint returns an \
                 API key's credit or spend. The balance belongs to the key's \
                 Cloud Billing account, shared by every project on it. \
                 FrugalBar therefore shows the figures you enter here, labels \
                 them configured, and dates them. They are not a measured \
                 vendor balance: they draw no bar, take no part in quota \
                 urgency, sorting or advice, and are never recorded in balance \
                 history. The monthly spend cap is the limit you set in AI \
                 Studio, shown as a limit only. A negative prepay balance is \
                 accepted; Google documents a billing lag that can overdraw it.
                 """)
                .font(.caption)
                .foregroundStyle(Theme.systemSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            HStack(spacing: 6) {
                Text("Gemini API prepaid credit")
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: configured ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(configured ? Color.green : Theme.systemSecondaryText)
                    Text(configured ? "Configured" : "Not configured")
                        .foregroundStyle(Theme.systemSecondaryText)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
        }
        .task {
            guard !loaded else { return }
            load()
            loaded = true
        }
        .onChange(of: currencyCode) { saved = false }
        .onChange(of: balanceText) { saved = false }
        .onChange(of: monthlyText) { saved = false }
        .onChange(of: capText) { saved = false }
    }

    /// The fields as a validated credit. `valid` distinguishes empty (fine)
    /// from unparseable (refused), so a typo in one pool cannot silently drop
    /// that pool and save the others as if the user had cleared it. Parsing is
    /// whole-field: a prefix is never accepted as a number.
    private var draft: (credit: GeminiAPICredit?, valid: Bool) {
        let balance = GeminiAPICredit.amount(from: balanceText)
        let monthly = GeminiAPICredit.amount(from: monthlyText)
        let cap = GeminiAPICredit.amount(from: capText)
        guard balance != .invalid, monthly != .invalid, cap != .invalid
        else { return (nil, false) }
        let credit = GeminiAPICredit(
            currencyCode: currencyCode,
            prepaidBalance: balance.decimal,
            monthlyCredit: monthly.decimal,
            monthlySpendCap: cap.decimal,
            configuredAt: Date())
        return (credit, credit != nil)
    }

    private func load() {
        guard let stored = GeminiAPICreditStore.load() else {
            configured = false
            saved = false
            return
        }
        currencyCode = stored.currencyCode
        balanceText = text(stored.prepaidBalance)
        monthlyText = text(stored.monthlyCredit)
        capText = text(stored.monthlySpendCap)
        configured = true
        saved = false
    }

    private func text(_ amount: Decimal?) -> String {
        amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }

    private func save() {
        guard let credit = draft.credit else { return }
        GeminiAPICreditStore.save(credit)
        configured = true
        saved = true
        onSaved()
    }

    private func remove() {
        GeminiAPICreditStore.save(nil)
        balanceText = ""
        monthlyText = ""
        capText = ""
        configured = false
        saved = true
        onSaved()
    }
}
