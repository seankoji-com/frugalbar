import Testing
import Foundation
@testable import QuotaBarCore

/// A one-way flag a notification observer can set from its block without
/// capturing a mutable local (which the Swift 6 language mode rejects in a
/// `@Sendable` closure).
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

/// The workspace store is the identity layer for multi-workspace OpenCode Go:
/// a rename or a reorder must never move a credential or a reading, and the
/// legacy single-workspace setup must survive without re-entering a key.
///
/// Serialized: every test reads and writes the same preference key.
@Suite("OpenCode Go workspaces", .serialized)
struct OpenCodeGoWorkspaceTests {

    private func clear() {
        CredentialStore.preferences.removeObject(forKey: OpenCodeGoWorkspaceStore.defaultsKey)
    }

    // MARK: - Identity

    @Test("the legacy workspace keeps the vendor's credential label and the CLI fallback")
    func legacyKeepsVendorCredentialLabel() {
        let legacy = OpenCodeGoWorkspaceStore.legacy
        // The label is the pre-workspace `opencode` item, so migration never
        // moves the secret and the CLI auth.json fallback still applies.
        #expect(legacy.credentialLabel == VendorIdentifier.opencode.rawValue)
        #expect(legacy.instanceID == "opencode-go:legacy")
        #expect(legacy.name == VendorIdentifier.opencode.displayName)
    }

    @Test("a rename never changes the instance key or the credential label")
    func renamePreservesIdentity() {
        var workspace = OpenCodeGoWorkspace(name: "alpha")
        let idBefore = workspace.instanceID
        let labelBefore = workspace.credentialLabel

        workspace.name = "renamed"

        #expect(workspace.instanceID == idBefore)
        #expect(workspace.credentialLabel == labelBefore)
        // The identity is namespaced, never the bare vendor raw value, so two
        // workspaces can never collide with each other or with a vendor.
        #expect(workspace.instanceID.hasPrefix(OpenCodeGoWorkspaceStore.instancePrefix))
    }

    @Test("two workspaces never share an instance key or a credential label")
    func workspacesAreDistinct() {
        let a = OpenCodeGoWorkspace(name: "alpha")
        let b = OpenCodeGoWorkspace(name: "alpha")   // same name, different identity
        #expect(a.instanceID != b.instanceID)
        #expect(a.credentialLabel != b.credentialLabel)
        // Neither may sit on the legacy item, or they would overwrite the
        // user's existing single-workspace key.
        #expect(a.credentialLabel != VendorIdentifier.opencode.rawValue)
        #expect(b.credentialLabel != VendorIdentifier.opencode.rawValue)
    }

    @Test("moved swaps two positions and leaves every other entry alone")
    func movedReorders() {
        let a = OpenCodeGoWorkspace(id: "a", name: "A")
        let b = OpenCodeGoWorkspace(id: "b", name: "B")
        let c = OpenCodeGoWorkspace(id: "c", name: "C")

        #expect(OpenCodeGoWorkspaceStore.moved([a, b, c], id: "a", by: 1).map(\.id) == ["b", "a", "c"])
        #expect(OpenCodeGoWorkspaceStore.moved([a, b, c], id: "c", by: -1).map(\.id) == ["a", "c", "b"])
        // Out of bounds and unknown ids are no-ops, not crashes.
        #expect(OpenCodeGoWorkspaceStore.moved([a, b, c], id: "a", by: -1).map(\.id) == ["a", "b", "c"])
        #expect(OpenCodeGoWorkspaceStore.moved([a, b, c], id: "c", by: 1).map(\.id) == ["a", "b", "c"])
        #expect(OpenCodeGoWorkspaceStore.moved([a, b, c], id: "zzz", by: 1).map(\.id) == ["a", "b", "c"])
        // Reordering is display order only: identity and credential survive.
        #expect(OpenCodeGoWorkspaceStore.moved([a, b, c], id: "a", by: 1).map(\.instanceID).contains(a.instanceID))
    }

