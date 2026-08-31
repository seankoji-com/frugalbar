import SwiftUI
import QuotaBarCore

/// Editor for one vendor's hand-entered renewal schedule.
///
/// Separate from the credential fields on purpose. A renewal date is not a
/// secret and buys no usage telemetry — it only answers "how much of the period
/// I paid for is left", and mixing it in with the key slots would suggest
/// otherwise.
struct CycleEditorRow: View {

    let vendor: VendorIdentifier
    @Binding var cycle: SubscriptionCycle?
    let onCommit: () -> Void

    @State private var costText: String = ""
    @State private var costCommitTask: Task<Void, Never>?

    /// A vendor with no cycle yet starts from today, the one date the user is
    /// certain to be able to correct from.
    private static func blank() -> SubscriptionCycle {
        SubscriptionCycle(anchorDate: Date(), cadence: .monthly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(vendor.displayName)
                    .font(.body)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .accessibilityLabel("Track \(vendor.displayName) renewal cycle")
            }

            if cycle != nil {
                HStack(spacing: 10) {
                    DatePicker(
                        "Renews on",
                        selection: anchorBinding,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.field)
                    .frame(maxWidth: 190)

                    Picker("", selection: cadenceBinding) {
                        ForEach(SubscriptionCycle.Cadence.allCases, id: \.self) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    // Bordered on purpose: unstyled, an empty field with a
                    // placeholder is indistinguishable from a label, and the
                    // cost simply looks like static text nobody can edit.
                    TextField("Cost", text: $costText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                        .onSubmit {
                            costCommitTask?.cancel()
                            commitCost()
                        }
                        .onChange(of: costText) { scheduleCostCommit() }
                }
                Text("Any date the subscription renewed on, or will renew on — "
                   + "every later renewal is counted forward from it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            costText = cycle?.cost.map { "\($0)" } ?? ""
        }
    }

    /// "Monthly · 12 days left", or nothing at all when untracked. Never a
    /// placeholder number — an unset cycle has no countdown to show.
    private var summary: String {
        guard let cycle else { return "Not tracked" }
        guard let days = cycle.daysRemaining(from: Date()) else {
            return cycle.cadence.displayName
        }
        return "\(cycle.cadence.displayName) · \(days) day\(days == 1 ? "" : "s") left"
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { cycle != nil },
            set: { isOn in
                cycle = isOn ? Self.blank() : nil
                if !isOn { costText = "" }
                onCommit()
            }
        )
    }

    private var anchorBinding: Binding<Date> {
        Binding(
            get: { cycle?.anchorDate ?? Date() },
            set: { newValue in
                guard var updated = cycle else { return }
                updated.anchorDate = newValue
                cycle = updated
                onCommit()
            }
        )
    }

    private var cadenceBinding: Binding<SubscriptionCycle.Cadence> {
        Binding(
            get: { cycle?.cadence ?? .monthly },
            set: { newValue in
                guard var updated = cycle else { return }
                updated.cadence = newValue
                cycle = updated
                onCommit()
            }
        )
    }

    /// Debounces `commitCost()` behind the last keystroke — each commit
    /// re-encodes and writes the *entire* cycles dictionary to `UserDefaults`
    /// (`SubscriptionCycleStore.set`'s read-modify-write), so committing on
    /// every keystroke turned typing a cost into a burst of full JSON
    /// serializations and disk writes. `onSubmit` still commits immediately.
    private func scheduleCostCommit() {
        costCommitTask?.cancel()
        costCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commitCost()
        }
    }

    /// Blank clears the cost rather than storing zero — "I did not say" and
    /// "it is free" are different claims, and only one of them is the user's.
    ///
    /// Text that isn't blank but also isn't a valid decimal (a locale comma
    /// separator, a stray character mid-edit) is a third case, and the one
    /// that used to be silently conflated with "I did not say": `Decimal(string:)`
    /// returns nil for that too, which then overwrote a previously-valid cost
    /// with nil on every keystroke of an in-progress edit. Only a successful
    /// parse or an explicit blank commits; unparsable text leaves the stored
    /// value untouched while the field keeps showing exactly what was typed.
    private func commitCost() {
        guard var updated = cycle else { return }
        let trimmed = costText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")

        if trimmed.isEmpty {
            guard updated.cost != nil else { return }
            updated.cost = nil
            cycle = updated
            onCommit()
            return
        }

        guard let parsed = Decimal(string: trimmed) else { return }
        guard updated.cost != parsed else { return }
        updated.cost = parsed
        cycle = updated
        onCommit()
    }
}
