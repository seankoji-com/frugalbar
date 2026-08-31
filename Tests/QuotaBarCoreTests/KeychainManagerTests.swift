import Testing
import Foundation
import Security
@testable import QuotaBarCore

/// Probes whether this process can use the login keychain at all.
enum KeychainAvailability {
    /// `false` only for -25308 (no unlocked keychain / no UI session).
    /// Every other failure — notably -34018 — reports `true` so the suite runs
    /// and fails loudly.
    static let isUsable: Bool = {
        let label = "quotabar-availability-probe"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.quotabar.probe",
            kSecAttrAccount as String: label,
            kSecValueData as String: Data("probe".utf8),
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        SecItemDelete(query as CFDictionary)
        if status == errSecInteractionNotAllowed {
            return false   // headless runner: skip
        }
        return true
    }()
}

/// There was no coverage of `KeychainManager` at all, which is how adding
/// `kSecUseDataProtectionKeychain` — an attribute that requires a signed,
/// entitled bundle and returns -34018 (`errSecMissingEntitlement`) from
/// `swift run` — broke every credential path while 81 tests stayed green.
///
/// Serialized because these cases share the login keychain.
///
/// Gated on an availability probe: a headless CI runner (launchd, no GUI
/// session) has no unlocked login keychain and refuses every write with
/// -25308 `errSecInteractionNotAllowed`. That is an environment limitation,
/// not a defect, so the suite skips there.
///
/// Crucially the probe only skips on -25308. `-34018`
/// (`errSecMissingEntitlement`) — the failure this suite exists to catch —
/// still runs and still fails, so the regression guard cannot be silently
/// disabled by an entitlement mistake.
@Suite("KeychainManager", .serialized, .enabled(if: KeychainAvailability.isUsable))
struct KeychainManagerTests {

    private let label = "quotabar-test-\(UUID().uuidString)"

    private func cleanup(_ label: String) {
        try? KeychainManager.shared.delete(label: label)
    }

    @Test("set then get round-trips the value")
    func roundTrip() throws {
        defer { cleanup(label) }
        try KeychainManager.shared.set(key: "s3cret-value", label: label)
        #expect(try KeychainManager.shared.get(label: label) == "s3cret-value")
    }

    /// The regression guard: this fails with `KeychainError.unknown(-34018)`
    /// the moment an attribute requiring an entitlement is reintroduced.
    @Test("storing a credential works from an unsigned test binary")
    func worksWithoutCodeSigningEntitlement() throws {
        defer { cleanup(label) }
        do {
            try KeychainManager.shared.set(key: "v", label: label)
        } catch let KeychainError.unknown(status) {
            Issue.record("""
                SecItemAdd failed with OSStatus \(status). \
                -34018 means an attribute requiring a signed, entitled bundle \
                (e.g. kSecUseDataProtectionKeychain) was added — that breaks \
                the documented `swift run` path entirely.
                """)
        }
    }

    @Test("set overwrites an existing value rather than duplicating it")
    func overwrite() throws {
        defer { cleanup(label) }
        try KeychainManager.shared.set(key: "first", label: label)
        try KeychainManager.shared.set(key: "second", label: label)
        #expect(try KeychainManager.shared.get(label: label) == "second")
    }

    @Test("delete removes the item and get then reports itemNotFound")
    func deleteRemoves() throws {
        try KeychainManager.shared.set(key: "v", label: label)
        try KeychainManager.shared.delete(label: label)
        #expect(throws: KeychainError.self) {
            _ = try KeychainManager.shared.get(label: label)
        }
        do {
            _ = try KeychainManager.shared.get(label: label)
            Issue.record("expected itemNotFound after delete")
        } catch KeychainError.itemNotFound {
            // expected
        } catch {
            Issue.record("expected itemNotFound, got \(error)")
        }
    }

    @Test("deleting an absent item is not an error")
    func deleteAbsentIsIdempotent() throws {
        try KeychainManager.shared.delete(label: "quotabar-never-written-\(UUID().uuidString)")
    }

    @Test("values round-trip unicode and long tokens intact")
    func unicodeAndLength() throws {
        defer { cleanup(label) }
        let value = "ghp_" + String(repeating: "aA0", count: 100) + "—✓"
        try KeychainManager.shared.set(key: value, label: label)
        #expect(try KeychainManager.shared.get(label: label) == value)
    }

    @Test("distinct labels do not collide")
    func labelsAreIndependent() throws {
        let a = "\(label)-a", b = "\(label)-b"
        defer { cleanup(a); cleanup(b) }
        try KeychainManager.shared.set(key: "alpha", label: a)
        try KeychainManager.shared.set(key: "beta", label: b)
        #expect(try KeychainManager.shared.get(label: a) == "alpha")
        #expect(try KeychainManager.shared.get(label: b) == "beta")
    }

    @Test("CredentialCache.ghToken resolves once within the TTL, then again after it expires")
    func credentialCacheHitAndExpiry() {
        // A fresh instance, not .shared — this exercises the cache/expiry
        // logic in isolation rather than the process-wide gh-token slot.
        let cache = CredentialStore.CredentialCache()
        let resolveCount = InvocationCounter()
        let epoch = Date(timeIntervalSince1970: 0)

        let first = cache.ghToken(now: epoch) {
            resolveCount.increment()
            return "token-a"
        }
        #expect(first == "token-a")
        #expect(resolveCount.value == 1)

        // Still within the TTL: the cached token is returned, resolve() is
        // never called again.
        let stillCached = cache.ghToken(now: epoch.addingTimeInterval(CredentialStore.CredentialCache.ghTokenTTL - 1)) {
            resolveCount.increment()
            return "token-b"
        }
        #expect(stillCached == "token-a")
        #expect(resolveCount.value == 1)

        // Past the TTL: resolve() runs again and its fresh result replaces
        // the expired entry.
        let afterExpiry = cache.ghToken(now: epoch.addingTimeInterval(CredentialStore.CredentialCache.ghTokenTTL + 1)) {
            resolveCount.increment()
            return "token-b"
        }
        #expect(afterExpiry == "token-b")
        #expect(resolveCount.value == 2)
    }
}

/// Counts invocations without touching a wall clock — safe for asserting
/// "resolved exactly once" style expectations.
private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
    }
}