    // MARK: - Migration and the read path

    @Test("resolved() seeds the legacy workspace without writing to preferences")
    func resolvedSeedsLegacyWithoutWriting() {
        clear()
        defer { clear() }

        #expect(OpenCodeGoWorkspaceStore.all().isEmpty)
        #expect(OpenCodeGoWorkspaceStore.resolved().map(\.id) == [OpenCodeGoWorkspaceStore.legacyID])
        // Reading must not write: a poll calls this at the top of every fetch,
        // and a write there would post a preference change and re-trigger a poll.
        #expect(OpenCodeGoWorkspaceStore.all().isEmpty)
    }

    @Test("persistLegacyIfNeeded writes once and never resurrects a removed workspace")
    func persistLegacyIsIdempotent() {
        clear()
        defer { clear() }

        #expect(OpenCodeGoWorkspaceStore.persistLegacyIfNeeded() == true)
        #expect(OpenCodeGoWorkspaceStore.all().map(\.id) == [OpenCodeGoWorkspaceStore.legacyID])
        // Already stored: a second call is a no-op.
        #expect(OpenCodeGoWorkspaceStore.persistLegacyIfNeeded() == false)

        // A user who keeps another workspace and drops the legacy one must not
        // have it silently re-added on the next launch.
        let other = OpenCodeGoWorkspace(name: "beta")
        OpenCodeGoWorkspaceStore.set([other])
        #expect(OpenCodeGoWorkspaceStore.persistLegacyIfNeeded() == false)
        #expect(OpenCodeGoWorkspaceStore.all().map(\.id) == [other.id])
    }

    @Test("nothing stored and a stored empty list are different answers")
    func missingListIsNotAStoredEmptyList() {
        clear()
        defer { clear() }

        // Nothing stored: the legacy workspace is what an install reads, and
        // the first launch writes it down.
        #expect(OpenCodeGoWorkspaceStore.stored() == nil)
        #expect(OpenCodeGoWorkspaceStore.all().isEmpty)
        #expect(OpenCodeGoWorkspaceStore.resolved().map(\.id) == [OpenCodeGoWorkspaceStore.legacyID])
        #expect(OpenCodeGoWorkspaceStore.persistLegacyIfNeeded() == true)
        #expect(OpenCodeGoWorkspaceStore.stored() != nil)
    }

    @Test("removing every workspace leaves it removed: an empty list is a decision")
    func storedEmptyListIsNotReseeded() {
        clear()
        defer { clear() }

        // What `removeWorkspace` writes when the last row goes.
        OpenCodeGoWorkspaceStore.set([])

        #expect(OpenCodeGoWorkspaceStore.stored()?.isEmpty == true)
        #expect(OpenCodeGoWorkspaceStore.all().isEmpty)
        // `resolved()` must NOT fall back to the legacy workspace here: that is
        // the bug that made a removed workspace reappear on the next poll, and
        // `persistLegacyIfNeeded()` write it back on the next launch.
        #expect(OpenCodeGoWorkspaceStore.resolved().isEmpty)
        #expect(OpenCodeGoWorkspaceStore.persistLegacyIfNeeded() == false)
        #expect(OpenCodeGoWorkspaceStore.stored()?.isEmpty == true)
    }

    // MARK: - Persistence carries no secret

    @Test("the workspace list round-trips and stores no key material")
    func persistenceCarriesNoSecret() throws {
        clear()
        defer { clear() }

        let workspace = OpenCodeGoWorkspace(name: "alpha")
        OpenCodeGoWorkspaceStore.set([OpenCodeGoWorkspaceStore.legacy, workspace])

        #expect(OpenCodeGoWorkspaceStore.all().map(\.id)
                == [OpenCodeGoWorkspaceStore.legacyID, workspace.id])

