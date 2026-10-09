import Foundation

/// How the popover orders its provider rows.
public enum ProviderOrdering: String, Sendable, CaseIterable, Codable {
    /// Whichever long window turns over soonest comes first; a vendor that
    /// published no window keeps its list position; a spent vendor goes
    /// last. See `QuotaManager.sortedSnapshots()`.
    case automatic
    /// Exactly the order arranged in Preferences → Providers, nothing more.
    case custom

    /// Missing or unrecognised stored values fall back to `.automatic`.
    public init(stored raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .automatic
    }
}

/// The user's choices about which providers appear, and in what order.
///
/// Read once per poll by `QuotaManager`, so a change made mid-fetch cannot
/// leave half the pass on the old list. A hidden provider is not polled at
/// all: it is absent from the popover, the menu bar summary, the advice, the
/// desktop widget, the history recorder and the event sources alike. Its
/// credential stays where it was, so showing it again costs nothing.
public struct ProviderDisplayPreferences: Sendable, Equatable {
    public var ordering: ProviderOrdering
    /// Every vendor, hidden ones included, in display order.
    public var order: [VendorIdentifier]
    public var hidden: Set<VendorIdentifier>

    public init(
        ordering: ProviderOrdering = .automatic,
        order: [VendorIdentifier] = ProviderDisplayPreferences.defaultOrder,
        hidden: Set<VendorIdentifier> = []
    ) {
        self.ordering = ordering
        self.order = order
        self.hidden = hidden
    }

    /// The order a fresh install shows, and the tie-break the automatic sort
    /// falls back to: subscriptions first, then spend, then developer limits.
    public static let defaultOrder: [VendorIdentifier] = [
        .claude, .openai, .gemini, .copilot, .opencode,
        .openrouter, .deepseek, .grok, .kiro, .devpass,
        .commandcode, .clinepass,
        .githubRest, .githubGraphql,
    ]

    public static let `default` = ProviderDisplayPreferences()

    /// The vendors to poll and draw, in order.
    public var visibleOrder: [VendorIdentifier] {
        order.filter { !hidden.contains($0) }
    }

    /// A vendor's position in `order`; one past the end for a vendor the
    /// list somehow does not name, so it sorts after every named one.
    public func rank(of vendor: VendorIdentifier) -> Int {
        order.firstIndex(of: vendor) ?? order.count
    }

    /// Turns a stored list into a complete order.
    ///
    /// Unknown raw values (a provider removed in a later release) and
    /// duplicates are dropped rather than failing the whole list. Any vendor
    /// the stored list does not name — one added in a later release — is
    /// appended in `canonical` order, so a new provider shows up at the end
    /// instead of vanishing until the user rebuilds the list by hand.
    public static func resolveOrder(
        stored: [String]?,
        canonical: [VendorIdentifier] = defaultOrder
    ) -> [VendorIdentifier] {
        var seen = Set<VendorIdentifier>()
        var result: [VendorIdentifier] = []
        for raw in stored ?? [] {
            guard let vendor = VendorIdentifier(rawValue: raw), seen.insert(vendor).inserted else { continue }
            result.append(vendor)
        }
        for vendor in canonical where seen.insert(vendor).inserted {
            result.append(vendor)
        }
        return result
    }

    /// Decodes a stored hidden list, dropping unknown raw values.
    public static func resolveHidden(stored: [String]?) -> Set<VendorIdentifier> {
        Set((stored ?? []).compactMap(VendorIdentifier.init(rawValue:)))
    }
}

extension Notification.Name {
    /// Posted on `NotificationCenter.default` after any provider display
    /// preference is written, so the running app can drop a hidden provider
    /// and fetch a newly shown one without waiting for the next poll.
    public static let frugalbarProviderPreferencesDidChange =
        Notification.Name("FrugalBarProviderPreferencesDidChange")
}

// MARK: - Storage

extension CredentialStore {

    /// `[String]` of `VendorIdentifier.rawValue`, hidden vendors included.
    public static let providerOrderDefaultsKey = "QuotaBarProviderOrder"
    /// `[String]` of `VendorIdentifier.rawValue`.
    public static let hiddenProvidersDefaultsKey = "QuotaBarHiddenProviders"
    /// `ProviderOrdering` raw value.
    public static let providerOrderingDefaultsKey = "QuotaBarProviderOrdering"

    /// Every vendor in display order. Reading always yields a complete list
    /// (see `ProviderDisplayPreferences.resolveOrder`).
    public static var providerOrder: [VendorIdentifier] {
        get { ProviderDisplayPreferences.resolveOrder(stored: preferences.stringArray(forKey: providerOrderDefaultsKey)) }
        set {
            preferences.set(newValue.map(\.rawValue), forKey: providerOrderDefaultsKey)
            postProviderPreferencesDidChange()
        }
    }

    /// Forgets a custom arrangement, returning to `defaultOrder`.
    public static func resetProviderOrder() {
        preferences.removeObject(forKey: providerOrderDefaultsKey)
        postProviderPreferencesDidChange()
    }

    public static var hiddenProviders: Set<VendorIdentifier> {
        get { ProviderDisplayPreferences.resolveHidden(stored: preferences.stringArray(forKey: hiddenProvidersDefaultsKey)) }
        set {
            preferences.set(newValue.map(\.rawValue).sorted(), forKey: hiddenProvidersDefaultsKey)
            postProviderPreferencesDidChange()
        }
    }

    public static var providerOrdering: ProviderOrdering {
        get { ProviderOrdering(stored: preferences.string(forKey: providerOrderingDefaultsKey)) }
        set {
            preferences.set(newValue.rawValue, forKey: providerOrderingDefaultsKey)
            postProviderPreferencesDidChange()
        }
    }

    /// All three choices in one read, so a poll sees a consistent set.
    public static var providerDisplayPreferences: ProviderDisplayPreferences {
        ProviderDisplayPreferences(
            ordering: providerOrdering,
            order: providerOrder,
            hidden: hiddenProviders
        )
    }

    private static func postProviderPreferencesDidChange() {
        NotificationCenter.default.post(name: .frugalbarProviderPreferencesDidChange, object: nil)
    }
}
