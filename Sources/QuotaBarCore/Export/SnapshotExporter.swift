import Foundation

// MARK: - Input

/// The Mac's event-notification choices, exported so the phone notifies on
/// the same kinds and vendors.
public struct SnapshotExportNotificationPrefs: Sendable, Equatable {
    public var disabledKinds: Set<AIEventKind>
    public var resetAlertVendors: Set<VendorIdentifier>

    public init(disabledKinds: Set<AIEventKind> = [], resetAlertVendors: Set<VendorIdentifier> = []) {
        self.disabledKinds = disabledKinds
        self.resetAlertVendors = resetAlertVendors
    }
}

/// Everything one snapshot document is built from. The exporter reads nothing
/// else, so the same input always gives the same bytes.
public struct SnapshotExportInput: Sendable {
    public var publisherId: String
    public var publisherLabel: String
    public var publishedAt: Date
    /// From the `Date` header of the pre-upload metadata response; both nil
    /// when the header was missing.
    public var macClockOffsetMs: Int?
    public var macClockSampledAt: Date?
    /// The Mac-visible providers, in Mac order.
    public var snapshots: [QuotaSnapshot]
    /// Instances whose reading predates a Mac clock discontinuity and has not
    /// been re-measured since.
    public var untrustedInstanceIDs: Set<String>
    /// Recorded events; the exporter picks the surfaced ones from the last
    /// seven days.
    public var events: [AIEvent]
    public var notificationPrefs: SnapshotExportNotificationPrefs

    public init(
        publisherId: String,
        publisherLabel: String,
        publishedAt: Date,
        macClockOffsetMs: Int? = nil,
        macClockSampledAt: Date? = nil,
        snapshots: [QuotaSnapshot],
        untrustedInstanceIDs: Set<String> = [],
        events: [AIEvent] = [],
        notificationPrefs: SnapshotExportNotificationPrefs = SnapshotExportNotificationPrefs()
    ) {
        self.publisherId = publisherId
        self.publisherLabel = publisherLabel
        self.publishedAt = publishedAt
        self.macClockOffsetMs = macClockOffsetMs
        self.macClockSampledAt = macClockSampledAt
        self.snapshots = snapshots
        self.untrustedInstanceIDs = untrustedInstanceIDs
        self.events = events
        self.notificationPrefs = notificationPrefs
    }
}

// MARK: - Output

/// A local exporter failure. The publish is withheld, the last good remote
/// document stays in place, and no provider's exported status changes.
public enum SnapshotExportError: Error, Equatable, Sendable {
    /// A non-nil row the table has no entry for.
    case unmappedRow(vendorId: VendorIdentifier, position: SnapshotExportTable.Position)
    /// Two different source identities in one document share a digest, or
    /// one provider, credit or event appears twice.
    case identityCollision

    /// The line Mac Settings shows.
    public var message: String {
        switch self {
        case .unmappedRow(let vendor, let position):
            "Sync export error: unmapped row (\(vendor.rawValue), \(position.rawValue))"
        case .identityCollision:
            "Sync export error: identity collision"
        }
    }
}

/// One encoded snapshot document, ready to upload.
public struct SnapshotExportDocument: Sendable, Equatable {
    public let data: Data
    public let providersOmitted: Int
    public let eventsTruncated: Bool
    /// The encoded size of each provider that made it into `data`, in order.
    public let providerByteCounts: [Int]

    public static let tooManyProvidersNotice = "Too many providers for sync — hide some on the Mac"

    /// The notice Mac Settings shows when trailing providers did not fit.
    public var notice: String? { providersOmitted > 0 ? Self.tooManyProvidersNotice : nil }
}

/// What Mac Settings shows about the export, and the document a publish may
/// send. A failed export withholds that publish and keeps the last good one.
public struct SnapshotExportState: Sendable {
    public private(set) var lastGoodDocument: SnapshotExportDocument?
    public private(set) var lastError: SnapshotExportError?

    public init() {}

    /// The document to publish, or nil to withhold this publish.
    public mutating func prepare(_ input: SnapshotExportInput) -> SnapshotExportDocument? {
        switch SnapshotExporter.export(input) {
        case .success(let document):
            lastGoodDocument = document
            lastError = nil
            return document
        case .failure(let error):
            lastError = error
            return nil
        }
    }

    public var settingsMessage: String? { lastError?.message ?? lastGoodDocument?.notice }
}

// MARK: - Exporter

