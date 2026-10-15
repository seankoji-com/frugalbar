import Foundation
import Testing
@testable import QuotaBarCore

// MARK: - Builders

private let now = Date(timeIntervalSince1970: 1_792_022_400)  // 2026-10-15T00:00:00Z

private func snapshot(
    _ vendor: VendorIdentifier,
    id: String? = nil,
    metric: MetricType = .percentage(usedFraction: 0.4, displayDetails: nil),
    status: ProviderStatus = .healthy,
    resetsAt: Date? = nil,
    rows: [DualBarMetrics?] = [],
    currencyBasis: CurrencyBasis? = nil
) -> QuotaSnapshot {
    QuotaSnapshot(
        id: id ?? vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
        category: .aiSubscriptions, metric: metric, status: status, resetsAt: resetsAt,
        lastUpdated: now.addingTimeInterval(-60), auxiliaryInfo: nil,
        row1: rows.count > 0 ? rows[0] : nil, row2: rows.count > 1 ? rows[1] : nil,
        row3: rows.count > 2 ? rows[2] : nil, currencyBasis: currencyBasis)
}

private func bar(
    _ fraction: Double?, label: String = "5H", blocked: Bool = false, resetsAt: Date? = nil,
    windowLength: TimeInterval? = nil
) -> DualBarMetrics {
    DualBarMetrics(primaryFraction: fraction, label: label, isBlocked: blocked,
                   resetsAt: resetsAt, windowLength: windowLength)
}

private func input(_ snapshots: [QuotaSnapshot], events: [AIEvent] = []) -> SnapshotExportInput {
    SnapshotExportInput(publisherId: "00000000-0000-4000-8000-000000000001", publisherLabel: "Test Mac",
                        publishedAt: now, snapshots: snapshots, events: events)
}

private func exported(_ snapshots: [QuotaSnapshot], events: [AIEvent] = []) throws -> [String: Any] {
    let document = try SnapshotExporter.export(input(snapshots, events: events)).get()
    return try #require(try JSONSerialization.jsonObject(with: document.data) as? [String: Any])
}

private func providers(_ document: [String: Any]) throws -> [[String: Any]] {
    try #require(document["providers"] as? [[String: Any]])
}

private func windows(_ provider: [String: Any]) throws -> [[String: Any]] {
    try #require(provider["windows"] as? [[String: Any]])
}

private func event(
    _ id: String, kind: AIEventKind = .vendorReset, hoursAgo: Double, source: AIEventSource = .resetTracker(name: "codex-reset"),
    url: String? = nil
) -> AIEvent {
    AIEvent(id: id, kind: kind, vendorId: .openai, title: "OpenAI usage reset", detail: nil,
            occurredAt: now.addingTimeInterval(-hoursAgo * 3600), observedAt: now, source: source,
            url: url.flatMap(URL.init(string:)))
}

/// A Grok provider whose every read fails offline, for the store path.
private struct OfflineGrokProvider: QuotaProvider {
    let vendorId: VendorIdentifier = .grok
    let displayName = "Grok"
    let category: MetricCategory = .aiSubscriptions
    func fetchSnapshot() async throws -> QuotaSnapshot { throw ProviderError(.offline) }
}

private let sourceDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/QuotaBarCore")

// MARK: - [REQ-MAC-QUANTITY](c), (d)

@Suite("Snapshot export — adapter rules")
struct SnapshotExporterTests {