        // The stored form is exactly the identity fields. There is no `key`
        // field to leak, and a secret-shaped name is the only user data present.
        let data = try #require(
            CredentialStore.preferences.data(forKey: OpenCodeGoWorkspaceStore.defaultsKey))
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.count == 2)
        for object in objects {
            #expect(Set(object.keys) == ["id", "name", "isEnabled"])
        }
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("oc_live"))
    }

    @Test("set() posts a preference change so the app re-reads without waiting for a poll")
    func setPostsChangeNotification() {
        clear()
        defer { clear() }

        let flag = Flag()
        // Observed by the sender, not `object: nil`: this asserts that the
        // post is *this* store's, so a sibling suite posting the same
        // notification name cannot make it pass or fail.
        let token = NotificationCenter.default.addObserver(
            forName: .frugalbarProviderPreferencesDidChange,
            object: OpenCodeGoWorkspaceStore.changeSender, queue: nil) { _ in
            flag.set()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        OpenCodeGoWorkspaceStore.set([OpenCodeGoWorkspace(name: "alpha")])
        #expect(flag.value)
    }

    // MARK: - Name normalisation

    @Test("a blanked name falls back to the stored one, and a non-blank name is trimmed")
    func setNameNormalisation() {
        clear()
        defer { clear() }

        let workspace = OpenCodeGoWorkspace(name: "Go Alpha")
        OpenCodeGoWorkspaceStore.set([workspace])

        // What the rename field writes when it is cleared and Return pressed:
        // the row must not go blank.
        var blanked = workspace
        blanked.name = "   "
        OpenCodeGoWorkspaceStore.set([blanked])
        #expect(OpenCodeGoWorkspaceStore.all().map(\.name) == ["Go Alpha"])

        // A real rename still lands, without the surrounding whitespace.
        var renamed = workspace
        renamed.name = "  Go Alpha Two  "
        OpenCodeGoWorkspaceStore.set([renamed])
        #expect(OpenCodeGoWorkspaceStore.all().map(\.name) == ["Go Alpha Two"])

        // A workspace with no earlier name to restore is kept as it stands
        // rather than dropped or handed a label nobody wrote.
        let unnamed = OpenCodeGoWorkspace(name: "")
        OpenCodeGoWorkspaceStore.set([unnamed])
        #expect(OpenCodeGoWorkspaceStore.all().map(\.id) == [unnamed.id])
    }

    // MARK: - Instance key to vendor

    @Test("a stored key maps back to its vendor, and an unknown key to nil")
    func vendorForInstanceKey() {
        #expect(OpenCodeGoWorkspaceStore.vendor(forInstanceKey: "opencode-go:alpha") == .opencode)
        #expect(OpenCodeGoWorkspaceStore.vendor(forInstanceKey: VendorIdentifier.claude.rawValue) == .claude)
        #expect(OpenCodeGoWorkspaceStore.vendor(forInstanceKey: "no-such-vendor") == nil)
    }

    @Test("a stored key maps back to its workspace name, so two series are tellable apart")
    func displayNameForInstanceKey() {
        clear()
        defer { clear() }

        let alpha = OpenCodeGoWorkspace(name: "Go Alpha")
        let legacy = OpenCodeGoWorkspaceStore.legacy
        OpenCodeGoWorkspaceStore.set([legacy, alpha])

        #expect(OpenCodeGoWorkspaceStore.displayName(forInstanceKey: alpha.instanceID) == "Go Alpha")
        #expect(OpenCodeGoWorkspaceStore.displayName(forInstanceKey: legacy.instanceID) == legacy.name)
        // A bare vendor key, and a key no workspace claims, name no workspace:
        // the caller falls back to the vendor's own name.
        #expect(OpenCodeGoWorkspaceStore.displayName(forInstanceKey: VendorIdentifier.opencode.rawValue) == nil)
        #expect(OpenCodeGoWorkspaceStore.displayName(forInstanceKey: "opencode-go:gone") == nil)
    }
}
