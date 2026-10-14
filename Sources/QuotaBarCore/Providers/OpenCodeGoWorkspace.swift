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

    /// The name an instance key belongs to, from the workspace list, or `nil`
    /// for a key no workspace claims — a bare vendor key, or one the user has
    /// removed.
    ///
    /// The desktop widget draws a series from stored readings with no snapshot
    /// in hand; `vendor(forInstanceKey:)` folds every `opencode-go:` key to the
    /// same vendor, so without this two workspaces would carry the identical
    /// legend label and the identical spoken entry. Callers fall back to the
    /// vendor's name when this is nil.
    public static func displayName(forInstanceKey key: String) -> String? {
        resolved().first { $0.instanceID == key }?.name
    }

    /// A workspace instance key's place in the user's list, or `nil` for a key
    /// the list does not name. Lets a surface that holds only stored keys (the
    /// History overview, the widget before its first poll) draw workspaces in
    /// the order the user arranged rather than in key order, which is a UUID's.
    public static func position(
        ofInstanceKey key: String,
        in workspaces: [OpenCodeGoWorkspace] = resolved()
    ) -> Int? {
        workspaces.firstIndex { $0.instanceID == key }
    }

    /// The stored workspace list, or `nil` when nothing has been stored yet.
    ///
    /// The distinction is the whole point: an install that has never stored a
    /// list seeds the legacy workspace, while a user who removed every
    /// workspace has stored an *empty* list and must not have one put back.
    /// `all()` flattens the two for the many callers that only read.
    ///
    /// `defaults` is the shared suite in the app; a test passes a randomised
    /// suite of its own so it never reads or writes the shared one.
    public static func stored(in defaults: UserDefaults = CredentialStore.preferences) -> [OpenCodeGoWorkspace]? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode([OpenCodeGoWorkspace].self, from: data)
    }

    /// Every configured workspace, in display order. Empty when none has been
    /// stored, and empty when the user has removed all of them — a stored
    /// empty list is a decision, not a missing value.
    public static func all(in defaults: UserDefaults = CredentialStore.preferences) -> [OpenCodeGoWorkspace] {
        stored(in: defaults) ?? []
    }

    /// Writes the list and tells the running app to re-read it, so adding,
    /// renaming, disabling or removing a workspace takes effect on the next
    /// refresh rather than on the next two-minute poll.
    ///
    /// Names are normalised here, on the single write path, rather than in the
    /// form that produced them: a cleared rename field would otherwise store an
    /// empty name, and the row, the popover and the widget legend would all
    /// draw a blank label with nothing on screen explaining it. A blank name
    /// falls back to the one already stored for that workspace id, so an
    /// accidental select-all-delete leaves the workspace named; a non-blank one
    /// is trimmed. That is the same rule `SettingsView.addWorkspace` applies
    /// when it refuses to create a workspace from an empty field.
    public static func set(
        _ workspaces: [OpenCodeGoWorkspace],
        in defaults: UserDefaults = CredentialStore.preferences
    ) {
        let previous = stored(in: defaults) ?? []
        let normalised = workspaces.map { workspace -> OpenCodeGoWorkspace in
            var copy = workspace
            let trimmed = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                copy.name = previous.first { $0.id == workspace.id }?.name ?? workspace.name
            } else {
                copy.name = trimmed
            }
            return copy
        }
        guard let data = try? JSONEncoder().encode(normalised) else { return }
        defaults.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(
            name: .frugalbarProviderPreferencesDidChange, object: changeSender)
    }

    /// The `object` on this store's posts — the workspace list is a provider
    /// preference, but a different writer from the display preferences, and a
    /// listener counting one must not count the other. See
    /// `Notification.Name.frugalbarProviderPreferencesDidChange`.
    ///
    /// A reference instance, not a string: `NotificationCenter` matches a
    /// block observer's `object` by identity.
    nonisolated(unsafe) public static let changeSender = NSObject()

    /// The workspace list to read, seeding the legacy workspace in memory only
    /// when nothing has ever been stored — without writing anything.
    ///
    /// This is the read path the fetch and every UI surface use: it never
    /// touches the preference file, so a poll cannot trigger a preference
    /// change (and the refresh such a change posts). `persistLegacyIfNeeded()`
    /// is what makes the seeded one durable, called once at launch.
    ///
    /// A stored empty list is returned as it is. Removing every workspace is a
    /// choice, and re-seeding would undo it on the very next poll.
    public static func resolved(in defaults: UserDefaults = CredentialStore.preferences) -> [OpenCodeGoWorkspace] {
        stored(in: defaults) ?? [legacy]
    }

    /// Seeds the legacy workspace on a first run, and only then.
    ///
    /// Idempotent: once a list is stored it is left alone — including an empty
    /// one, so a user who removed every workspace does not get one
    /// resurrected. Returns whether it wrote.
    @discardableResult
    public static func persistLegacyIfNeeded() -> Bool {
        guard stored() == nil else { return false }
        set([legacy])
        return true
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

    /// The list after a drag: the rows at `source` land before the row that
    /// was at `destination`, with the meaning `List.onMove` gives both. Like
    /// `moved(_:id:by:)` this only reorders; every workspace keeps its id,
    /// name, credential and history.
    public static func moved(
        _ workspaces: [OpenCodeGoWorkspace],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [OpenCodeGoWorkspace] {
        let valid = source.filter { workspaces.indices.contains($0) }
        guard !valid.isEmpty else { return workspaces }
        let moving = valid.map { workspaces[$0] }
        var remaining = workspaces
        for index in valid.sorted(by: >) { remaining.remove(at: index) }
        // Rows taken out above the destination shift it up by one each.
        let insertAt = min(max(destination - valid.filter { $0 < destination }.count, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
    }
}
