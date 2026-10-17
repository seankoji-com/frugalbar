import CryptoKit
import Foundation
@testable import QuotaBarCore

/// Reads the canonical sync fixtures in `Tests/Fixtures/snapshot-v1/`.
///
/// Each `<name>.input.json` describes exporter input in a language-neutral
/// form (README.md there gives the format); `<name>.expected.json` holds the
/// exact document bytes the exporter must produce, or `<name>.expected-error.json`
/// the local failure that withholds the publish.
enum SnapshotFixtures {

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/snapshot-v1", isDirectory: true)

    static let manifestName = "MANIFEST.sha256"

    /// Set to rewrite the expected files and the manifest from the exporter,
    /// instead of comparing against them. Review every diff it makes.
    static var isRegenerating: Bool {
        ProcessInfo.processInfo.environment["FRUGALBAR_WRITE_SNAPSHOT_FIXTURES"] == "1"
    }

    static func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".input.json") }
            .map { String($0.dropLast(".input.json".count)) }
            .sorted()
    }

    static func url(_ file: String) -> URL { directory.appendingPathComponent(file) }

    static func rawInput(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: url("\(name).input.json"))
        return try require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(name) input object")
    }

    static func input(_ name: String) throws -> SnapshotExportInput {
        try decodeInput(rawInput(name))
    }

    static func expectedDocument(_ name: String) -> Data? {
        try? Data(contentsOf: url("\(name).expected.json"))
    }

    static func expectedError(_ name: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: url("\(name).expected-error.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    /// The exported document of a fixture, parsed.
    static func document(_ name: String) throws -> [String: Any] {
        let data = try require(expectedDocument(name), "expected document for \(name)")
        return try require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(name) document")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Decoding

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    static func decodeInput(_ raw: [String: Any]) throws -> SnapshotExportInput {
        let prefs = raw["notificationPrefs"] as? [String: Any] ?? [:]
        return SnapshotExportInput(
            publisherId: try string(raw, "publisherId"),
            publisherLabel: try string(raw, "publisherLabel"),
            publishedAt: try date(raw["publishedAt"]),
            macClockOffsetMs: raw["macClockOffsetMs"] as? Int,
            macClockSampledAt: try optionalDate(raw["macClockSampledAt"]),
            snapshots: try expand(raw["snapshots"], key: "snapshot").map(snapshot),
            untrustedInstanceIDs: Set(raw["untrustedInstanceIds"] as? [String] ?? []),
            events: try expand(raw["events"], key: "event").map(event),
            notificationPrefs: SnapshotExportNotificationPrefs(
                disabledKinds: Set(try (prefs["disabledKinds"] as? [String] ?? []).map {
                    try require(AIEventKind(rawValue: $0), "event kind \($0)")
                }),
                resetAlertVendors: Set(try (prefs["resetAlertVendors"] as? [String] ?? []).map {
                    try require(VendorIdentifier(rawValue: $0), "vendor \($0)")
                })
            )
        )
    }

    /// Expands `{"repeat": N, "<key>": template}` entries: "{n}" in every string
    /// becomes the zero-padded copy index, and with `stepSeconds` each event copy
    /// moves that far from the one before.
    static func expand(_ value: Any?, key: String) throws -> [[String: Any]] {
        try (value as? [[String: Any]] ?? []).flatMap { entry -> [[String: Any]] in
            guard let count = entry["repeat"] as? Int else { return [entry] }
            let template = try require(entry[key] as? [String: Any], "repeat without \(key)")
            let step = entry["stepSeconds"] as? Double ?? 0
            return try (0..<count).map { index in
                var copy = try require(substitute(template, String(format: "%03d", index)) as? [String: Any], "template")
                if step != 0 {
                    for field in ["occurredAt", "observedAt"] {
                        let shifted = try date(copy[field]).addingTimeInterval(step * Double(index))
                        copy[field] = ExportText.timestamp(shifted)
                    }
                }
                return copy
            }
        }
    }

    static func substitute(_ value: Any, _ n: String) -> Any {
        switch value {
        case let text as String: return text.replacingOccurrences(of: "{n}", with: n)
        case let array as [Any]: return array.map { substitute($0, n) }
        case let object as [String: Any]: return object.mapValues { substitute($0, n) }
        default: return value
        }
    }

    static func snapshot(_ raw: [String: Any]) throws -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(
            id: try string(raw, "id"),
            vendorId: try vendor(raw["vendorId"]),
            displayName: try string(raw, "displayName"),
            category: try require(MetricCategory(rawValue: try string(raw, "category")), "category"),
            metric: try metric(try require(raw["metric"] as? [String: Any], "metric")),
            status: try status(try require(raw["status"] as? [String: Any], "status")),
            resetsAt: try optionalDate(raw["resetsAt"]),
            lastUpdated: try date(raw["lastUpdated"]),
            auxiliaryInfo: raw["auxiliaryInfo"] as? String,
            row1: try (raw["row1"] as? [String: Any]).map(row),
            row2: try (raw["row2"] as? [String: Any]).map(row),
            row3: try (raw["row3"] as? [String: Any]).map(row),
            badgeText: raw["badgeText"] as? String,
            planName: raw["planName"] as? String,
            latencyMs: raw["latencyMs"] as? Int,
            keyMasked: raw["keyMasked"] as? String,
            cliSource: raw["cliSource"] as? String,
            currencyBasis: try (raw["currencyBasis"] as? String).map {
                try require(CurrencyBasis(rawValue: $0), "basis \($0)")
            }
        )
        snapshot.apiCredits = try (raw["apiCredits"] as? [[String: Any]] ?? []).map { credit in
            APICreditEntry(
                id: try string(credit, "id"),
                vendorId: try vendor(credit["vendorId"]),
                label: try string(credit, "label"),
                metric: try metric(try require(credit["metric"] as? [String: Any], "credit metric")),
                currencyBasis: try (credit["currencyBasis"] as? String).map {
                    try require(CurrencyBasis(rawValue: $0), "basis \($0)")
                },
                detail: credit["detail"] as? String,
                source: credit["source"] as? String
            )
        }
        snapshot.resetCreditsAvailable = raw["resetCreditsAvailable"] as? Int
        if let stale = raw["staleReading"] as? [String: Any] {
            snapshot.staleReading = StaleReading(
                reason: try reason(try string(stale, "reason"), message: nil),
                at: try date(stale["at"]))
        }
        return snapshot
    }

    static func row(_ raw: [String: Any]) throws -> DualBarMetrics {
        DualBarMetrics(
            primaryFraction: raw["primaryFraction"] as? Double,
            expectedPaceFraction: raw["expectedPaceFraction"] as? Double,
            label: try string(raw, "label"),
            blockedColor: raw["blockedColor"] as? String,
            isBlocked: raw["isBlocked"] as? Bool ?? false,
            measuresElapsedTimeOnly: raw["measuresElapsedTimeOnly"] as? Bool ?? false,
            usedText: raw["usedText"] as? String,
            resetText: raw["resetText"] as? String,
            resetsAt: try optionalDate(raw["resetsAt"]),
            windowLength: raw["windowLength"] as? Double,
            quantityUsed: try optionalDecimal(raw["quantityUsed"]),
            quantityRemaining: try optionalDecimal(raw["quantityRemaining"]),
            quantityLimit: try optionalDecimal(raw["quantityLimit"]),
            quantityUnit: raw["quantityUnit"] as? String
        )
    }

    static func metric(_ raw: [String: Any]) throws -> MetricType {
        switch try string(raw, "type") {
        case "percentage":
            return .percentage(usedFraction: try require(raw["usedFraction"] as? Double, "usedFraction"),
                               displayDetails: nil)
        case "count":
            return .count(remaining: try require(raw["remaining"] as? Int, "remaining"),
                          limit: try require(raw["limit"] as? Int, "limit"),
                          unitName: try string(raw, "unitName"))
        case "currency":
            return .currency(balance: try require(try optionalDecimal(raw["balance"]), "balance"),
                             limit: try optionalDecimal(raw["limit"]),
                             spent: try optionalDecimal(raw["spent"]),
                             currencyCode: try string(raw, "currencyCode"))
        case "credits":
            return .credits(remaining: raw["remaining"] as? Int, unitName: try string(raw, "unit"))
        case "subscription":
            return .subscription(tierName: raw["tierName"] as? String,
                                 renewalDate: try optionalDate(raw["renewalAt"]))
        case let other:
            throw FixtureError(description: "unknown metric type \(other)")
        }
    }

    static func status(_ raw: [String: Any]) throws -> ProviderStatus {
        switch try string(raw, "kind") {
        case "measured":
            let urgency: Urgency = switch raw["urgency"] as? String {
            case "warning": .warning
            case "critical": .critical
            default: .none
            }
            return .measured(urgency)
        case "unavailable":
            return .unavailable(try reason(try string(raw, "reason"), message: raw["message"] as? String))
        case let other:
            throw FixtureError(description: "unknown status kind \(other)")
        }
    }

    static func reason(_ name: String, message: String?) throws -> UnavailableReason {
        switch name {
        case "notConfigured": return .notConfigured
        case "credentialRejected": return .credentialRejected
        case "unsupported": return .unsupported(message ?? "")
        case "offline": return .offline
        case "timedOut": return .timedOut
        case "badResponse": return .badResponse
        case "rateLimited": return .rateLimited(retryAfter: nil)
        default: throw FixtureError(description: "unknown reason \(name)")
        }
    }

    static func event(_ raw: [String: Any]) throws -> AIEvent {
        AIEvent(
            id: try string(raw, "id"),
            kind: try require(AIEventKind(rawValue: try string(raw, "kind")), "event kind"),
            vendorId: try vendor(raw["vendorId"]),
            instanceId: raw["instanceId"] as? String,
            title: try string(raw, "title"),
            detail: raw["detail"] as? String,
            occurredAt: try date(raw["occurredAt"]),
            observedAt: try date(raw["observedAt"]),
            source: try require(AIEventSource(rawValue: try string(raw, "source")), "event source"),
            url: (raw["url"] as? String).flatMap(URL.init(string:))
        )
    }

    // MARK: - Scalars

    static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw FixtureError(description: "fixture is missing \(what)") }
        return value
    }

    static func string(_ raw: [String: Any], _ key: String) throws -> String {
        try require(raw[key] as? String, key)
    }

    static func vendor(_ value: Any?) throws -> VendorIdentifier {
        try require((value as? String).flatMap(VendorIdentifier.init(rawValue:)), "vendorId")
    }

    static func date(_ value: Any?) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try require((value as? String).flatMap(formatter.date(from:)), "timestamp \(String(describing: value))")
    }

    static func optionalDate(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        return try date(value)
    }

    static func optionalDecimal(_ value: Any?) throws -> Decimal? {
        guard let text = value as? String else { return nil }
        return try require(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), "decimal \(text)")
    }
}