/// Builds snapshot schema v1 (D§2.2.E) from the Mac's snapshots.
///
/// This is the export adapter: window identity, eligibility, basis fallback
/// and reset provenance all live here, keyed on `SnapshotExportTable` and the
/// snapshot's structured fields. Display text is never read; labels and names
/// are only copied, cut to their byte limit. Nothing here changes a snapshot.
public enum SnapshotExporter {

    public static let schemaMajor: Int64 = 1
    public static let schemaMinor: Int64 = 0
    public static let maxDocumentBytes = 256 * 1024
    public static let maxWindowsPerProvider = 6
    public static let maxAPICreditsPerProvider = 8
    public static let maxEvents = 100
    public static let eventHorizon: TimeInterval = 7 * 24 * 3600

    public static func export(
        _ input: SnapshotExportInput,
        identity: (String) -> String = SnapshotExportIdentity.digest
    ) -> Result<SnapshotExportDocument, SnapshotExportError> {
        var providers: [Fragment] = []
        for snapshot in input.snapshots {
            do {
                providers.append(try provider(snapshot, input: input, identity: identity))
            } catch {
                return .failure(error)
            }
        }
        let surfaced = surfacedEvents(input)
        let events = surfaced.prefix(maxEvents).map { event($0, identity: identity) }

        // Overflow: drop events oldest first, then trailing providers, until
        // the encoded document fits. Each fragment is encoded once and the
        // document's size is summed from them. Events past the cap of 100 are
        // dropped the same way, so the phone's gap notice covers them too.
        var providerCount = providers.count
        var eventCount = events.count
        var eventsTruncated = surfaced.count > maxEvents
        func size() -> Int {
            skeleton(input, omitted: providers.count - providerCount, truncated: eventsTruncated)
                .encoded().count
                + providers.prefix(providerCount).reduce(0) { $0 + $1.bytes.count } + max(providerCount - 1, 0)
                + events.prefix(eventCount).reduce(0) { $0 + $1.bytes.count } + max(eventCount - 1, 0)
        }
        while size() > maxDocumentBytes {
            if eventCount > 0 {
                eventCount -= 1
                eventsTruncated = true
            } else if providerCount > 0 {
                providerCount -= 1
            } else {
                break
            }
        }

        let kept = Array(providers.prefix(providerCount)) + Array(events.prefix(eventCount))
        guard identitiesAreConsistent(kept.flatMap(\.identities)) else { return .failure(.identityCollision) }

        let document = skeleton(
            input,
            omitted: providers.count - providerCount,
            truncated: eventsTruncated,
            providers: providers.prefix(providerCount).map(\.json),
            events: events.prefix(eventCount).map(\.json)
        )
        return .success(SnapshotExportDocument(
            data: document.encoded(),
            providersOmitted: providers.count - providerCount,
            eventsTruncated: eventsTruncated,
            providerByteCounts: providers.prefix(providerCount).map(\.bytes.count)
        ))
    }

    /// One provider or event, encoded once, with the identities it exports.
    struct Fragment {
        let json: ExportJSON
        let bytes: Data
        let identities: [Identity]

        init(_ json: ExportJSON, identities: [Identity]) {
            self.json = json
            self.bytes = json.encoded()
            self.identities = identities
        }
    }

    /// An exported digest and the full source identity it was made from. A
    /// reference (an event's `instanceId`) points at an identity and may
    /// repeat; anything else names a provider, credit or event of its own.
    struct Identity {
        let source: String
        let digest: String
        let isReference: Bool

        init(_ source: String, identity: (String) -> String, isReference: Bool = false) {
            self.source = source
            self.digest = identity(source)
            self.isReference = isReference
        }
    }

    /// Every digest in a document stands for exactly one source identity,
    /// references included, and nothing but a reference appears twice.
    static func identitiesAreConsistent(_ identities: [Identity]) -> Bool {
        var sources: [String: String] = [:]
        var named: Set<String> = []
        for identity in identities {
            if let known = sources.updateValue(identity.source, forKey: identity.digest), known != identity.source {
                return false
            }
            if !identity.isReference, !named.insert(identity.digest).inserted { return false }
        }
        return true
    }

