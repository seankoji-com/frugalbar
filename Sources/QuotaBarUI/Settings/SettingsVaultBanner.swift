import QuotaBarCore
import SwiftUI

/// Pure merge rule for applying asynchronously loaded Keychain values into
/// Settings state without clobbering edits the user has already typed.
enum SettingsCredentialMerge {
    struct Result: Equatable {
        let loaded: [VendorIdentifier: String]
        let entered: [VendorIdentifier: String]
        let loadedGeminiClientID: String
        let enteredGeminiClientID: String
    }

    static func merge(
        slots: [VendorIdentifier],
        currentLoaded: [VendorIdentifier: String],
        currentEntered: [VendorIdentifier: String],
        freshLoaded: [VendorIdentifier: String],
        currentLoadedGeminiClientID: String,
        currentEnteredGeminiClientID: String,
        freshGeminiClientID: String,
        unreadableSlots: Set<VendorIdentifier> = [],
        geminiClientIDUnreadable: Bool = false
    ) -> Result {
        var nextLoaded = currentLoaded
        var nextEntered = currentEntered
        // A slot the vault cannot read has no fresh value, not an empty one.
        // Taking "" as its saved baseline made a field the user had cleared
        // look untouched, so unlocking later restored the old secret.
        for id in slots where !unreadableSlots.contains(id) {
            let previousLoaded = currentLoaded[id] ?? ""
            let previousEntered = currentEntered[id] ?? ""
            let isDirty = previousEntered != previousLoaded
            let fresh = freshLoaded[id] ?? ""
            nextLoaded[id] = fresh
            if !isDirty {
                nextEntered[id] = fresh
            }
        }
        let geminiDirty = currentEnteredGeminiClientID != currentLoadedGeminiClientID
        if geminiClientIDUnreadable {
            return Result(
                loaded: nextLoaded,
                entered: nextEntered,
                loadedGeminiClientID: currentLoadedGeminiClientID,
                enteredGeminiClientID: currentEnteredGeminiClientID
            )
        }
        return Result(
            loaded: nextLoaded,
            entered: nextEntered,
            loadedGeminiClientID: freshGeminiClientID,
            enteredGeminiClientID: geminiDirty ? currentEnteredGeminiClientID : freshGeminiClientID
        )
    }
}

/// Whether a vault status change reported while Settings is open should also
/// reload the credential fields, sources and workspace key indicators, not
/// just the banner. A background unlock (a popover refresh) or a migrated
/// legacy item changes what the fields should show; a deferred session write
/// alone does not, and reloading sources for it would re-run discovery on
/// every Gemini renewal.
enum SettingsVaultReload {
    static func shouldReloadCredentials(
        previous: VaultStatusSnapshot,
        current: VaultStatusSnapshot
    ) -> Bool {
        previous.state != current.state
            || previous.pendingLegacyKeys != current.pendingLegacyKeys
            || previous.pendingLegacySyncKeys != current.pendingLegacySyncKeys
    }

    /// The saved value Settings should show for `label`: the cached value,
    /// "" on confirmed absence, or nil when the vault cannot say. Outside a
    /// readable state, for a legacy item still pending migration, or after a
    /// failed legacy scan, a missing cache entry means "unknown", never "no
    /// saved value".
    static func freshValue(label: String, cached: String?, in status: VaultStatusSnapshot) -> String? {
        switch status.state {
        case .loaded, .empty:
            if status.pendingLegacyKeys.contains(label) { return nil }
            if let cached { return cached }
            return status.legacyScanSucceeded ? "" : nil
        default:
            return nil
        }
    }
}

/// Presentation model for the inline Keychain vault banner in Settings.
struct SettingsVaultBannerPresentation: Equatable {
    enum Kind: Equatable {
        case corrupt
        case locked
        case pendingWrites
    }

    let kind: Kind
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String

    static func make(from status: VaultStatusSnapshot) -> SettingsVaultBannerPresentation? {
        if status.isCorrupt {
            return SettingsVaultBannerPresentation(
                kind: .corrupt,
                icon: "exclamationmark.triangle.fill",
                title: "Saved Keychain vault could not be read",
                detail: "FrugalBar kept the existing vault intact so no credentials are overwritten.",
                actionTitle: "Retry"
            )
        }
        if status.needsUnlock {
            let title = status.isLockedOrDenied
                ? "Keychain is locked"
                : "Some saved credentials need Keychain access"
            return SettingsVaultBannerPresentation(
                kind: .locked,
                icon: "lock.fill",
                title: title,
                detail: "Unlock to load saved credentials and resume sync.",
                actionTitle: "Unlock Keychain"
            )
        }
        if status.hasPendingWrites {
            return SettingsVaultBannerPresentation(
                kind: .pendingWrites,
                icon: "arrow.triangle.2.circlepath.circle.fill",
                title: "Pending credential updates",
                detail: "Renewed credentials are active in memory and ready to save to Keychain.",
                actionTitle: "Save pending changes"
            )
        }
        return nil
    }
}

struct SettingsVaultBannerView: View {
    let presentation: SettingsVaultBannerPresentation
    let isBusy: Bool
    let onAction: () -> Void

    private var tint: Color {
        switch presentation.kind {
        case .corrupt: .red
        case .locked: .orange
        case .pendingWrites: .blue
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: presentation.icon)
                .foregroundStyle(tint)
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.callout.weight(.semibold))
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.systemSecondaryText)
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Button(presentation.actionTitle, action: onAction)
                .disabled(isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}
