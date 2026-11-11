import Foundation

/// Which allowance a banked reset credit applies to.
///
/// A grant that clears a Fable window is scoped to that model's weekly cap;
/// every other grant is a plan-wide reset. What the grant clears decides
/// first, with the vendor's own `id`/`label` as the fallback when it publishes
/// no `clears`. The distinction is never inferred from the ticket order or a
/// count.
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