    static func skeleton(
        _ input: SnapshotExportInput,
        omitted: Int,
        truncated: Bool,
        providers: [ExportJSON] = [],
        events: [ExportJSON] = []
    ) -> ExportJSON {
        let prefs = input.notificationPrefs
        return .object([
            ("schemaVersion", .object([("major", .int(schemaMajor)), ("minor", .int(schemaMinor))])),
            ("publisherId", .string(input.publisherId)),
            ("publisherLabel", .string(ExportText.truncate(input.publisherLabel, limit: .name))),
            ("publishedAt", .string(ExportText.timestamp(input.publishedAt))),
            ("macClockOffsetMs", input.macClockOffsetMs.flatMap(clockOffset) ?? .null),
            ("macClockSampledAt", input.macClockSampledAt.map { .string(ExportText.timestamp($0)) } ?? .null),
            ("providersOmitted", .int(Int64(omitted))),
            ("eventsTruncated", .bool(truncated)),
            ("providers", .array(providers)),
            ("events", .array(events)),
            ("notificationPrefs", .object([
                ("disabledKinds", .array(prefs.disabledKinds.map(\.rawValue).sorted().map(ExportJSON.string))),
                ("resetAlertVendors", .array(prefs.resetAlertVendors.map(\.rawValue).sorted().map(ExportJSON.string))),
            ])),
        ])
    }

    /// The Mac's clock offset is signed (the sign says which way the clock
    /// was off), and integers are 0…2^53 − 1, so it is exported as a decimal
    /// string. Its magnitude keeps the 2^53 − 1 bound; past it, null.
    static func clockOffset(_ value: Int) -> ExportJSON? {
        Int64(value).magnitude <= UInt64(ExportText.maxInteger) ? .string(String(value)) : nil
    }

    // MARK: Providers

    static func provider(
        _ snapshot: QuotaSnapshot,
        input: SnapshotExportInput,
        identity: (String) -> String
    ) throws(SnapshotExportError) -> Fragment {
        let rows: [(SnapshotExportTable.Position, DualBarMetrics?)] = [
            (.row1, snapshot.row1), (.row2, snapshot.row2), (.row3, snapshot.row3),
        ]
        let table = SnapshotExportTable.windowIDs(for: snapshot.vendorId, metric: snapshot.metric)
        var windows: [Window] = []
        for (position, row) in rows {
            guard let row else { continue }
            let windowID = row.measuresElapsedTimeOnly ? SnapshotExportTable.billingCycleWindowID : table[position]
            guard let windowID, !windows.contains(where: { $0.id == windowID }) else {
                throw SnapshotExportError.unmappedRow(vendorId: snapshot.vendorId, position: position)
            }
            windows.append(window(row, id: windowID, position: position, snapshot: snapshot))
        }
        windows = Array(windows.prefix(maxWindowsPerProvider))

        // A reading is a measured status, or rows or credit entries a provider
        // built from a response. A placeholder from a failed first read has
        // none of those: no measurement time and no primary value. A billing
        // cycle is not evidence of a reading either: it is the user's own
        // date, which `QuotaManager` attaches to a failed read too.
        let hasReading = snapshot.status.confidence == .measured
            || rows.contains { $0.1.map { !$0.measuresElapsedTimeOnly } ?? false }
            || !snapshot.apiCredits.isEmpty
        // A DevPass spend or Kiro plan figure the vendor did not report: the
        // primary was built from that default, so it has no value either.
        let usageUnreported = windows.contains {
            $0.usageUnreported && SnapshotExportTable.primaryIsBuiltFrom(snapshot.vendorId, windowID: $0.id)
        }

        let credits = snapshot.apiCredits.prefix(maxAPICreditsPerProvider)
        let instance = Identity(snapshot.id, identity: identity)
        let creditIdentities = credits.map { Identity($0.id, identity: identity) }
        let instanceID = instance.digest
        var fields: [(String, ExportJSON)] = [
            ("instanceId", .string(instanceID)),
            ("vendorId", .string(snapshot.vendorId.rawValue)),
            ("displayName", .string(ExportText.truncate(snapshot.displayName, limit: .name))),
        ]
        if let planName = snapshot.planName {
            fields.append(("planName", .string(ExportText.truncate(planName, limit: .name))))
        }
        fields += [
            ("status", status(snapshot.status)),
            ("measuredAt", hasReading ? .string(ExportText.timestamp(snapshot.lastUpdated)) : .null),
            ("measuredAtTrusted", .bool(!input.untrustedInstanceIDs.contains(snapshot.id))),
            ("lastAttemptAt", .string(ExportText.timestamp(snapshot.staleReading?.at ?? snapshot.lastUpdated))),
        ]
        if let stale = snapshot.staleReading {
            fields.append(("lastPollFailure", .object([
                ("reason", .string(reasonName(stale.reason))),
                ("at", .string(ExportText.timestamp(stale.at))),
            ])))
        }
        fields += [
            ("primary", hasReading && !usageUnreported
                ? metric(snapshot.metric, basis: primaryBasis(snapshot))
                : unavailableMetric("noReading")),
            ("windows", .array(windows.map(\.json))),
            ("tightestWindowId", tightest(windows).map { .string($0) } ?? .null),
            ("apiCredits", .array(zip(credits, creditIdentities).map { entry, id in
                var credit: [(String, ExportJSON)] = [
                    ("id", .string(id.digest)),
                    ("label", .string(ExportText.truncate(entry.label, limit: .name))),
                    ("metric", metric(entry.metric, basis: entry.currencyBasis)),
                    ("basis", entry.currencyBasis.map { .string($0.rawValue) } ?? .null),
                ]
                if let detail = entry.detail {
                    credit.append(("detail", .string(ExportText.truncate(detail, limit: .message))))
                }
                return .object(credit)
            })),
        ]
        return Fragment(.object(fields), identities: [instance] + creditIdentities)
    }

