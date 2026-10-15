import Foundation
import Testing
@testable import QuotaBarCore

/// The canonical fixture set, run end to end through the exporter.
@Suite("Snapshot export — canonical fixtures", .serialized)
struct SnapshotExportFixtureTests {

    static let fixtureNames: [String] = (try? SnapshotFixtures.names()) ?? []

    // MARK: [REQ-FIXTURES]

    @Test("the fixtures match MANIFEST.sha256, file for file")
    func fixturesMatchManifest() throws {
        if SnapshotFixtures.isRegenerating { try writeManifest() }
        let manifest = try String(contentsOf: SnapshotFixtures.url(SnapshotFixtures.manifestName), encoding: .utf8)
        var listed: [String: String] = [:]
        for line in manifest.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            try #require(parts.count == 2, "malformed manifest line: \(line)")
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            #expect(listed[name] == nil, "\(name) is listed twice")
            listed[name] = String(parts[0])
        }
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: SnapshotFixtures.directory.path)
            .filter { $0 != SnapshotFixtures.manifestName && !$0.hasPrefix(".") }
        #expect(Set(onDisk) == Set(listed.keys), "every fixture file is listed, and every listed file exists")
        for (name, digest) in listed {
            let data = try Data(contentsOf: SnapshotFixtures.url(name))
            #expect(SnapshotFixtures.sha256(data) == digest, "\(name) does not match its manifest hash")
        }
    }

    @Test("the fixture set covers D§2.2.E's list and every export-adapter table line and branch")
    func fixturesCoverEveryTableLineAndBranch() throws {
        let required: Set<String> = [
            // D§2.2.E fixture list.
            "fixture:every-vendor", "fixture:github-consolidated", "fixture:never-measured",
            "fixture:blocked-no-percentage", "fixture:no-eligible-window", "fixture:stale-retained",
            "fixture:two-opencode-workspaces", "fixture:events-overflow", "fixture:providers-overflow",
            "fixture:every-field-at-limit", "fixture:long-feed-guid-event-id",
            // One per export-adapter table line.
            "table:claude", "table:openai", "table:gemini", "table:opencode", "table:copilot",
            "table:openrouter", "table:deepseek", "table:grok", "table:kiro", "table:devpass-percentage",
            "table:devpass-currency", "table:commandcode", "table:clinepass", "table:muse",
            "table:github_rest", "table:github_graphql", "table:billing-cycle",
            // And every branch the table and its notes name.
            "branch:grok-daily", "branch:grok-unknown-length", "branch:grok-on-demand",
            "branch:devpass-capped", "branch:devpass-uncapped", "branch:commandcode-capped",
            "branch:commandcode-total", "branch:commandcode-remaining-positive",
            "branch:commandcode-remaining-zero", "branch:missing-basis", "branch:unmapped-row",
            "branch:devpass-capped-missing-usage", "branch:devpass-uncapped-missing-usage",
            "branch:kiro-overage-missing-usage", "branch:kiro-bonus-missing-usage",
            "branch:kiro-bonus-partial-usage", "branch:kiro-bonus-mismatched-pools",
            "branch:kiro-plan-split-unknown", "branch:kiro-plan-split-reported",
            // Regressions: a failed first read that QuotaManager gave a billing cycle.
            "regression:never-measured-with-cycle",
        ]
        var covered: Set<String> = []
        for name in Self.fixtureNames {
            covered.formUnion(try SnapshotFixtures.rawInput(name)["covers"] as? [String] ?? [])
            #expect(SnapshotFixtures.expectedDocument(name) != nil || SnapshotFixtures.expectedError(name) != nil,
                    "\(name) has no expected output")
        }
        #expect(required.subtracting(covered).isEmpty, "uncovered: \(required.subtracting(covered).sorted())")
    }

    // MARK: [REQ-MAC-EXPORT](a), [REQ-FIXTURES](d)

    @Test("every fixture produces exactly its expected JSON", arguments: fixtureNames)
    func everyFixtureProducesExactlyItsExpectedJSON(name: String) throws {
        let input = try SnapshotFixtures.input(name)
        switch SnapshotExporter.export(input) {
        case .success(let document):
            if SnapshotFixtures.isRegenerating {
                try document.data.write(to: SnapshotFixtures.url("\(name).expected.json"))
            }
            let expected = try #require(SnapshotFixtures.expectedDocument(name), "\(name) exported a document")
            #expect(document.data == expected, "\(name): exported bytes differ from \(name).expected.json")
            #expect(document.data.count <= SnapshotExporter.maxDocumentBytes)
        case .failure(let error):
            let actual = Self.errorJSON(error)
            if SnapshotFixtures.isRegenerating {
                let data = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys, .prettyPrinted])
                try data.write(to: SnapshotFixtures.url("\(name).expected-error.json"))
            }
            let expected = try #require(SnapshotFixtures.expectedError(name), "\(name) failed: \(error.message)")
            #expect(actual == expected)
        }
    }

    @Test("the fixture list is not empty, so the per-fixture test really ran")
    func fixtureListIsNotEmpty() {
        #expect(Self.fixtureNames.count >= 30)
    }

    static func errorJSON(_ error: SnapshotExportError) -> [String: String] {
        switch error {
        case .unmappedRow(let vendor, let position):
            ["error": "unmappedRow", "vendorId": vendor.rawValue, "position": position.rawValue,
             "message": error.message]
        case .identityCollision:
            ["error": "identityCollision", "message": error.message]
        }
    }

    func writeManifest() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: SnapshotFixtures.directory.path)
            .filter { $0 != SnapshotFixtures.manifestName && !$0.hasPrefix(".") }
            .sorted()
        let lines = try files.map { "\(SnapshotFixtures.sha256(try Data(contentsOf: SnapshotFixtures.url($0))))  \($0)" }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: SnapshotFixtures.url(SnapshotFixtures.manifestName), atomically: true, encoding: .utf8)
    }

    // MARK: [REQ-MAC-QUANTITY](b)

    /// One window of a fixture's exported document.
    func window(_ name: String, provider: Int = 0, _ id: String) throws -> [String: Any] {
        let providers = try #require(try SnapshotFixtures.document(name)["providers"] as? [[String: Any]])
        let windows = try #require(providers[provider]["windows"] as? [[String: Any]])
        return try #require(windows.first { $0["windowId"] as? String == id }, "\(name) has no window \(id)")
    }

    func provider(_ name: String, _ index: Int = 0) throws -> [String: Any] {
        let providers = try #require(try SnapshotFixtures.document(name)["providers"] as? [[String: Any]])
        return providers[index]
    }

    func quantity(_ window: [String: Any]) -> [String: String]? {
        window["quantity"] as? [String: String]
    }

    @Test("fixtures assert each table line's structured quantities and units")
    func fixtureQuantitiesAndUnits() throws {
        // Consolidated GitHub: remaining and limit per row, REST from the provider's reset.
        #expect(quantity(try window("github-consolidated", "rest")) == ["remaining": "4500", "limit": "5000", "unit": "req/hr"])
        #expect(try window("github-consolidated", "rest")["resetSource"] as? String == "provider")
        #expect(quantity(try window("github-consolidated", "graphql")) == ["remaining": "1000", "limit": "5000", "unit": "pts/hr"])
        #expect(try window("github-consolidated", "graphql")["resetSource"] as? String == "none")
        #expect(try window("github-consolidated", "graphql")["resetsAt"] is NSNull)
        // Standalone GraphQL: provider reset; its "REST" label is copied, not used for identity.
        let standalone = try window("github-graphql-standalone", "graphql")
        #expect(quantity(standalone) == ["remaining": "1000", "limit": "5000", "unit": "pts/hr"])
        #expect(standalone["resetSource"] as? String == "provider")
        #expect(standalone["label"] as? String == "REST")
        // Copilot: two rows, no quantities.
        #expect((try provider("copilot")["windows"] as? [Any])?.count == 2)
        #expect(quantity(try window("copilot", "premium")) == nil)
        #expect(quantity(try window("copilot", "chat")) == nil)
        // Grok: on-demand used and cap in USD; the plan row carries none.
        #expect(quantity(try window("grok-daily", "on_demand")) == ["used": "5", "limit": "20", "unit": "USD"])
        #expect(quantity(try window("grok-unknown-length", "on_demand")) == ["used": "10.5", "limit": "21", "unit": "USD"])
        #expect(quantity(try window("grok-daily", "plan")) == nil)
        // Kiro: all three rows, used and limit in credits.
        #expect(quantity(try window("kiro", "monthly")) == ["used": "18.43", "limit": "50", "unit": "credits"])
        #expect(quantity(try window("kiro", "bonus")) == ["used": "295.94", "limit": "500", "unit": "credits"])
        #expect(quantity(try window("kiro", "overage")) == ["used": "0", "limit": "10000", "unit": "credits"])
        // DevPass: credits on the percentage branch, USD on both spend branches.
        #expect(quantity(try window("devpass-percentage", "monthly")) == ["used": "20", "limit": "80", "unit": "credits"])
        #expect(quantity(try window("devpass-capped-spend", "spend")) == ["used": "10", "limit": "25", "unit": "USD"])
        #expect(try provider("devpass-capped-spend")["tightestWindowId"] as? String == "spend")
        #expect(quantity(try window("devpass-uncapped", "spend")) == ["used": "3.5", "unit": "USD"])
        let uncapped = try #require(try provider("devpass-uncapped")["primary"] as? [String: Any])
        #expect(uncapped["basis"] as? String == "lifetimeSpend")
        #expect(try SnapshotFixtures.input("devpass-uncapped").snapshots[0].currencyBasis == nil)
        // Command Code: capped windows, a total, and the remaining-only branch.
        #expect(quantity(try window("commandcode-capped", "5h")) == ["used": "1.25", "limit": "5", "unit": "credits"])
        #expect(quantity(try window("commandcode-capped", "weekly")) == ["used": "5", "limit": "20", "unit": "credits"])
        #expect(quantity(try window("commandcode-total", "credits")) == ["used": "20", "limit": "80", "unit": "credits"])
        #expect(quantity(try window("commandcode-remaining-positive", "credits")) == ["remaining": "42.5", "unit": "credits"])
        #expect(quantity(try window("commandcode-remaining-zero", "credits")) == ["remaining": "0", "unit": "credits"])
        // Gemini: w3 has the largest fraction and is not tightest.
        #expect(try window("gemini", "w3")["eligibleForTightest"] as? Bool == false)
        #expect(try provider("gemini")["tightestWindowId"] as? String == "w2")
    }

    @Test("missing DevPass usage, missing Kiro overage and a cycle-only placeholder export no reading, not a zero or a plan")
    func fixturesWithoutAReadingExportNoReading() throws {
        for name in ["devpass-capped-missing-usage", "devpass-uncapped-missing-usage"] {
            let spend = try window(name, "spend")
            #expect(spend["usedFraction"] is NSNull, "\(name)")
            #expect(spend["quantity"] == nil, "\(name)")
            #expect(spend["unavailable"] as? [String: String] == ["reason": "noReading"], "\(name)")
            #expect(spend["eligibleForTightest"] as? Bool == false, "\(name)")
            let exported = try provider(name)
            #expect(exported["primary"] as? [String: String] == ["type": "unavailable", "reason": "noReading"], "\(name)")
            #expect(exported["tightestWindowId"] is NSNull, "\(name)")
        }
        // The key itself was read: the capped key is measured and keeps its time.
        #expect(try provider("devpass-capped-missing-usage")["measuredAt"] as? String == "2026-10-14T23:58:00.000Z")

        // Missing Kiro overage: that window has no reading; the plan and its primary still do.
        let overage = try window("kiro-overage-missing-usage", "overage")
        #expect(overage["usedFraction"] is NSNull)
        #expect(overage["quantity"] == nil)
        #expect(overage["unavailable"] as? [String: String] == ["reason": "noReading"])
        #expect(overage["eligibleForTightest"] as? Bool == false)
        #expect(quantity(try window("kiro-overage-missing-usage", "monthly")) == ["used": "18.43", "limit": "50", "unit": "credits"])
        #expect((try provider("kiro-overage-missing-usage")["primary"] as? [String: Any])?["type"] as? String == "percentage")
        #expect(quantity(try window("kiro", "overage")) == ["used": "0", "limit": "10000", "unit": "credits"])

        let cycleOnly = try provider("never-measured-with-cycle")
        #expect(cycleOnly["measuredAt"] is NSNull)
        #expect(cycleOnly["primary"] as? [String: String] == ["type": "unavailable", "reason": "noReading"])
        #expect((cycleOnly["status"] as? [String: String])?["reason"] == "offline")
        #expect(try window("never-measured-with-cycle", "cycle")["kind"] as? String == "billingCycle")
        #expect(cycleOnly["tightestWindowId"] is NSNull)
    }

    @Test("incomplete Kiro bonus pools and an unknown Kiro plan split export no reading, as the Kiro builder fills them")
    func kiroIncompleteFiguresExportNoReading() throws {
        let noReading = ["reason": "noReading"]
        let bonusNames = ["kiro-bonus-missing-usage", "kiro-bonus-partial-usage", "kiro-bonus-mismatched-pools"]
        for name in bonusNames {
            let bonus = try window(name, "bonus")
            #expect(bonus["usedFraction"] is NSNull, "\(name)")
            #expect(bonus["quantity"] == nil, "\(name)")
            #expect(bonus["unavailable"] as? [String: String] == noReading, "\(name)")
            #expect(bonus["eligibleForTightest"] as? Bool == false, "\(name)")
            #expect(quantity(try window(name, "monthly")) == ["used": "40", "limit": "50", "unit": "credits"], "\(name)")
            #expect((try provider(name)["primary"] as? [String: Any])?["type"] as? String == "percentage", "\(name)")
            #expect(try provider(name)["tightestWindowId"] as? String == "monthly", "\(name)")
        }

        // Above the plan limit with no overage figure: neither the plan nor the overage is known.
        for id in ["monthly", "overage"] {
            let unknown = try window("kiro-plan-split-unknown", id)
            #expect(unknown["usedFraction"] is NSNull, "\(id)")
            #expect(unknown["quantity"] == nil, "\(id)")
            #expect(unknown["unavailable"] as? [String: String] == noReading, "\(id)")
            #expect(unknown["eligibleForTightest"] as? Bool == false, "\(id)")
        }
        #expect(try provider("kiro-plan-split-unknown")["primary"] as? [String: String]
                == ["type": "unavailable", "reason": "noReading"])
        #expect(try provider("kiro-plan-split-unknown")["tightestWindowId"] is NSNull)
        // The control's reported overage splits the same total.
        #expect(quantity(try window("kiro-plan-split-reported", "monthly")) == ["used": "50", "limit": "50", "unit": "credits"])
        #expect(quantity(try window("kiro-plan-split-reported", "overage")) == ["used": "50", "limit": "1000", "unit": "credits"])
        #expect(try provider("kiro-plan-split-reported")["tightestWindowId"] as? String == "monthly")

        // Each fixture row carries the quantities the Kiro builder fills for that response.
        let built = try ProviderBranchSnapshots.kiroBonuses() + [
            try ProviderBranchSnapshots.kiroEnabledOverage(reported: nil, total: 100),
            try ProviderBranchSnapshots.kiroEnabledOverage(reported: "50.0", total: 100),
        ]
        for (name, snapshot) in zip(bonusNames + ["kiro-plan-split-unknown", "kiro-plan-split-reported"], built) {
            let fixture = try SnapshotFixtures.input(name).snapshots[0]
            for (fixtureRow, builtRow) in [(fixture.row1, snapshot.row1), (fixture.row2, snapshot.row2), (fixture.row3, snapshot.row3)] {
                #expect(fixtureRow?.quantityUsed == builtRow?.quantityUsed, "\(name)")
                #expect(fixtureRow?.quantityLimit == builtRow?.quantityLimit, "\(name)")
                #expect(fixtureRow?.quantityUnit == builtRow?.quantityUnit, "\(name)")
            }
        }
    }

    @Test("fixtures assert each window's exact windowSeconds")
    func fixtureWindowSeconds() throws {
        let cases: [(String, Int, String, Int?)] = [
            ("claude", 0, "5h", 18000), ("claude", 0, "weekly", 604800),
            ("opencode", 0, "5h", 18000), ("opencode", 0, "weekly", 604800), ("opencode", 0, "monthly", nil),
            ("grok-daily", 0, "plan", 86400), ("grok-daily", 0, "on_demand", 86400),
            ("grok-unknown-length", 0, "plan", nil), ("grok-unknown-length", 0, "on_demand", nil),
            // 18000.4 s and 604799.5 s round to the nearest whole second.
            ("openai", 0, "w1", 18000), ("openai", 0, "w2", 604800), ("openai", 0, "w3", nil),
            ("billing-cycle", 0, "cycle", nil), ("billing-cycle", 1, "cycle", nil), ("billing-cycle", 1, "5h", 18000),
            ("kiro", 0, "monthly", 2_592_000), ("kiro", 0, "bonus", nil), ("kiro", 0, "overage", nil),
            ("devpass-percentage", 0, "monthly", 2_678_400), ("devpass-capped-spend", 0, "spend", nil),
            ("commandcode-capped", 0, "5h", 18000), ("commandcode-total", 0, "credits", nil),
            ("github-consolidated", 0, "rest", nil), ("github-graphql-standalone", 0, "graphql", nil),
            ("gemini", 0, "w1", 18000), ("gemini", 0, "w3", nil), ("copilot", 0, "premium", nil),
            ("clinepass", 0, "5h", 18000), ("muse", 0, "weekly", 604800),
        ]
        for (name, index, id, seconds) in cases {
            let value = try window(name, provider: index, id)["windowSeconds"]
            if let seconds {
                #expect(value as? Int == seconds, "\(name) \(id)")
            } else {
                #expect(value is NSNull, "\(name) \(id) should be null")
            }
        }
        // Every window in every fixture has the key, null or a whole number.
        for name in Self.fixtureNames where SnapshotFixtures.expectedDocument(name) != nil {
            for provider in try SnapshotFixtures.document(name)["providers"] as? [[String: Any]] ?? [] {
                for window in provider["windows"] as? [[String: Any]] ?? [] {
                    #expect(window["windowSeconds"] is NSNull || window["windowSeconds"] is Int, "\(name)")
                }
            }
        }
    }

    // MARK: [REQ-MAC-EXPORT](b), [REQ-MAC-BOUNDS](a)(b)(c)

    @Test("only allowlisted fields are exported, and secret-bearing fields never appear")
    func onlyAllowlistedFieldsAreExported() throws {
        for name in Self.fixtureNames {
            guard let data = SnapshotFixtures.expectedDocument(name) else { continue }
            let text = try #require(String(data: data, encoding: .utf8))
            for marker in ["AUXINFO-MARKER", "KEYMASK-MARKER", "proxy-host.lan.internal", "CLI Proxy",
                           "USEDTEXT-MARKER", "RESETTEXT-MARKER", "BADGE-MARKER"] {
                #expect(!text.contains(marker), "\(name) leaks \(marker)")
            }
            for key in ["keyMasked", "cliSource", "auxiliaryInfo", "latencyMs", "badgeText", "usedText", "resetText"] {
                #expect(!text.contains("\"\(key)\""), "\(name) exports \(key)")
            }
            var walker = DocumentWalker(fixture: name)
            walker.walkDocument(try SnapshotFixtures.document(name))
            #expect(walker.problems.isEmpty, "\(walker.problems.prefix(10))")
        }
    }

    @Test("every string obeys its escaped byte limit, and numbers stay in their domains")
    func everyStringAndNumberObeysTheSchemaDomains() throws {
        // The walker in the test above checks limits too; this asserts it
        // really saw the at-limit and over-limit values in field-limits.
        var walker = DocumentWalker(fixture: "field-limits")
        walker.walkDocument(try SnapshotFixtures.document("field-limits"))
        #expect(walker.problems.isEmpty, "\(walker.problems)")
        #expect(walker.longestByLimit[.name] == 64)
        #expect(walker.longestByLimit[.unit] == 32)
        #expect(walker.longestByLimit[.message] == 160)
        #expect(walker.longestByLimit[.eventDetail] == 280)
        #expect(walker.longestByLimit[.url] == 512)
    }

    @Test("macClockOffsetMs is a signed decimal string, and the walker holds every integer to 0…2^53−1")
    func clockOffsetIsASignedDecimalString() throws {
        // stale-retained's Mac clock is 1.5 s behind; the sign survives as text.
        #expect(try SnapshotFixtures.input("stale-retained").macClockOffsetMs == -1500)
        #expect(try SnapshotFixtures.document("stale-retained")["macClockOffsetMs"] as? String == "-1500")
        #expect(try SnapshotFixtures.document("billing-cycle")["macClockOffsetMs"] as? String == "250")
        #expect(try SnapshotFixtures.document("never-measured")["macClockOffsetMs"] is NSNull)
        // Every fixture with a sample exports it as a string.
        for name in Self.fixtureNames where SnapshotFixtures.expectedDocument(name) != nil {
            let offset = try SnapshotFixtures.document(name)["macClockOffsetMs"]
            #expect(offset is NSNull || offset is String, "\(name): \(String(describing: offset))")
        }
        // The walker has no exemption: a signed integer here is a domain violation,
        // and a string must match the decimal pattern.
        func problems(_ offset: Any) throws -> [String] {
            var document = try SnapshotFixtures.document("stale-retained")
            document["macClockOffsetMs"] = offset
            var walker = DocumentWalker(fixture: "offset")
            walker.walkDocument(document)
            return walker.problems
        }
        #expect(try problems(-1500).count == 1)
        #expect(try problems("-1500").isEmpty)
        #expect(try problems("-1.5e3").count == 1)
        #expect(try problems(NSNull()).isEmpty)
        // Past 2^53 − 1 in either direction there is no offset to export.
        let base = SnapshotExportInput(publisherId: "00000000-0000-4000-8000-000000000001", publisherLabel: "Mac",
                                       publishedAt: Date(timeIntervalSince1970: 1_792_022_400), snapshots: [])
        func exportedOffset(_ value: Int) throws -> Any? {
            var input = base
            input.macClockOffsetMs = value
            let data = try SnapshotExporter.export(input).get().data
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])["macClockOffsetMs"]
        }
        #expect(try exportedOffset(-9_007_199_254_740_991) as? String == "-9007199254740991")
        #expect(try exportedOffset(9_007_199_254_740_991) as? String == "9007199254740991")
        #expect(try exportedOffset(-9_007_199_254_740_992) is NSNull)
        #expect(try exportedOffset(0) as? String == "0")
    }

    @Test("cardinality never exceeds 6 windows, 8 API credits per provider, or 100 events")
    func cardinalityNeverExceedsLimits() throws {
        for name in Self.fixtureNames where SnapshotFixtures.expectedDocument(name) != nil {
            let document = try SnapshotFixtures.document(name)
            #expect((document["events"] as? [Any])?.count ?? 0 <= 100, "\(name)")
            for provider in document["providers"] as? [[String: Any]] ?? [] {
                #expect((provider["windows"] as? [Any])?.count ?? 0 <= 6, "\(name)")
                #expect((provider["apiCredits"] as? [Any])?.count ?? 0 <= 8, "\(name)")
            }
        }
        // The inputs that carry more than the limits.
        #expect(try SnapshotFixtures.input("events-selection").events.filter(\.isSurfaced).count > 100)
        #expect((try SnapshotFixtures.document("events-selection")["events"] as? [Any])?.count == 100)
        #expect(try SnapshotFixtures.input("field-limits").snapshots[0].apiCredits.count == 9)
        #expect((try provider("field-limits")["apiCredits"] as? [Any])?.count == 8)
    }

    // MARK: [REQ-MAC-BOUNDS](d)

    @Test("overflow drops events first, then trailing providers, and stays within 256 KB")
    func overflowFixturesDropEventsThenProviders() throws {
        let events = try SnapshotFixtures.document("events-overflow")
        let eventsInput = try SnapshotFixtures.input("events-overflow")
        #expect(events["eventsTruncated"] as? Bool == true)
        #expect(events["providersOmitted"] as? Int == 0)
        let keptEvents = try #require(events["events"] as? [[String: Any]])
        #expect(!keptEvents.isEmpty && keptEvents.count < eventsInput.events.count)
        #expect((events["providers"] as? [Any])?.count == eventsInput.snapshots.count)
        // The newest events survive: oldest are dropped first.
        let newest = eventsInput.events.max { $0.occurredAt < $1.occurredAt }
        #expect(keptEvents.first?["occurredAt"] as? String == newest.map { ExportText.timestamp($0.occurredAt) })

        let providers = try SnapshotFixtures.document("providers-overflow")
        let providersInput = try SnapshotFixtures.input("providers-overflow")
        #expect(providers["eventsTruncated"] as? Bool == true)
        #expect((providers["events"] as? [Any])?.isEmpty == true)
        let kept = try #require(providers["providers"] as? [[String: Any]])
        let omitted = try #require(providers["providersOmitted"] as? Int)
        #expect(omitted > 0 && kept.count + omitted == providersInput.snapshots.count)
        // Trailing providers go; the leading ones stay in Mac order.
        #expect(kept.first?["instanceId"] as? String == SnapshotExportIdentity.digest(providersInput.snapshots[0].id))

        for name in ["events-overflow", "providers-overflow"] {
            let data = try #require(SnapshotFixtures.expectedDocument(name))
            #expect(data.count <= 256 * 1024)
        }
        let result = try SnapshotExporter.export(providersInput).get()
        #expect(result.notice == "Too many providers for sync — hide some on the Mac")
        #expect(try SnapshotExporter.export(eventsInput).get().notice == nil)
    }

    // MARK: [REQ-MAC-BOUNDS](e)

    /// Measures the encoded size of every provider across the fixtures, for
    /// the handoff notes: `swift test --filter providerEncodedSizeReport`.
    /// "Typical" leaves out the synthetic fixtures that fill every field to
    /// its maximum (and repeat that provider dozens of times); "worst" is
    /// exactly those.
    @Test("provider encoded size across fixtures (report for the handoff notes)")
    func providerEncodedSizeReport() throws {
        let synthetic: Set<String> = ["events-overflow", "providers-overflow", "field-limits"]
        var typical: [Int] = []
        var all: [Int] = []
        var worst = (size: 0, fixture: "")
        for name in Self.fixtureNames {
            guard case .success(let document) = SnapshotExporter.export(try SnapshotFixtures.input(name)) else { continue }
            all += document.providerByteCounts
            if !synthetic.contains(name) { typical += document.providerByteCounts }
            if let largest = document.providerByteCounts.max(), largest > worst.size { worst = (largest, name) }
        }
        func median(_ values: [Int]) -> Double {
            let sorted = values.sorted()
            return sorted.count % 2 == 1
                ? Double(sorted[sorted.count / 2])
                : Double(sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        print("SNAPSHOT-SIZE-REPORT typical-median=\(median(typical)) bytes (\(typical.count) providers) "
              + "all-median=\(median(all)) bytes (\(all.count) providers) "
              + "worst=\(worst.size) bytes (\(worst.fixture)) budget=\(SnapshotExporter.maxDocumentBytes) bytes")
        #expect(!typical.isEmpty)
        // Every field at its maximum must still leave room for ~35 providers.
        #expect(worst.size <= SnapshotExporter.maxDocumentBytes / 35)
    }
}

/// Walks an exported document and records every field or value outside the
/// schema: unknown keys, strings over their escaped byte limit or outside
/// their enum, and numbers outside their domain.
struct DocumentWalker {
    let fixture: String
    var problems: [String] = []
    var longestByLimit: [ExportText.Limit: Int] = [:]

    init(fixture: String) { self.fixture = fixture }

    enum Shape { case top, schemaVersion, provider, status, failure, metric, window, quantity, unavailable,
                      credit, event, source, prefs }

    static let keys: [Shape: Set<String>] = [
        .top: ["schemaVersion", "publisherId", "publisherLabel", "publishedAt", "macClockOffsetMs",
               "macClockSampledAt", "providersOmitted", "eventsTruncated", "providers", "events", "notificationPrefs"],
        .schemaVersion: ["major", "minor"],
        .provider: ["instanceId", "vendorId", "displayName", "planName", "status", "measuredAt", "measuredAtTrusted",
                    "lastAttemptAt", "lastPollFailure", "primary", "windows", "tightestWindowId", "apiCredits"],
        .status: ["kind", "reason", "message"],
        .failure: ["reason", "at"],
        .metric: ["type", "usedFraction", "remaining", "limit", "unit", "balance", "spent", "currencyCode",
                  "basis", "tierName", "renewalAt", "reason"],
        .window: ["windowId", "label", "kind", "usedFraction", "quantity", "unavailable", "blocked", "resetsAt",
                  "resetSource", "windowSeconds", "cycleStart", "cycleEnd", "eligibleForTightest"],
        .quantity: ["used", "remaining", "limit", "unit"],
        .unavailable: ["reason"],
        .credit: ["id", "label", "metric", "basis", "detail"],
        .event: ["id", "kind", "vendorId", "instanceId", "title", "detail", "occurredAt", "observedAt", "source", "url"],
        .source: ["kind", "caption"],
        .prefs: ["disabledKinds", "resetAlertVendors"],
    ]

    static let enums: [String: Set<String>] = [
        "vendorId": Set(VendorIdentifier.allCases.map(\.rawValue)),
        "statusKind": ["measured", "unavailable"],
        "reason": ["notConfigured", "credentialRejected", "unsupported", "offline", "timedOut", "badResponse",
                   "rateLimited", "outOfRange", "missingBasis", "noReading"],
        "type": ["percentage", "count", "currency", "credits", "subscription", "unavailable"],
        "windowKind": ["quota", "billingCycle"],
        "resetSource": ["window", "provider", "none"],
        "eventKind": Set(AIEventKind.allCases.map(\.rawValue)),
        "sourceKind": ["quotaPoll", "openRouterCatalog", "vendorFeed", "resetTracker", "statusPage", "accountModels"],
        "basis": ["accountCredit", "keySpendCap", "lifetimeSpend", "prepaidCredit"],
    ]

    nonisolated(unsafe) static let hex32 = /[0-9a-f]{32}/
    nonisolated(unsafe) static let timestamp = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/
    nonisolated(unsafe) static let decimal = /-?\d{1,18}(\.\d{1,8})?/
    nonisolated(unsafe) static let slug = /[a-z0-9_-]{1,32}/
    nonisolated(unsafe) static let uuid = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

    mutating func problem(_ text: String) { problems.append("\(fixture): \(text)") }

    mutating func walkDocument(_ document: [String: Any]) {
        object(document, .top, path: "")
    }

    mutating func object(_ value: Any?, _ shape: Shape, path: String) {
        guard let object = value as? [String: Any] else { return problem("\(path) is not an object") }
        for key in object.keys where !(Self.keys[shape] ?? []).contains(key) {
            problem("\(path).\(key) is not an allowlisted field")
        }
        for (key, child) in object {
            field(key, child, in: shape, path: "\(path).\(key)", parent: object)
        }
    }

    mutating func field(_ key: String, _ value: Any, in shape: Shape, path: String, parent: [String: Any]) {
        if value is NSNull { return }
        if let items = value as? [Any] {
            for (index, item) in items.enumerated() {
                let itemPath = "\(path)[\(index)]"
                switch (shape, key) {
                case (.top, "providers"): object(item, .provider, path: itemPath)
                case (.top, "events"): object(item, .event, path: itemPath)
                case (.provider, "windows"): object(item, .window, path: itemPath)
                case (.provider, "apiCredits"): object(item, .credit, path: itemPath)
                case (.prefs, "disabledKinds"): member(item, "eventKind", path: itemPath)
                case (.prefs, "resetAlertVendors"): member(item, "vendorId", path: itemPath)
                default: problem("\(itemPath) is an unexpected array")
                }
            }
            return
        }
        if value is [String: Any] {
            let child: Shape? = switch (shape, key) {
            case (.top, "schemaVersion"): .schemaVersion
            case (.top, "notificationPrefs"): .prefs
            case (.provider, "status"): .status
            case (.provider, "lastPollFailure"): .failure
            case (.provider, "primary"), (.credit, "metric"): .metric
            case (.window, "quantity"): .quantity
            case (.window, "unavailable"): .unavailable
            case (.event, "source"): .source
            default: nil
            }
            guard let child else { return problem("\(path) is an unexpected object") }
            return object(value, child, path: path)
        }
        if let text = value as? String {
            return string(key, text, in: shape, path: path)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return }
            if CFNumberIsFloatType(number) {
                guard key == "usedFraction", (0...1).contains(number.doubleValue) else {
                    return problem("\(path) = \(number) is not a fraction in 0…1")
                }
                return
            }
            let integer = number.int64Value
            if !(0...ExportText.maxInteger).contains(integer) {
                problem("\(path) = \(integer) is outside 0…2^53−1")
            }
            return
        }
        problem("\(path) has an unexpected value")
    }

    mutating func member(_ value: Any, _ set: String, path: String) {
        guard let text = value as? String, Self.enums[set]?.contains(text) == true else {
            return problem("\(path) = \(value) is not in \(set)")
        }
    }

    mutating func limited(_ text: String, _ limit: ExportText.Limit, path: String) {
        let bytes = ExportText.escapedByteCount(text)
        longestByLimit[limit] = max(longestByLimit[limit] ?? 0, bytes)
        if bytes > limit.rawValue { problem("\(path) is \(bytes) bytes, over \(limit.rawValue)") }
    }

    mutating func matches<Output>(_ text: String, _ pattern: Regex<Output>, path: String) {
        if text.wholeMatch(of: pattern) == nil { problem("\(path) = \(text) has the wrong form") }
    }

    mutating func string(_ key: String, _ text: String, in shape: Shape, path: String) {
        switch (shape, key) {
        case (_, "displayName"), (_, "planName"), (_, "label"), (_, "publisherLabel"), (_, "tierName"):
            limited(text, .name, path: path)
        case (.metric, "unit"), (.quantity, "unit"), (_, "currencyCode"), (.source, "caption"):
            limited(text, .unit, path: path)
        case (.metric, "basis"), (.credit, "basis"):
            limited(text, .unit, path: path)
            member(text, "basis", path: path)
        case (.status, "message"), (.credit, "detail"), (.event, "title"):
            limited(text, .message, path: path)
        case (.event, "detail"):
            limited(text, .eventDetail, path: path)
        case (.event, "url"):
            limited(text, .url, path: path)
            if !text.hasPrefix("https://") { problem("\(path) is not https") }
        case (.provider, "instanceId"), (.credit, "id"), (.event, "id"), (.event, "instanceId"):
            matches(text, Self.hex32, path: path)
        case (_, "publishedAt"), (_, "macClockSampledAt"), (_, "measuredAt"), (_, "lastAttemptAt"), (_, "at"),
             (_, "resetsAt"), (_, "cycleStart"), (_, "cycleEnd"), (_, "renewalAt"), (_, "occurredAt"),
             (_, "observedAt"):
            matches(text, Self.timestamp, path: path)
        case (.metric, "balance"), (.metric, "limit"), (.metric, "spent"),
             (.quantity, "used"), (.quantity, "remaining"), (.quantity, "limit"), (.top, "macClockOffsetMs"):
            matches(text, Self.decimal, path: path)
        case (.top, "publisherId"):
            matches(text, Self.uuid, path: path)
        case (.window, "windowId"), (.provider, "tightestWindowId"):
            matches(text, Self.slug, path: path)
        case (_, "vendorId"):
            member(text, "vendorId", path: path)
        case (.status, "kind"):
            member(text, "statusKind", path: path)
        case (_, "reason"):
            member(text, "reason", path: path)
        case (.metric, "type"):
            member(text, "type", path: path)
        case (.window, "kind"):
            member(text, "windowKind", path: path)
        case (.window, "resetSource"):
            member(text, "resetSource", path: path)
        case (.event, "kind"):
            member(text, "eventKind", path: path)
        case (.source, "kind"):
            member(text, "sourceKind", path: path)
        default:
            problem("\(path) is a string field the byte table does not cover")
        }
    }
}
