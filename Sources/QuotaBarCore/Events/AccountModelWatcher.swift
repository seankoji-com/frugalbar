import Foundation

/// One model the user's own account can select right now, as the vendor's
/// account-scoped model list reports it.
public struct AccountModel: Sendable, Equatable {
    /// The vendor's own id — what the CLI sends on the wire.
    public let id: String
    /// The vendor's display name, when it publishes one.
    public let name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

/// One model as last seen on an account's model list, persisted so the next
/// poll can be diffed against it.
public struct AccountModelRecord: Sendable, Equatable {
    public let vendorId: VendorIdentifier
    public let modelId: String
    public let name: String?
    public let firstSeen: Date
    public let lastSeen: Date

    public init(vendorId: VendorIdentifier, modelId: String, name: String?, firstSeen: Date, lastSeen: Date) {
        self.vendorId = vendorId
        self.modelId = modelId
        self.name = name
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Announces models that became selectable on the user's own subscriptions.
///
/// The question it answers is "can I pick it in my tool right now", not "was
/// it announced": each vendor's list comes from an endpoint scoped to the
/// user's credential (see `AccountModelLister`), so a model shows up here only
/// once the account itself serves it. Launch posts, catalog listings and
/// staged rollouts that have not reached the account say nothing.
///
/// - A vendor's first successful list seeds silently. Without that, enabling
///   the feature would announce every model the account already had.
/// - A list that could not be read (`nil`) changes nothing; an empty list is
///   ignored too, since no vendor sells a subscription with no models and an
///   empty answer is far likelier a glitch than a fact.
/// - Records are never deleted. A model that drops out and returns is not
///   new, and is not announced again.
public struct AccountModelWatcher: Sendable {
    /// The models `vendor`'s account can select, or nil when the list could
    /// not be read (not configured, offline, rejected, unknown shape).
    public typealias Lister = @Sendable (VendorIdentifier) async -> [AccountModel]?

    private let vendors: [VendorIdentifier]
    private let list: Lister

    public init(vendors: [VendorIdentifier] = AccountModelLister.supportedVendors, list: @escaping Lister = AccountModelLister.live) {
        self.vendors = vendors
        self.list = list
    }

    public func prepare(store: QuotaHistoryStore, vendors active: Set<VendorIdentifier>, now: Date) async -> PendingPoll {
        var events: [AIEvent] = []
        var records: [AccountModelRecord] = []
        var fetched = false
        for vendor in vendors where active.contains(vendor) {
            guard let models = await list(vendor), !models.isEmpty else { continue }
            let known: [String: AccountModelRecord]
            do {
                known = try await store.accountModels(vendor: vendor)
            } catch {
                // An unreadable baseline read as empty would re-seed silently,
                // which is harmless, but a partial read could announce the
                // whole list; skip the vendor this round instead.
                NSLog("frugalbar: failed to read known models for \(vendor.rawValue): \(error)")
                continue
            }
            fetched = true
            let diff = Self.diff(vendor: vendor, known: known, current: models, now: now)
            events += diff.events
            records += diff.records
        }
        let rows = records
        return PendingPoll(events: events, fetched: fetched) {
            try await store.upsertAccountModels(rows)
        }
    }

    /// The pure decision. `known` empty means this vendor was never listed
    /// before: every model is recorded and none is announced.
    static func diff(
        vendor: VendorIdentifier,
        known: [String: AccountModelRecord],
        current: [AccountModel],
        now: Date
    ) -> (events: [AIEvent], records: [AccountModelRecord]) {
        let isSeed = known.isEmpty
        var events: [AIEvent] = []
        var records: [AccountModelRecord] = []
        var seen: Set<String> = []
        for model in current {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let name = model.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let old = known[id]
            records.append(AccountModelRecord(
                vendorId: vendor, modelId: id, name: name ?? old?.name,
                firstSeen: old?.firstSeen ?? now, lastSeen: now))
            guard !isSeed, old == nil else { continue }
            events.append(AIEvent(
                id: AIEvent.makeID(kind: .newModel, vendorId: vendor, components: ["account", id]),
                kind: .newModel,
                vendorId: vendor,
                title: "\(name ?? id) now available in \(AccountModelLister.productName(vendor))",
                detail: name != nil && name != id ? "Model id \(id)" : nil,
                occurredAt: now,
                observedAt: now,
                source: .accountModels
            ))
        }
        return (events, records)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