    /// The exported `currency.basis`: the snapshot's own; DevPass's uncapped
    /// spend as `lifetimeSpend`; otherwise none, which exports as
    /// `unavailable {missingBasis}`. The snapshot itself is left as it was.
    static func primaryBasis(_ snapshot: QuotaSnapshot) -> CurrencyBasis? {
        if let basis = snapshot.currencyBasis { return basis }
        if snapshot.vendorId == .devpass, case .currency(_, nil, _, _) = snapshot.metric {
            return .lifetimeSpend
        }
        return nil
    }

    static func status(_ status: ProviderStatus) -> ExportJSON {
        switch status {
        case .measured:
            return .object([("kind", .string("measured"))])
        case .unavailable(let reason):
            var fields: [(String, ExportJSON)] = [
                ("kind", .string("unavailable")),
                ("reason", .string(reasonName(reason))),
            ]
            if case .unsupported(let message) = reason {
                fields.append(("message", .string(ExportText.truncate(message, limit: .message))))
            }
            return .object(fields)
        }
    }

    static func reasonName(_ reason: UnavailableReason) -> String {
        switch reason {
        case .notConfigured:      "notConfigured"
        case .credentialRejected: "credentialRejected"
        case .unsupported:        "unsupported"
        case .offline:            "offline"
        case .timedOut:           "timedOut"
        case .badResponse:        "badResponse"
        case .rateLimited:        "rateLimited"
        }
    }

    static func unavailableMetric(_ reason: String) -> ExportJSON {
        .object([("type", .string("unavailable")), ("reason", .string(reason))])
    }

    /// A `primary` (or API-credit) value. A figure outside its domain makes
    /// only this value `unavailable {outOfRange}`.
    static func metric(_ metric: MetricType, basis: CurrencyBasis?) -> ExportJSON {
        let outOfRange = unavailableMetric("outOfRange")
        switch metric {
        case .percentage(let used, _):
            guard let used = ExportText.fraction(used) else { return outOfRange }
            return .object([("type", .string("percentage")), ("usedFraction", .fraction(used))])
        case .count(let remaining, let limit, let unit):
            guard let remaining = ExportText.integer(remaining), let limit = ExportText.integer(limit)
            else { return outOfRange }
            return .object([
                ("type", .string("count")),
                ("remaining", .int(remaining)),
                ("limit", .int(limit)),
                ("unit", .string(ExportText.truncate(unit, limit: .unit))),
            ])
        case .currency(let balance, let limit, let spent, let code):
            guard let basis else { return unavailableMetric("missingBasis") }
            guard let balanceText = ExportText.decimal(balance) else { return outOfRange }
            var fields: [(String, ExportJSON)] = [("type", .string("currency")), ("balance", .string(balanceText))]
            for (key, value) in [("limit", limit), ("spent", spent)] {
                guard let value else { continue }
                guard let text = ExportText.decimal(value) else { return outOfRange }
                fields.append((key, .string(text)))
            }
            fields += [
                ("currencyCode", .string(ExportText.truncate(code, limit: .unit))),
                ("basis", .string(basis.rawValue)),
            ]
            return .object(fields)
        case .credits(let remaining, let unit):
            let value: ExportJSON
            if let remaining {
                // maxInteger bounds exact JSON integer export in sync-v1 only.
                // Local credits remain Decimal; fractions and larger balances
                // stay local rather than being rounded or changing the schema.
                guard !remaining.isNaN, remaining >= 0,
                      remaining <= Decimal(ExportText.maxInteger) else { return outOfRange }
                let count = NSDecimalNumber(decimal: remaining).int64Value
                guard Decimal(count) == remaining else { return outOfRange }
                value = .int(count)
            } else {
                value = .null
            }
            return .object([
                ("type", .string("credits")),
                ("remaining", value),
                ("unit", .string(ExportText.truncate(unit, limit: .unit))),
            ])
        case .subscription(let tierName, let renewal):
            var fields: [(String, ExportJSON)] = [("type", .string("subscription"))]
            if let tierName {
                fields.append(("tierName", .string(ExportText.truncate(tierName, limit: .name))))
            }
            if let renewal {
                fields.append(("renewalAt", .string(ExportText.timestamp(renewal))))
            }
            return .object(fields)
        }
    }

