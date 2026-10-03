import Testing
import Foundation
@testable import QuotaBarCore

/// Serialized: every test here reads and writes the same preference keys.
@Suite("Provider display preferences", .serialized)
struct ProviderPreferencesTests {

    private let keys = [
        CredentialStore.providerOrderDefaultsKey,
        CredentialStore.hiddenProvidersDefaultsKey,
        CredentialStore.providerOrderingDefaultsKey,
    ]

    private func clear() {
        for key in keys { CredentialStore.preferences.removeObject(forKey: key) }
    }

    // MARK: Pure resolution

    @Test("a complete stored order is returned as stored")
    func storedOrderWins() {
        let stored = ProviderDisplayPreferences.defaultOrder.reversed().map(\.rawValue)
        #expect(ProviderDisplayPreferences.resolveOrder(stored: stored)
                == Array(ProviderDisplayPreferences.defaultOrder.reversed()))
    }

    /// The failure this guards: a provider added in a later release never
    /// appearing for anyone who had ever rearranged the list.
    @Test("vendors the stored list does not name are appended in canonical order")
    func missingVendorsAreAppended() {
        let resolved = ProviderDisplayPreferences.resolveOrder(stored: ["kiro", "claude"])
        #expect(resolved.prefix(2) == [.kiro, .claude])
        let rest = ProviderDisplayPreferences.defaultOrder.filter { $0 != .kiro && $0 != .claude }
        #expect(Array(resolved.dropFirst(2)) == rest)
        #expect(Set(resolved) == Set(VendorIdentifier.allCases))
    }

    @Test("unknown raw values and duplicates are dropped, not fatal")
    func junkIsDropped() {
        let resolved = ProviderDisplayPreferences.resolveOrder(stored: ["grok", "no-such-vendor", "grok", "openai"])
        #expect(resolved.prefix(2) == [.grok, .openai])
        #expect(resolved.count == VendorIdentifier.allCases.count)
        #expect(ProviderDisplayPreferences.resolveOrder(stored: nil) == ProviderDisplayPreferences.defaultOrder)
        #expect(ProviderDisplayPreferences.resolveOrder(stored: []) == ProviderDisplayPreferences.defaultOrder)
    }

    @Test("the default order names every vendor exactly once")
    func defaultOrderIsComplete() {
        #expect(Set(ProviderDisplayPreferences.defaultOrder) == Set(VendorIdentifier.allCases))
        #expect(ProviderDisplayPreferences.defaultOrder.count == VendorIdentifier.allCases.count)
    }

    @Test("hidden decoding drops unknown vendors")
    func hiddenDecoding() {
        #expect(ProviderDisplayPreferences.resolveHidden(stored: ["kiro", "bogus"]) == [.kiro])
        #expect(ProviderDisplayPreferences.resolveHidden(stored: nil).isEmpty)
    }

    @Test("ordering decodes tolerantly")
    func orderingDecoding() {
        #expect(ProviderOrdering(stored: nil) == .automatic)
        #expect(ProviderOrdering(stored: "sideways") == .automatic)
        #expect(ProviderOrdering(stored: "custom") == .custom)
    }

    @Test("visibleOrder keeps the order and drops hidden vendors; rank follows the list")
    func visibleOrderAndRank() {
        let prefs = ProviderDisplayPreferences(order: [.kiro, .claude, .grok], hidden: [.claude])
        #expect(prefs.visibleOrder == [.kiro, .grok])
        #expect(prefs.rank(of: .grok) == 2)
        #expect(prefs.rank(of: .openai) == 3)
    }

    // MARK: Storage

    @Test("writes land in the app's suite, not UserDefaults.standard")
    func writesGoToTheNamedSuite() {
        clear()
        defer { clear() }
        CredentialStore.hiddenProviders = [.grok]
        #expect(CredentialStore.preferences.stringArray(forKey: CredentialStore.hiddenProvidersDefaultsKey) == ["grok"])
        #expect(UserDefaults.standard.object(forKey: CredentialStore.hiddenProvidersDefaultsKey) == nil)
    }

    @Test("order, hidden set and ordering round-trip and default sensibly")
    func roundTrip() {
        clear()
        defer { clear() }
        #expect(CredentialStore.providerOrder == ProviderDisplayPreferences.defaultOrder)
        #expect(CredentialStore.hiddenProviders.isEmpty)
        #expect(CredentialStore.providerOrdering == .automatic)

        CredentialStore.providerOrder = [.openai, .claude]
        CredentialStore.hiddenProviders = [.githubGraphql, .devpass]
        CredentialStore.providerOrdering = .custom

        #expect(CredentialStore.providerOrder.prefix(2) == [.openai, .claude])
        #expect(CredentialStore.providerOrder.count == VendorIdentifier.allCases.count)
        #expect(CredentialStore.hiddenProviders == [.githubGraphql, .devpass])
        #expect(CredentialStore.providerOrdering == .custom)

        let combined = CredentialStore.providerDisplayPreferences
        #expect(combined.ordering == .custom)
        #expect(combined.order.prefix(2) == [.openai, .claude])
        #expect(combined.hidden == [.githubGraphql, .devpass])

        CredentialStore.resetProviderOrder()
        #expect(CredentialStore.providerOrder == ProviderDisplayPreferences.defaultOrder)
    }

    /// The running app relies on this to drop a hidden provider at once
    /// rather than on the next two-minute poll.
    @Test("every write posts the change notification")
    func writesPostNotification() async {
        clear()
        defer { clear() }
        let counter = NotificationCounter(name: .frugalbarProviderPreferencesDidChange)
        defer { counter.stop() }
        CredentialStore.providerOrder = [.claude]
        CredentialStore.hiddenProviders = [.claude]
        CredentialStore.providerOrdering = .custom
        CredentialStore.resetProviderOrder()
        #expect(counter.count == 4)
    }
}

/// Counts synchronous posts of one notification on the default center.
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var token: NSObjectProtocol?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    init(name: Notification.Name) {
        // No queue: delivered synchronously on the posting thread, so the
        // count is final by the time the setter returns.
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self._count += 1
            self.lock.unlock()
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
