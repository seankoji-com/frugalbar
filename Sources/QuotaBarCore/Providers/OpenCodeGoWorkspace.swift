import Foundation

/// One named OpenCode Go subscription workspace.
///
/// A "workspace" here is a separate OpenCode Go subscription under the same
/// OpenCode account — `opencode go alpha`, `opencode go beta` — each with its
/// own API key and its own rolling / weekly / monthly quota. It is not a local
/// project directory and not a model catalog entry.
///
/// `id` is the stable identity. It is generated once when the workspace is
/// added and is never derived from `name`, so renaming or reordering a
/// workspace keeps its credential and its recorded history, and a name change
/// can never silently point one workspace's key at another's readings.
public struct OpenCodeGoWorkspace: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var name: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
    }

    /// The stable key a workspace's readings, cache entry, spawn and history
    /// rows are filed under.
    ///
    /// Namespaced rather than bare so it can never collide with a
    /// `VendorIdentifier` raw value, and stable rather than derived from `name`
    /// so a rename is not a new identity.
    public var instanceID: String { OpenCodeGoWorkspaceStore.instanceID(for: self) }

    /// The macOS Keychain label this workspace's key is stored under. Two
    /// workspaces never share a label.
    public var credentialLabel: String { OpenCodeGoWorkspaceStore.credentialLabel(for: self) }
}

/// Storage for the user's OpenCode Go workspaces.
///
/// Lives in the shared preference suite (never `UserDefaults.standard`, whose
/// identity is the process name for an unbundled executable) and, for
/// credentials, in our own Keychain service — never in the preference file.
public enum OpenCodeGoWorkspaceStore {

    /// The workspace every install has.
    ///
    /// A user who configured the single legacy `opencode` key before
    /// workspaces existed keeps that key, and the CLI `auth.json` fallback,
    /// under this workspace: its credential label is the legacy vendor label,
    /// so migration never has to move a secret and never asks the user to
    /// re-enter one. It is also what makes an unconfigured install behave
    /// exactly as it did before this feature existed.
    public static let legacyID = "legacy"

    public static var legacy: OpenCodeGoWorkspace {
        // Deliberately the vendor's own display name, not "OpenCode Go": the
        // legacy workspace is the row this app has always drawn, and its name
        // must not change under a user who never added a second one.
        OpenCodeGoWorkspace(id: legacyID, name: VendorIdentifier.opencode.displayName)
    }

    /// Prefix of every workspace instance key. Namespaced so a workspace key
    /// is never mistaken for a bare vendor raw value.
    public static let instancePrefix = "opencode-go:"

    static let defaultsKey = "QuotaBarOpenCodeGoWorkspaces"

    public static func instanceID(for workspace: OpenCodeGoWorkspace) -> String {
        instancePrefix + workspace.id
    }

    /// The legacy workspace keeps the pre-existing `opencode` Keychain item so
    /// its credential survives migration untouched; every other workspace gets
    /// its own label.
    public static func credentialLabel(for workspace: OpenCodeGoWorkspace) -> String {
        workspace.id == legacyID ? VendorIdentifier.opencode.rawValue : instanceID(for: workspace)
    }

    /// Names the vendor an instance key belongs to, or `nil` when it is not a
    /// workspace key at all.
    ///
    /// Used to read back a history row's vendor without a snapshot in hand — a
    /// widget series or a history query that has only the stored key. The
    /// returned value is the shared vendor; the key itself is what keeps two
    /// workspaces apart.
    public static func vendor(forInstanceKey key: String) -> VendorIdentifier? {
        key.hasPrefix(instancePrefix) ? .opencode : VendorIdentifier(rawValue: key)
    }

    /// Every configured workspace, in display order. Empty when none has been
    /// stored yet — `ensureMigrated()` is what guarantees at least the legacy
    /// one exists.
    public static func all() -> [OpenCodeGoWorkspace] {
        guard let data = CredentialStore.preferences.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([OpenCodeGoWorkspace].self, from: data)
        else { return [] }
        return list
    }

    /// Writes the list and tells the running app to re-read it, so adding,
    /// renaming, disabling or removing a workspace takes effect on the next
    /// refresh rather than on the next two-minute poll.
    public static func set(_ workspaces: [OpenCodeGoWorkspace]) {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        CredentialStore.preferences.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: .frugalbarProviderPreferencesDidChange, object: nil)
    }

    /// The workspace list, guaranteeing the legacy workspace exists — without
    /// writing anything.
    ///
    /// This is the read path the fetch and every UI surface use: it never
    /// touches the preference file, so a poll cannot trigger a preference
    /// change (and the refresh such a change posts). `persistLegacyIfNeeded()`
    /// is what makes the returned list durable, called once at launch.
    public static func resolved() -> [OpenCodeGoWorkspace] {
        let existing = all()
        return existing.isEmpty ? [legacy] : existing
    }

    /// Seeds the legacy workspace on a first run, and only then.
    ///
    /// Idempotent: once a list is stored it is left alone, so a user who
    /// removed the legacy workspace does not get it resurrected. Returns
    /// whether it wrote.
    @discardableResult
    public static func persistLegacyIfNeeded() -> Bool {
        guard all().isEmpty else { return false }
        set([legacy])
        return true
    }

    /// The workspace list, guaranteeing the legacy workspace exists.
    ///
    /// Idempotent: once a list is stored it is returned unchanged, so a user
    /// who removed the legacy workspace does not get it resurrected.
    public static func ensureMigrated() -> [OpenCodeGoWorkspace] {
        let existing = all()
        guard existing.isEmpty else { return existing }
        let seeded = [legacy]
        set(seeded)
        return seeded
    }

    /// Persists a key for one workspace. The key only ever reaches the
    /// Keychain; it is never written to the preference file.
    public static func setCredential(_ key: String, for workspace: OpenCodeGoWorkspace) throws {
        try KeychainManager.shared.set(key: key, label: workspace.credentialLabel)
    }

    public static func deleteCredential(for workspace: OpenCodeGoWorkspace) throws {
        try KeychainManager.shared.delete(label: workspace.credentialLabel)
    }

    /// Whether the Keychain already holds a key for this workspace. Never reads
    /// the value out.
    public static func hasCredential(for workspace: OpenCodeGoWorkspace) -> Bool {
        (try? KeychainManager.shared.get(label: workspace.credentialLabel))?.isEmpty == false
    }

    /// Moves a workspace to a new position, preserving order for every other
    /// entry. Ordering is display order only — identity, credential and
    /// history are untouched.
    public static func moved(_ workspaces: [OpenCodeGoWorkspace], id: String, by offset: Int) -> [OpenCodeGoWorkspace] {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return workspaces }
        let target = index + offset
        guard workspaces.indices.contains(target) else { return workspaces }
        var copy = workspaces
        copy.swapAt(index, target)
        return copy
    }
}