    // MARK: Windows

    struct Window {
        let id: String
        let position: Int
        let usedFraction: Double?
        let blocked: Bool
        let resetsAt: Date?
        let eligible: Bool
        let usageUnreported: Bool
        let json: ExportJSON
    }

    static func window(
        _ row: DualBarMetrics,
        id: String,
        position: SnapshotExportTable.Position,
        snapshot: QuotaSnapshot
    ) -> Window {
        let index = SnapshotExportTable.Position.allCases.firstIndex(of: position) ?? 0
        var fields: [(String, ExportJSON)] = [
            ("windowId", .string(id)),
            ("label", .string(ExportText.truncate(row.label, limit: .name))),
        ]

        // A billing cycle measures elapsed time, not consumption: it exports
        // its period and nothing else.
        if row.measuresElapsedTimeOnly {
            fields += [
                ("kind", .string("billingCycle")),
                ("usedFraction", .null),
                ("blocked", .bool(false)),
                ("resetsAt", .null),
                ("resetSource", .string("none")),
                ("windowSeconds", .null),
            ]
            if let end = row.resetsAt, let length = row.windowLength, length.isFinite, length > 0 {
                fields += [
                    ("cycleStart", .string(ExportText.timestamp(end.addingTimeInterval(-length)))),
                    ("cycleEnd", .string(ExportText.timestamp(end))),
                ]
            }
            fields.append(("eligibleForTightest", .bool(false)))
            return Window(id: id, position: index, usedFraction: nil, blocked: false,
                          resetsAt: nil, eligible: false, usageUnreported: false, json: .object(fields))
        }

        var outOfRange = false
        var usedFraction: Double? = nil
        if let fraction = row.primaryFraction {
            usedFraction = ExportText.fraction(fraction)
            outOfRange = usedFraction == nil
        }
        var quantity: [(String, ExportJSON)] = []
        if let unit = row.quantityUnit {
            for (key, value) in [("used", row.quantityUsed), ("remaining", row.quantityRemaining),
                                 ("limit", row.quantityLimit)] {
                guard let value else { continue }
                guard let text = ExportText.decimal(value) else { outOfRange = true; continue }
                quantity.append((key, .string(text)))
            }
            if !quantity.isEmpty {
                quantity.append(("unit", .string(ExportText.truncate(unit, limit: .unit))))
            }
        }
        // A window whose figure is the vendor's usage or limit, with that
        // figure unreported: the provider drew it from a default, and a
        // default is not a reading.
        let usageUnreported =
            (SnapshotExportTable.figureIsReportedUsage(snapshot.vendorId, windowID: id) && row.quantityUsed == nil)
            || (SnapshotExportTable.limitIsReported(snapshot.vendorId, windowID: id) && row.quantityLimit == nil)
        let unavailable = usageUnreported ? "noReading" : outOfRange ? "outOfRange" : nil
        if unavailable != nil {
            usedFraction = nil
            quantity = []
        }

        let resetsAt: Date?
        let resetSource: String
        if let own = row.resetsAt {
            (resetsAt, resetSource) = (own, "window")
        } else if SnapshotExportTable.takesProviderReset(snapshot.vendorId, position), let shared = snapshot.resetsAt {
            (resetsAt, resetSource) = (shared, "provider")
        } else {
            (resetsAt, resetSource) = (nil, "none")
        }

        let windowSeconds: ExportJSON = {
            guard let length = row.windowLength, length.isFinite, length > 0 else { return .null }
            let rounded = length.rounded()
            guard rounded <= Double(ExportText.maxInteger) else { return .null }
            return .int(Int64(rounded))
        }()

        let eligible = (usedFraction != nil || row.isBlocked)
            && !SnapshotExportTable.isNeverEligible(snapshot.vendorId, windowID: id)

        fields += [
            ("kind", .string("quota")),
            ("usedFraction", usedFraction.map { .fraction($0) } ?? .null),
        ]
        if !quantity.isEmpty { fields.append(("quantity", .object(quantity))) }
        if let unavailable { fields.append(("unavailable", .object([("reason", .string(unavailable))]))) }
        fields += [
            ("blocked", .bool(row.isBlocked)),
            ("resetsAt", resetsAt.map { .string(ExportText.timestamp($0)) } ?? .null),
            ("resetSource", .string(resetSource)),
            ("windowSeconds", windowSeconds),
            ("eligibleForTightest", .bool(eligible)),
        ]
        return Window(id: id, position: index, usedFraction: usedFraction, blocked: row.isBlocked,
                      resetsAt: resetsAt, eligible: eligible, usageUnreported: usageUnreported, json: .object(fields))
    }

