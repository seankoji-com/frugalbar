import Foundation

/// Which allowance a banked reset credit applies to.
///
/// The vendor's grant `id` names the model first: an id containing Fable is
/// model-scoped even when the grant also clears a shared plan window. With no
/// model id, `clears` decides (a plan window is the general ticket; a
/// Fable-only clear is the model ticket). The `label` is the fallback when
/// neither is present. The distinction is never inferred from the ticket order
/// or a count.
public enum ResetCreditScope: Sendable, Equatable, Hashable {
    case plan
    case model(String)

    public var isPlan: Bool {
        if case .plan = self { return true }
        return false
    }

    /// A short name for the scope, used in the ticket line's spoken label.
    public var displayName: String {
        switch self {
        case .plan: "General"
        case .model(let name): name
        }
    }
}

/// The tickets one scope holds, with their published expiries aligned to the
/// drawn glyphs. `count` is the full published figure; `expiries` is capped at
/// the display limit, and the UI states the remainder as `+n` rather than
/// inventing an expiry for it.
public struct ResetCreditGroup: Sendable, Equatable {
    public let scope: ResetCreditScope
    public let count: Int
    public let expiries: [Date?]

    public init(scope: ResetCreditScope, count: Int, expiries: [Date?]) {
        self.scope = scope
        self.count = count
        self.expiries = expiries
    }
}