    @Test("the exporter never reads usedText or resetText, and reads label only to copy it truncated")
    func exporterSourceNeverReadsDisplayText() throws {
        let directory = sourceDirectory.appendingPathComponent("Export")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 3)
        for file in files {
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["usedText", "resetText", "badgeText", "auxiliaryInfo", "keyMasked", "cliSource",
                              "latencyMs", "shortPlanName", "rowTitle"] {
                #expect(!source.contains(forbidden), "\(file) mentions \(forbidden)")
            }
            // Every `.label` read is the argument of the truncating copy.
            let reads = source.matches(of: /\.label\b/).count
            let copies = source.matches(of: /ExportText\.truncate\(\w+\.label, limit: \.name\)/).count
            #expect(reads == copies, "\(file): \(reads) label reads, \(copies) truncating copies")
        }
    }

    @Test("a multibyte label over its escaped-byte limit is cut at a character boundary with an ellipsis")
    func multibyteLabelIsTruncatedAtACharacterBoundary() throws {
        let label = String(repeating: "é", count: 40)  // 80 bytes
        let cut = ExportText.truncate(label, limit: .name)
        #expect(cut == String(repeating: "é", count: 30) + "…")
        #expect(ExportText.escapedByteCount(cut) <= 64)

        // A family emoji is one character of 25 bytes: it is kept whole or dropped whole.
        let family = "👨‍👩‍👧‍👦"
        let emoji = ExportText.truncate(String(repeating: family, count: 5), limit: .name)
        #expect(emoji == family + family + "…")

        // Escaping counts: 40 quotes are 80 escaped bytes.
        let quotes = ExportText.truncate(String(repeating: "\"", count: 40), limit: .name)
        #expect(ExportText.escapedByteCount(quotes) <= 64)
        #expect(quotes == String(repeating: "\"", count: 30) + "…")

        // Text that fits is copied unchanged, at exactly the limit.
        let exact = String(repeating: "é", count: 32)
        #expect(ExportText.truncate(exact, limit: .name) == exact)

        let row = bar(0.5, label: label, resetsAt: now, windowLength: 18000)
        let window = try windows(try providers(try exported([snapshot(.claude, rows: [row])]))[0])[0]
        #expect(window["label"] as? String == cut)
    }

    @Test("table window ids are unique within each vendor and match ^[a-z0-9_]{1,32}$")
    func tableWindowIDsAreUniquePerVendorAndMatchTheSlugPattern() {
        for (vendor, metric) in SnapshotExportTable.branches {
            let ids = Array(SnapshotExportTable.windowIDs(for: vendor, metric: metric).values)
                + [SnapshotExportTable.billingCycleWindowID]
            #expect(Set(ids).count == ids.count, "\(vendor) reuses a window id: \(ids)")
            for id in ids {
                #expect(id.wholeMatch(of: /[a-z0-9_]{1,32}/) != nil, "\(vendor): \(id)")
            }
        }
        #expect(Set(SnapshotExportTable.branches.map(\.vendor)) == Set(VendorIdentifier.allCases))
    }

    @Test("an unmapped row withholds the publish, shows the Mac error, and leaves provider status unchanged")
    func unmappedRowTakesTheLocalFailurePath() throws {
        var state = SnapshotExportState()
        let good = snapshot(.claude, status: .critical, rows: [bar(0.9), bar(0.4, label: "WK")])
        let published = state.prepare(input([good]))
        #expect(published != nil)

        let unmapped = snapshot(.claude, status: .critical, rows: [bar(0.9), bar(0.4, label: "WK"), bar(0.1, label: "MO")])
        let before = unmapped
        #expect(state.prepare(input([unmapped])) == nil, "no document to publish")
        #expect(state.lastGoodDocument == published, "the last good document stays in place")
        #expect(state.lastError == .unmappedRow(vendorId: .claude, position: .row3))
        #expect(state.settingsMessage == "Sync export error: unmapped row (claude, row3)")
        #expect(unmapped == before)
        #expect(unmapped.status == .critical)

        // A vendor with no windows at all fails the same way for any row.
        let stray = snapshot(.openrouter, metric: .currency(balance: 1, limit: nil, spent: nil, currencyCode: "USD"),
                             rows: [bar(0.2)], currencyBasis: .accountCredit)
        #expect(SnapshotExporter.export(input([stray])) == .failure(.unmappedRow(vendorId: .openrouter, position: .row1)))

        // A good export clears the error.
        #expect(state.prepare(input([good])) != nil)
        #expect(state.lastError == nil)
    }

    @Test("a nil basis outside the DevPass rule exports unavailable {missingBasis}")
    func nilBasisOutsideDevPassExportsMissingBasis() throws {
        let money = MetricType.currency(balance: 12.5, limit: nil, spent: nil, currencyCode: "USD")
        let document = try exported([
            snapshot(.openrouter, metric: money),
            snapshot(.deepseek, metric: money, currencyBasis: .accountCredit),
            snapshot(.devpass, metric: money),
            snapshot(.devpass, id: "devpass:capped", metric: .currency(balance: 5, limit: 10, spent: 5, currencyCode: "USD")),
        ])
        let primaries = try providers(document).map { try #require($0["primary"] as? [String: Any]) }
        #expect(primaries[0]["type"] as? String == "unavailable")
        #expect(primaries[0]["reason"] as? String == "missingBasis")
        #expect(primaries[1]["basis"] as? String == "accountCredit")
        // DevPass's uncapped branch is the one fallback; a capped DevPass with no basis is not.
        #expect(primaries[2]["basis"] as? String == "lifetimeSpend")
        #expect(primaries[3]["reason"] as? String == "missingBasis")
    }

    @Test("every shipped provider branch has a table entry")
    func everyShippedProviderBranchHasATableEntry() throws {
        // Which positions each provider's source fills, read from the source
        // itself so a new row assignment cannot slip past the table.
        let files: [(String, [VendorIdentifier])] = [
            ("ClaudeQuotaProvider.swift", [.claude]), ("OpenAIQuotaProvider.swift", [.openai]),
            ("GeminiQuotaProvider.swift", [.gemini]), ("OpenCodeGoProvider.swift", [.opencode]),
            ("GitHubCopilotProvider.swift", [.copilot]), ("OpenRouterProvider.swift", [.openrouter]),
            ("DeepSeekProvider.swift", [.deepseek]), ("GrokQuotaProvider.swift", [.grok]),
            ("KiroQuotaProvider.swift", [.kiro]), ("CommandCodeQuotaProvider.swift", [.commandcode]),
            ("ClinePassQuotaProvider.swift", [.clinepass]), ("MuseQuotaProvider.swift", [.muse]),
        ]
        for (file, vendors) in files {
            let source = try String(contentsOf: sourceDirectory.appendingPathComponent("Providers/\(file)"), encoding: .utf8)
            for position in SnapshotExportTable.Position.allCases {
                let fills = !source.matches(of: try Regex("\\b\(position.rawValue): (?!nil\\b)")).isEmpty
                    || source.contains(".\(position.rawValue) = ")
                guard fills else { continue }
                for vendor in vendors {
                    #expect(SnapshotExportTable.windowIDs(for: vendor, metric: .subscription(tierName: nil, renewalDate: nil))[position] != nil,
                            "\(file) fills \(position.rawValue) for \(vendor), which has no table entry")
                }
            }
        }
        // DevPass and GitHub branch on structure the source scan cannot see:
        // DevPass on its metric, GitHub on consolidated vs standalone.
        for metric in [MetricType.percentage(usedFraction: 0, displayDetails: nil),
                       .currency(balance: 0, limit: nil, spent: nil, currencyCode: "USD")] {
            #expect(SnapshotExportTable.windowIDs(for: .devpass, metric: metric)[.row1] != nil)
        }
        let any = MetricType.count(remaining: 1, limit: 2, unitName: "req/hr")
        #expect(SnapshotExportTable.windowIDs(for: .githubRest, metric: any)[.row1] == "rest")
        #expect(SnapshotExportTable.windowIDs(for: .githubRest, metric: any)[.row2] == "graphql")
        #expect(SnapshotExportTable.windowIDs(for: .githubGraphql, metric: any)[.row1] == "graphql")

        // And the providers whose snapshot builders tests can reach export cleanly in every branch.
        for snapshot in try ProviderBranchSnapshots.all() {
            if case .failure(let error) = SnapshotExporter.export(input([snapshot])) {
                Issue.record("\(snapshot.vendorId) branch failed: \(error.message)")
            }
        }
    }

    // MARK: - [REQ-MAC-EXPORT]

    @Test("identities are the first 32 hex characters of SHA-256 of the full source identity")
    func identitiesAreTheFirst32HexOfSHA256() throws {
        // `printf claude | shasum -a 256` = c857d09db23e6822e3600bc06ad8d58f92ed62bc…
        #expect(SnapshotExportIdentity.digest("claude") == "c857d09db23e6822e3600bc06ad8d58f")
        #expect(SnapshotExportIdentity.digest("abc") == "ba7816bf8f01cfea414140de5dae2223")
        #expect(SnapshotExportIdentity.digest("") == "e3b0c44298fc1c149afbf4c8996fb924")
        let longID = "vendor_reset|openai|tracker:codex-reset|" + String(repeating: "guid", count: 500)
        let workspace = "opencode:wrk_01HALPHA"
        let document = try exported(
            [snapshot(.opencode, id: workspace, rows: [bar(0.1)])],
            events: [AIEvent(id: longID, kind: .usageRestored, vendorId: .opencode, instanceId: workspace,
                             title: "t", detail: nil, occurredAt: now, observedAt: now, source: .quotaPoll)])
        let provider = try providers(document)[0]
        let exportedEvent = try #require((document["events"] as? [[String: Any]])?.first)
        #expect(provider["instanceId"] as? String == SnapshotExportIdentity.digest(workspace))
        #expect(exportedEvent["id"] as? String == SnapshotExportIdentity.digest(longID))
        // The same function everywhere, so an event's reference matches its provider.
        #expect(exportedEvent["instanceId"] as? String == provider["instanceId"] as? String)
    }

    @Test("an identity collision makes the exporter refuse to publish")
    func identityCollisionRefusesToPublish() {
        let two = [snapshot(.claude, rows: [bar(0.1)]), snapshot(.openai, rows: [bar(0.2)])]
        #expect(SnapshotExporter.export(input(two), identity: { _ in "0123456789abcdef0123456789abcdef" })
                == .failure(.identityCollision))
        // Distinct sources with distinct digests publish.
        #expect((try? SnapshotExporter.export(input(two)).get()) != nil)
        // A duplicated instance is a collision too.
        let duplicate = [snapshot(.claude, rows: [bar(0.1)]), snapshot(.claude, rows: [bar(0.2)])]
        #expect(SnapshotExporter.export(input(duplicate)) == .failure(.identityCollision))
        var state = SnapshotExportState()
        #expect(state.prepare(input(duplicate)) == nil)
        #expect(state.settingsMessage == "Sync export error: identity collision")
    }

    @Test("an event's instance reference is checked against every identity, and may repeat")
    func eventReferencesTakePartInCollisionChecks() throws {
        let kiro = snapshot(.kiro, rows: [bar(0.2, label: "MO")])
        func reference(_ id: String, to instance: String) -> AIEvent {
            AIEvent(id: id, kind: .usageRestored, vendorId: .kiro, instanceId: instance, title: "t", detail: nil,
                    occurredAt: now, observedAt: now, source: .quotaPoll)
        }
        let digest = SnapshotExportIdentity.digest
        // A different source forced onto the provider's digest is refused,
        // though the provider and event ids themselves stay distinct.
        let ontoProvider: (String) -> String = { $0 == "different-source" ? digest("kiro") : digest($0) }
        #expect(SnapshotExporter.export(input([kiro], events: [reference("e1", to: "different-source")]),
                                        identity: ontoProvider) == .failure(.identityCollision))
        // Two different references to absent providers, forced onto one digest.
        let shared: (String) -> String = { $0.hasPrefix("absent-") ? "0123456789abcdef0123456789abcdef" : digest($0) }
        #expect(SnapshotExporter.export(input([], events: [reference("e1", to: "absent-a"), reference("e2", to: "absent-b")]),
                                        identity: shared) == .failure(.identityCollision))
        // A reference forced onto another event's id.
        let ontoEvent: (String) -> String = { $0 == "absent-a" ? digest("e2") : digest($0) }
        #expect(SnapshotExporter.export(input([], events: [reference("e1", to: "absent-a"), reference("e2", to: "kiro")]),
                                        identity: ontoEvent) == .failure(.identityCollision))

        // Repeated references to one source publish, the provider's own and an absent one alike.
        let repeated = [reference("e1", to: "kiro"), reference("e2", to: "kiro"),
                        reference("e3", to: "absent-a"), reference("e4", to: "absent-a")]
        for identity in [ontoProvider, shared, digest] {
            let document = try #require(try JSONSerialization.jsonObject(
                with: try SnapshotExporter.export(input([kiro], events: repeated), identity: identity).get().data) as? [String: Any])
            let references = try #require(document["events"] as? [[String: Any]]).compactMap { $0["instanceId"] as? String }
            #expect(references.count == 4)
            #expect(Set(references).count == 2)
            #expect(references.contains(try providers(document)[0]["instanceId"] as? String ?? ""))
        }
    }

    @Test("a failed first read that QuotaManager gave a billing cycle exports no measurement and no plan")
    func failedFirstReadWithACycleExportsNoReading() async throws {
        let cycle = SubscriptionCycle(anchorDate: Date().addingTimeInterval(-40 * 86400), cadence: .monthly)
        let manager = QuotaManager(providerFactory: { [OfflineGrokProvider()] }, cycleLookup: { _ in cycle })
        let stored = try #require(await manager.refresh()["grok"])
        // The store really attached the user's cycle to its placeholder.
        #expect(stored.status == .unavailable(.offline))
        #expect(stored.row1?.measuresElapsedTimeOnly == true)
        #expect(stored.row2 == nil && stored.row3 == nil && stored.apiCredits.isEmpty && stored.staleReading == nil)

        let provider = try providers(try exported([stored]))[0]
        #expect(provider["measuredAt"] is NSNull)
        #expect(provider["primary"] as? [String: String] == ["type": "unavailable", "reason": "noReading"])
        #expect((provider["status"] as? [String: String])?["reason"] == "offline")
        #expect(try windows(provider).map { $0["kind"] as? String } == ["billingCycle"])
        #expect(provider["tightestWindowId"] is NSNull)

        // never-measured-with-cycle is this same snapshot, so its fixture pins the bytes.
        let fixture = try SnapshotFixtures.input("never-measured-with-cycle").snapshots[0]
        #expect(fixture.vendorId == stored.vendorId && fixture.id == stored.id)
        #expect(fixture.metric == stored.metric)
        #expect(fixture.status == stored.status)
        #expect(fixture.row1?.label == stored.row1?.label && fixture.row1?.measuresElapsedTimeOnly == true)
        #expect(fixture.row2 == nil && fixture.row3 == nil && fixture.apiCredits.isEmpty && fixture.staleReading == nil)

        // A vendor row beside the same cycle is a reading again.
        var measured = stored
        measured.row2 = bar(0.4, label: "OD")
        let read = try providers(try exported([measured]))[0]
        #expect(read["measuredAt"] as? String == ExportText.timestamp(stored.lastUpdated))
    }

    @Test("DevPass usage the vendor did not send exports as no reading, not 0 used; the Mac's own output is unchanged")
    func devPassMissingUsageExportsNoReading() throws {
        func build(_ body: String) throws -> QuotaSnapshot {
            let key = try JSONDecoder().decode(DevPassQuotaProvider.KeyData.self, from: Data(body.utf8))
            return DevPassQuotaProvider.snapshot(from: key, provider: DevPassQuotaProvider(), now: now)
        }
        for limit in ["null", "\"25\""] {
            let missing = try build(#"{"label":"key","limit":\#(limit),"devPlan":"none"}"#)
            let zero = try build(#"{"label":"key","usage":"0","limit":\#(limit),"devPlan":"none"}"#)
            // The Mac draws exactly what it drew before; only the passive quantity keeps the absence.
            #expect(missing.row1?.quantityUsed == nil)
            #expect(zero.row1?.quantityUsed == 0)
            var unchanged = missing
            unchanged.row1?.quantityUsed = 0
            #expect(unchanged == zero)

            let absent = try providers(try exported([missing]))[0]
            let spend = try windows(absent)[0]
            #expect(spend["windowId"] as? String == "spend")
            #expect(spend["usedFraction"] is NSNull)
            #expect(spend["quantity"] == nil)
            #expect(spend["unavailable"] as? [String: String] == ["reason": "noReading"])
            #expect(spend["eligibleForTightest"] as? Bool == false)
            #expect(absent["tightestWindowId"] is NSNull)
            #expect(absent["primary"] as? [String: String] == ["type": "unavailable", "reason": "noReading"])

            // A zero the vendor did send is a reading, and exports as one.
            let reported = try providers(try exported([zero]))[0]
            #expect((try windows(reported)[0]["quantity"] as? [String: String])?["used"] == "0")
            #expect((reported["primary"] as? [String: Any])?["type"] as? String == "currency")
        }
    }

    @Test("Kiro overage the vendor did not send exports as no reading, not 0 used; the plan and the Mac's own output are unchanged")
    func kiroMissingOverageExportsNoReading() throws {
        let missing = try ProviderBranchSnapshots.kiroEnabledOverage(reported: nil)
        let zero = try ProviderBranchSnapshots.kiroEnabledOverage(reported: "0.0")
        // The Mac draws exactly what it drew before; only the passive quantity keeps the absence.
        #expect(missing.row3?.quantityUsed == nil)
        #expect(zero.row3?.quantityUsed == 0)
        #expect(missing.row3?.usedText == "0/1000 overage credits @ $0.04/credit")
        var unchanged = missing
        unchanged.row3?.quantityUsed = 0
        #expect(unchanged == zero)

        func window(_ provider: [String: Any], _ id: String) throws -> [String: Any] {
            try #require(try windows(provider).first { $0["windowId"] as? String == id })
        }
        let absent = try providers(try exported([missing]))[0]
        let overage = try window(absent, "overage")
        #expect(overage["usedFraction"] is NSNull)
        #expect(overage["quantity"] == nil)
        #expect(overage["unavailable"] as? [String: String] == ["reason": "noReading"])
        #expect(overage["eligibleForTightest"] as? Bool == false)
        // The plan is a reading of its own: its window and the percentage primary stay.
        let monthly = try window(absent, "monthly")
        #expect(monthly["quantity"] as? [String: String] == ["used": "40", "limit": "50", "unit": "credits"])
        #expect(monthly["unavailable"] == nil)
        #expect((absent["primary"] as? [String: Any])?["type"] as? String == "percentage")
        #expect(absent["tightestWindowId"] as? String == "monthly")

        // A zero the vendor did send is a reading, and exports as one.
        let reported = try window(try providers(try exported([zero]))[0], "overage")
        #expect(reported["quantity"] as? [String: String] == ["used": "0", "limit": "1000", "unit": "credits"])
        #expect(reported["unavailable"] == nil)
        #expect(reported["eligibleForTightest"] as? Bool == true)
    }

    @Test("measuredAt is null for unavailableSnapshot placeholders, and set for a real or retained read")
    func measuredAtIsNullForUnavailablePlaceholders() throws {
        let placeholder = GrokQuotaProvider(accessToken: nil).unavailable(.notConfigured)
        var retained = snapshot(.claude, rows: [bar(0.5)])
        retained.staleReading = StaleReading(reason: .offline, at: now)
        let document = try exported([placeholder, retained])
        let (empty, kept) = (try providers(document)[0], try providers(document)[1])
        #expect(empty["measuredAt"] is NSNull)
        #expect((empty["primary"] as? [String: Any])?["reason"] as? String == "noReading")
        #expect((empty["status"] as? [String: Any])?["reason"] as? String == "notConfigured")
        #expect(kept["measuredAt"] as? String == ExportText.timestamp(retained.lastUpdated))
        #expect(kept["lastAttemptAt"] as? String == ExportText.timestamp(now))
    }

    @Test("billing cycles export only cycleStart and cycleEnd")
    func billingCyclesExportOnlyCycleStartAndEnd() throws {
        let cycle = SubscriptionCycle(anchorDate: now.addingTimeInterval(-40 * 86400), cadence: .monthly)
        let row = try #require(cycle.cycleRow(now: now, calendar: Calendar(identifier: .gregorian)))
        let renewal = try #require(row.resetsAt)
        let length = try #require(row.windowLength)
        let window = try windows(try providers(try exported([snapshot(.muse, rows: [bar(0.3), nil, row])]))[0])[1]
        #expect(window["windowId"] as? String == "cycle")
        #expect(window["kind"] as? String == "billingCycle")
        #expect(window["cycleEnd"] as? String == ExportText.timestamp(renewal))
        #expect(window["cycleStart"] as? String == ExportText.timestamp(renewal.addingTimeInterval(-length)))
        // Nothing else describes it: no fraction, quantity, reset or length, and never eligible.
        #expect(window["usedFraction"] is NSNull)
        #expect(window["resetsAt"] is NSNull)
        #expect(window["resetSource"] as? String == "none")
        #expect(window["windowSeconds"] is NSNull)
        #expect(window["quantity"] == nil)
        #expect(window["eligibleForTightest"] as? Bool == false)
    }

    @Test("tightestWindowId: blocked first, then largest fraction, earliest known reset, then row order")
    func tightestFollowsDiscoveryOrder() throws {
        func tightest(_ vendor: VendorIdentifier, _ rows: [DualBarMetrics?], resetsAt: Date? = nil) throws -> String? {
            try providers(try exported([snapshot(vendor, resetsAt: resetsAt, rows: rows)]))[0]["tightestWindowId"] as? String
        }
        let soon = now.addingTimeInterval(3600), later = now.addingTimeInterval(7200)
        #expect(try tightest(.claude, [bar(0.9), bar(nil, label: "WK", blocked: true)]) == "weekly")
        #expect(try tightest(.claude, [bar(0.3), bar(0.6, label: "WK")]) == "weekly")
        #expect(try tightest(.claude, [bar(0.5, resetsAt: later), bar(0.5, label: "WK", resetsAt: soon)]) == "weekly")
        #expect(try tightest(.claude, [bar(0.5), bar(0.5, label: "WK", resetsAt: later)]) == "weekly")
        #expect(try tightest(.claude, [bar(0.5), bar(0.5, label: "WK")]) == "5h")
        // The provider reset counts for a P row.
        #expect(try tightest(.githubRest, [bar(0.5, label: "REST"), bar(0.5, label: "GraphQL")], resetsAt: soon) == "rest")
        // Gemini's w3 is never eligible, whatever its fraction.
        #expect(try tightest(.gemini, [bar(0.2), bar(0.3, label: "WK"), bar(0.99, label: "MO")]) == "w2")
        // Nothing eligible: null.
        #expect(try tightest(.claude, [bar(nil), bar(nil, label: "WK")]) == nil)
        #expect(try providers(try exported([snapshot(.claude, rows: [bar(nil)])]))[0]["tightestWindowId"] is NSNull)
    }

    @Test("events: the surfaced kinds from the last 7 days, newest first, at most 100; notificationPrefs present")
    func eventsCoverSevenDaysSurfacedNewestFirstAtMostAHundred() throws {
        var events = (0..<120).map { event("e\($0)", hoursAgo: Double($0) + 1) }
        events += [
            event("old", hoursAgo: 7 * 24 + 1),
            event("retired", kind: .priceChange, hoursAgo: 0.1),
            event("routine", kind: .usageReset, hoursAgo: 0.2, source: .quotaPoll),
            event("catalog", kind: .newModel, hoursAgo: 0.3, source: .openRouterCatalog),
            event("account", kind: .newModel, hoursAgo: 0.4, source: .accountModels),
        ]
        var prefsInput = input([snapshot(.openai, rows: [bar(0.1)])], events: events.shuffled())
        prefsInput.notificationPrefs = SnapshotExportNotificationPrefs(disabledKinds: [.newModel], resetAlertVendors: [.claude])
        let document = try #require(try JSONSerialization.jsonObject(
            with: try SnapshotExporter.export(prefsInput).get().data) as? [String: Any])
        let exportedEvents = try #require(document["events"] as? [[String: Any]])
        #expect(exportedEvents.count == 100)
        #expect(document["eventsTruncated"] as? Bool == true)
        let expectedIDs = (["account"] + (0..<99).map { "e\($0)" }).map(SnapshotExportIdentity.digest)
        #expect(exportedEvents.map { $0["id"] as? String } == expectedIDs)
        let prefs = try #require(document["notificationPrefs"] as? [String: [String]])
        #expect(prefs == ["disabledKinds": ["new_model"], "resetAlertVendors": ["claude"]])

        // Under the cap nothing is truncated, and an http URL is dropped while an https one is kept.
        let few = try exported([snapshot(.openai, rows: [bar(0.1)])], events: [
            event("a", hoursAgo: 1, url: "https://example.com/a"), event("b", hoursAgo: 2, url: "http://example.com/b"),
        ])
        #expect(few["eventsTruncated"] as? Bool == false)
        let urls = (few["events"] as? [[String: Any]])?.map { $0["url"] as? String }
        #expect(urls == ["https://example.com/a", nil])
        #expect(try exported([])["notificationPrefs"] != nil)
    }

    @Test("events: occurredAt from publishedAt − 7 days to publishedAt, both ends included, nothing after")
    func eventWindowIsBoundedAtBothEnds() throws {
        let horizon = SnapshotExporter.eventHorizon
        func at(_ id: String, _ offset: TimeInterval) -> AIEvent {
            AIEvent(id: id, kind: .vendorReset, vendorId: .openai, title: "OpenAI usage reset", detail: nil,
                    occurredAt: now.addingTimeInterval(offset), observedAt: now, source: .resetTracker(name: "codex-reset"))
        }
        let events = [
            at("oldest-kept", -horizon), at("just-too-old", -horizon - 0.001), at("published", 0),
            at("just-after", 0.001), at("tomorrow", 86400), at("next-year", 365 * 86400), at("recent", -3600),
        ]
        let kept = try #require(try exported([snapshot(.openai, rows: [bar(0.1)])], events: events.shuffled())["events"]
            as? [[String: Any]])
        #expect(kept.map { $0["id"] as? String } == ["published", "recent", "oldest-kept"].map(SnapshotExportIdentity.digest))

        // Future events cannot fill the cap and push out a real one.
        let flood = (0..<150).map { at("future\($0)", Double($0 + 1) * 60) } + [at("real", -60)]
        let document = try exported([snapshot(.openai, rows: [bar(0.1)])], events: flood)
        #expect((document["events"] as? [[String: Any]])?.map { $0["id"] as? String } == [SnapshotExportIdentity.digest("real")])
        #expect(document["eventsTruncated"] as? Bool == false)
    }

    // MARK: - [REQ-MAC-BOUNDS](b), (c), (d)

    @Test("numeric domains: decimals, integers and fractions; a violation makes only that metric outOfRange")
    func outOfRangeValuesTurnOnlyThatMetricUnavailable() throws {
        #expect(ExportText.decimal(Decimal(string: "999999999999999999.99999999")!) == "999999999999999999.99999999")
        #expect(ExportText.decimal(Decimal(string: "-1.5")!) == "-1.5")
        #expect(ExportText.decimal(Decimal(string: "1000000000000000000")!) == nil)  // 19 digits
        #expect(ExportText.decimal(Decimal(string: "0.123456789")!) == nil)  // 9 decimals
        #expect(ExportText.decimal(.nan) == nil)
        #expect(ExportText.integer(9_007_199_254_740_991) == 9_007_199_254_740_991)
        #expect(ExportText.integer(9_007_199_254_740_992) == nil)
        #expect(ExportText.integer(-1) == nil)
        #expect(ExportText.fraction(0) == 0 && ExportText.fraction(1) == 1)
        #expect(ExportText.fraction(1.0001) == nil && ExportText.fraction(-0.1) == nil && ExportText.fraction(.nan) == nil)

        var tooBig = bar(0.5, label: "WK", resetsAt: now)
        tooBig.quantityUsed = Decimal(string: "1234567890123456789")
        tooBig.quantityLimit = 2
        tooBig.quantityUnit = "credits"
        var credit = snapshot(.openai, metric: .percentage(usedFraction: 1.5, displayDetails: nil),
                              rows: [bar(1.2), tooBig, bar(0.3, label: "PLAN")])
        credit.apiCredits = [
            APICreditEntry(id: "big", vendorId: .openai, label: "Big", metric: .credits(remaining: Int.max, unitName: "credits")),
            APICreditEntry(id: "ok", vendorId: .openai, label: "OK", metric: .credits(remaining: 5, unitName: "credits")),
        ]
        let provider = try providers(try exported([credit]))[0]
        #expect((provider["primary"] as? [String: Any])?["reason"] as? String == "outOfRange")
        let rows = try windows(provider)
        for index in [0, 1] {
            #expect(rows[index]["usedFraction"] is NSNull)
            #expect(rows[index]["quantity"] == nil)
            #expect((rows[index]["unavailable"] as? [String: String]) == ["reason": "outOfRange"])
            #expect(rows[index]["eligibleForTightest"] as? Bool == false)
        }
        // Siblings stay valid.
        #expect(rows[2]["usedFraction"] as? Double == 0.3)
        #expect(provider["tightestWindowId"] as? String == "w3")
        let credits = try #require(provider["apiCredits"] as? [[String: Any]])
        #expect((credits[0]["metric"] as? [String: Any])?["reason"] as? String == "outOfRange")
        #expect((credits[1]["metric"] as? [String: Any])?["remaining"] as? Int == 5)
        let count = snapshot(.githubRest, metric: .count(remaining: -1, limit: 5000, unitName: "req/hr"))
        #expect((try providers(try exported([count]))[0]["primary"] as? [String: Any])?["reason"] as? String == "outOfRange")
    }

    @Test("the exporter never emits more than 8 API credits per provider")
    func apiCreditsAreCappedAtEight() throws {
        var many = snapshot(.openai, rows: [bar(0.1)])
        many.apiCredits = (0..<12).map {
            APICreditEntry(id: "c\(String($0))", vendorId: .openai, label: "C\(String($0))",
                           metric: .credits(remaining: $0, unitName: "credits"))
        }
        let credits = try #require(try providers(try exported([many]))[0]["apiCredits"] as? [[String: Any]])
        #expect(credits.map { $0["id"] as? String } == (0..<8).map { SnapshotExportIdentity.digest("c\($0)") })
    }

    @Test("Settings shows the too-many-providers notice when providers are omitted")
    func overflowNoticeReachesSettings() throws {
        var state = SnapshotExportState()
        let document = try #require(state.prepare(try SnapshotFixtures.input("providers-overflow")))
        #expect(document.providersOmitted > 0)
        #expect(document.data.count <= SnapshotExporter.maxDocumentBytes)
        #expect(state.settingsMessage == "Too many providers for sync — hide some on the Mac")
    }
}