    /// D§2.2.G: blocked first, then the largest used fraction, then the
    /// earliest known reset (known before unknown), then row order. Nil when
    /// no window is eligible.
    static func tightest(_ windows: [Window]) -> String? {
        windows.filter(\.eligible).min { lhs, rhs in
            if lhs.blocked != rhs.blocked { return lhs.blocked }
            let l = lhs.usedFraction ?? -1, r = rhs.usedFraction ?? -1
            if l != r { return l > r }
            switch (lhs.resetsAt, rhs.resetsAt) {
            case let (a?, b?) where a != b: return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.position < rhs.position
            }
        }?.id
    }

    // MARK: Events

    /// Surfaced events from the seven days up to `publishedAt`, both ends
    /// included, newest first. An event dated after `publishedAt` is left out:
    /// it would sort ahead of every real one and use up the cap. Retired kinds
    /// are never surfaced.
    static func surfacedEvents(_ input: SnapshotExportInput) -> [AIEvent] {
        let window = input.publishedAt.addingTimeInterval(-eventHorizon)...input.publishedAt
        return input.events
            .filter { $0.isSurfaced && window.contains($0.occurredAt) }
            .sorted { $0.occurredAt != $1.occurredAt ? $0.occurredAt > $1.occurredAt : $0.id < $1.id }
    }

    static func event(_ event: AIEvent, identity: (String) -> String) -> Fragment {
        var identities = [Identity(event.id, identity: identity)]
        var fields: [(String, ExportJSON)] = [
            ("id", .string(identities[0].digest)),
            ("kind", .string(event.kind.rawValue)),
            ("vendorId", .string(event.vendorId.rawValue)),
        ]
        if let instance = event.instanceId {
            let reference = Identity(instance, identity: identity, isReference: true)
            identities.append(reference)
            fields.append(("instanceId", .string(reference.digest)))
        }
        fields.append(("title", .string(ExportText.truncate(event.title, limit: .message))))
        if let detail = event.detail {
            fields.append(("detail", .string(ExportText.truncate(detail, limit: .eventDetail))))
        }
        let (sourceKind, caption) = source(event.source)
        fields += [
            ("occurredAt", .string(ExportText.timestamp(event.occurredAt))),
            ("observedAt", .string(ExportText.timestamp(event.observedAt))),
            ("source", .object([("kind", .string(sourceKind)), ("caption", .string(caption))])),
        ]
        if let url = event.url, url.scheme?.lowercased() == "https",
           ExportText.escapedByteCount(url.absoluteString) <= ExportText.Limit.url.rawValue {
            fields.append(("url", .string(url.absoluteString)))
        }
        return Fragment(.object(fields), identities: identities)
    }

    /// The evidence behind an event, as a closed kind and a fixed caption.
    /// The caption names the kind of source, never a host or a feed name.
    static func source(_ source: AIEventSource) -> (String, String) {
        switch source {
        case .quotaPoll:         ("quotaPoll", "Vendor usage endpoint")
        case .openRouterCatalog: ("openRouterCatalog", "OpenRouter model catalog")
        case .vendorFeed:        ("vendorFeed", "Vendor news feed")
        case .resetTracker:      ("resetTracker", "Community reset tracker")
        case .statusPage:        ("statusPage", "Vendor status page")
        case .accountModels:     ("accountModels", "Your account's model list")
        }
    }
}
