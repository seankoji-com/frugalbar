import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import QuotaBarCore
import QuotaBarUI

/// Isolated, fixture-backed live native harness that exercises the production
/// `AppDelegate` -> `NSStatusItem` -> `NSPopover` -> `PopoverInspection`
/// (`popoverShouldClose`) lifecycle on-screen without touching Keychain,
/// `com.quotabar.app` preferences, live history storage, or the network.
@MainActor
final class LiveGlanceHarness {

    static let directoryEnvKey = "FRUGALBAR_LIVE_HARNESS_DIR"
    static let scenariosEnvKey = "FRUGALBAR_LIVE_HARNESS_SCENARIOS"

    static var outputDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment[directoryEnvKey], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private struct FixtureProvider: QuotaProvider {
        let snapshot: QuotaSnapshot
        var vendorId: VendorIdentifier { snapshot.vendorId }
        var displayName: String { snapshot.displayName }
        var category: MetricCategory { snapshot.category }
        var instanceID: String { snapshot.id }
        func fetchSnapshot() async throws -> QuotaSnapshot { snapshot }
    }

    private final class FixtureSource: @unchecked Sendable {
        private let lock = NSLock()
        private var _snapshots: [QuotaSnapshot] = []
        private var _failBalances = false
        private var _failEvents = false
        private var _failMarkers = false

        var snapshots: [QuotaSnapshot] {
            get { lock.withLock { _snapshots } }
            set { lock.withLock { _snapshots = newValue } }
        }

        var failBalances: Bool {
            get { lock.withLock { _failBalances } }
            set { lock.withLock { _failBalances = newValue } }
        }

        var failEvents: Bool {
            get { lock.withLock { _failEvents } }
            set { lock.withLock { _failEvents = newValue } }
        }

        var failMarkers: Bool {
            get { lock.withLock { _failMarkers } }
            set { lock.withLock { _failMarkers = newValue } }
        }
    }

    private struct Report: Codable {
        let gitHead: String
        let statusItemTitle: String
        let statusItemAccessibilityLabel: String
        let statusItemClicked: Bool
        let popoverOpened: Bool
        let rowExpanded: Bool
        let inspectorOpened: Bool
        let escape1ClosedInspectorOnly: Bool
        let escape2ClosedPopover: Bool
        let captureMethod: String
        let captures: [String]
        let menuBarStates: [MenuBarStateSummary]
    }

    private struct MenuBarStateSummary: Codable {
        let state: String
        let text: String
        let tone: String
        let accessibilityLabel: String
    }

    let outputDir: URL
    let tempDir: URL
    let historyStore: QuotaHistoryStore
    let manager: QuotaManager
    let store: QuotaStore
    private let fixtureSource = FixtureSource()
    private let now = Date()

    init(outputDir: URL) {
        self.outputDir = outputDir
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("frugalbar-live-harness-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.tempDir = tmp

        let hStore = QuotaHistoryStore(
            databaseURL: tmp.appendingPathComponent("history.sqlite3"),
            isTestHost: true
        )
        self.historyStore = hStore

        let source = self.fixtureSource
        let manager = QuotaManager(
            providerFactory: {
                source.snapshots.map { FixtureProvider(snapshot: $0) }
            },
            displayPreferences: { .default }
        )
        self.manager = manager

        self.store = QuotaStore(
            manager: manager,
            historyRecorder: nil,
            readingsLoader: { since in
                (try? await hStore.fetchReadings(since: since)) ?? []
            },
            vendorReadingsLoader: { vendor, since in
                try? await hStore.fetchReadings(vendor: vendor, since: since)
            },
            eventsLoader: { vendor, instanceId, kinds, since, limit in
                if limit == nil && source.failMarkers { return nil }
                if limit != nil && source.failEvents { return nil }
                return try? await hStore.fetchEvents(
                    vendor: vendor, instanceID: instanceId, kinds: kinds, since: since, limit: limit
                )
            },
            tokenUsageLoader: nil,
            balanceSeriesLoader: { since, until, bucketSeconds, seriesIds in
                if source.failBalances { return nil }
                return try? await hStore.fetchBalanceSeries(
                    since: since, until: until, bucketSeconds: bucketSeconds, seriesIds: seriesIds
                )
            },
            activityStatusLoader: nil
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func run(
        statusItem: NSStatusItem,
        popover: NSPopover,
        inspection: PopoverInspection,
        applyStatusItemPresentation: @escaping @MainActor () -> Void
    ) async -> Int32 {
        defer { cleanup() }
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try requireAccessibilityClient()

            let primaryBatch = makePrimaryFixtureBatch()
            fixtureSource.snapshots = primaryBatch
            try await seedHistory(for: primaryBatch)
            await store.forceRefresh(allowInteractiveUnlock: false)
            applyStatusItemPresentation()
            pumpEvents(seconds: 0.3)

            guard let button = statusItem.button else {
                throw HarnessError("NSStatusItem.button is nil")
            }
            let statusTitle = button.attributedTitle.string.trimmingCharacters(in: .whitespaces)
            let statusLabel = button.accessibilityLabel() ?? ""
            guard !statusTitle.isEmpty, !statusLabel.isEmpty else {
                throw HarnessError("Status item missing title or accessibility label")
            }

            var captures: [String] = []
            var captureMethod = "screencapture-window"
            var statusItemClicked = false
            var popoverOpened = false
            var rowExpanded = false
            var inspectorOpened = false
            var escape1ClosedInspectorOnly = false
            var escape2ClosedPopover = false

            // 1. Real status-item click -> Popover open
            button.performClick(nil)
            statusItemClicked = true
            try waitUntil(timeout: 5.0, description: "NSPopover to open after status-item click") {
                popover.isShown && popover.contentViewController?.view.window != nil
            }
            popoverOpened = popover.isShown
            guard let popoverWindow = popover.contentViewController?.view.window else {
                throw HarnessError("NSPopover window is nil after opening")
            }
            try waitUntilVisible(popoverWindow, timeout: 3.0)
            NSApp.activate(ignoringOtherApps: true)
            popoverWindow.makeKeyAndOrderFront(nil)
            pumpEvents(seconds: 0.45)

            let (collapsedPath, method1) = try captureWindow(popoverWindow, name: "live-popover-collapsed")
            captureMethod = method1
            captures.append(collapsedPath)

            // 2. Row expand via Accessibility (Claude group)
            guard axPress(where: { $0.hasPrefix("Claude,") }) else {
                let seen = axSampleLabels(limit: 20).joined(separator: " | ")
                throw HarnessError("Could not AXPress Claude group row to expand (seen: \(seen))")
            }
            pumpEvents(seconds: 0.45)
            guard axFind(where: { $0.hasPrefix("Primary") }) else {
                throw HarnessError("Expanded Claude group did not expose Primary account row")
            }
            rowExpanded = true
            let (expandedPath, _) = try captureWindow(popoverWindow, name: "live-popover-expanded-claude")
            captures.append(expandedPath)

            // 3. Inline inspector open via Accessibility (Primary account row)
            guard axPress(where: { $0.hasPrefix("Primary") }) else {
                throw HarnessError("Could not AXPress Primary account row to open inspector")
            }
            try await waitUntilAsync(timeout: 5.0, description: "Inline inspector to open") {
                inspection.snapshot != nil && popover.isShown
            }
            inspectorOpened = inspection.snapshot != nil
            await pumpEventsAsync(seconds: 0.9)
            let (inspectorPath, _) = try captureWindow(popoverWindow, name: "live-inspector-open")
            captures.append(inspectorPath)

            // 4. Escape #1: MUST close inspector while NSPopover stays open (no close-button fallback)
            NSApp.activate(ignoringOtherApps: true)
            popoverWindow.makeKeyAndOrderFront(nil)
            await pumpEventsAsync(seconds: 0.15)
            try sendEscape(to: popoverWindow)
            try await waitUntilAsync(timeout: 3.0, description: "Escape #1 to close inline inspector") {
                inspection.snapshot == nil
            }
            guard popover.isShown else {
                throw HarnessError("Escape #1 closed the entire NSPopover instead of only the inspector")
            }
            escape1ClosedInspectorOnly = inspection.snapshot == nil && popover.isShown
            await pumpEventsAsync(seconds: 0.2)
            let (afterEsc1Path, _) = try captureWindow(popoverWindow, name: "live-after-escape-1")
            captures.append(afterEsc1Path)

            // 5. Escape #2: MUST close NSPopover
            NSApp.activate(ignoringOtherApps: true)
            popoverWindow.makeKeyAndOrderFront(nil)
            await pumpEventsAsync(seconds: 0.15)
            try sendEscape(to: popoverWindow)
            try await waitUntilAsync(timeout: 3.0, description: "Escape #2 to close NSPopover") {
                !popover.isShown
            }
            escape2ClosedPopover = !popover.isShown

            // 6. State-matrix live captures (when scenarios != "core")
            let scenarioMode = ProcessInfo.processInfo.environment[Self.scenariosEnvKey] ?? "all"
            if scenarioMode != "core" {
                try await captureStateMatrix(
                    button: button,
                    popover: popover,
                    inspection: inspection,
                    applyStatusItemPresentation: applyStatusItemPresentation,
                    captures: &captures
                )
            }

            let menuStates = try await sampleLiveMenuBarStates(
                button: button,
                applyStatusItemPresentation: applyStatusItemPresentation
            )
            let report = Report(
                gitHead: ProcessInfo.processInfo.environment["FRUGALBAR_GIT_HEAD"] ?? "unknown",
                statusItemTitle: statusTitle,
                statusItemAccessibilityLabel: statusLabel,
                statusItemClicked: statusItemClicked,
                popoverOpened: popoverOpened,
                rowExpanded: rowExpanded,
                inspectorOpened: inspectorOpened,
                escape1ClosedInspectorOnly: escape1ClosedInspectorOnly,
                escape2ClosedPopover: escape2ClosedPopover,
                captureMethod: captureMethod,
                captures: captures,
                menuBarStates: menuStates
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: outputDir.appendingPathComponent("live-harness-report.json"))
            print("LIVE-HARNESS PASS captures=\(captures.count) method=\(captureMethod) escape1=inspector_only escape2=popover_closed")
            return 0
        } catch {
            FileHandle.standardError.write(Data("LIVE-HARNESS FAIL: \(error)\n".utf8))
            return 1
        }
    }

    private func captureStateMatrix(
        button: NSStatusBarButton,
        popover: NSPopover,
        inspection: PopoverInspection,
        applyStatusItemPresentation: @escaping @MainActor () -> Void,
        captures: inout [String]
    ) async throws {
        // Re-open popover for state-matrix captures
        button.performClick(nil)
        try waitUntil(timeout: 5.0, description: "NSPopover to reopen for state matrix") {
            popover.isShown && popover.contentViewController?.view.window != nil
        }
        guard let popoverWindow = popover.contentViewController?.view.window else {
            throw HarnessError("NSPopover window missing on reopen")
        }
        try waitUntilVisible(popoverWindow, timeout: 3.0)
        NSApp.activate(ignoringOtherApps: true)
        popoverWindow.makeKeyAndOrderFront(nil)
        await pumpEventsAsync(seconds: 0.35)

        // Inspector: Balance sparkline trend (OpenRouter)
        guard let openRouter = store.snapshots.first(where: { $0.id == "openrouter" }) else {
            throw HarnessError("OpenRouter fixture snapshot missing for balance inspector captures")
        }
        fixtureSource.failBalances = false
        inspection.snapshot = openRouter
        await pumpEventsAsync(seconds: 0.7)
        guard axFindText(where: { $0.localizedCaseInsensitiveContains("Balance history") }),
              !axFindText(where: { $0.contains("Could not read the recorded balance") }) else {
            let seen = axSampleLabels(limit: 20).joined(separator: " | ")
            throw HarnessError("Balance trend inspector did not render healthy Balance history (seen: \(seen))")
        }
        captures.append(try captureWindow(popoverWindow, name: "live-inspector-balance-trend").0)
        inspection.snapshot = nil
        await pumpEventsAsync(seconds: 0.25)

        // Inspector: Balance readFailed
        fixtureSource.failBalances = true
        inspection.snapshot = openRouter
        NSApp.activate(ignoringOtherApps: true)
        popoverWindow.makeKeyAndOrderFront(nil)
        await pumpEventsAsync(seconds: 0.7)
        guard axFindText(where: { $0.contains("Could not read the recorded balance") }) else {
            let seen = axSampleLabels(limit: 20).joined(separator: " | ")
            throw HarnessError("Balance readFailed inspector did not render BalanceCardState.readFailed message (seen: \(seen))")
        }
        captures.append(try captureWindow(popoverWindow, name: "live-inspector-balance-read-failed").0)
        inspection.snapshot = nil
        fixtureSource.failBalances = false
        await pumpEventsAsync(seconds: 0.25)

        // Inspector: History with markersFailed
        guard let claude = store.snapshots.first(where: { $0.vendorId == .claude }) else {
            throw HarnessError("Claude fixture snapshot missing for History markersFailed capture")
        }
        fixtureSource.failMarkers = true
        inspection.snapshot = claude
        NSApp.activate(ignoringOtherApps: true)
        popoverWindow.makeKeyAndOrderFront(nil)
        await pumpEventsAsync(seconds: 0.7)
        guard axPress(where: { $0 == "History" }) else {
            let seen = axSampleLabels(limit: 20).joined(separator: " | ")
            throw HarnessError("Could not AXPress History tab in inline inspector (seen: \(seen))")
        }
        await pumpEventsAsync(seconds: 0.6)
        guard axFindText(where: { $0.contains("Reset markers could not be read") }) else {
            let seen = axSampleLabels(limit: 20).joined(separator: " | ")
            throw HarnessError("History inspector did not render markersFailed warning banner (seen: \(seen))")
        }
        captures.append(try captureWindow(popoverWindow, name: "live-inspector-history-markers-failed").0)
        inspection.snapshot = nil
        fixtureSource.failMarkers = false
        await pumpEventsAsync(seconds: 0.25)

        // Popover: Stale + Exhausted + Blocked + Elevated Developer Limits
        try await replaceSnapshots(makeStaleExhaustedDevLimitsBatch(), applyStatusItemPresentation: applyStatusItemPresentation)
        await pumpEventsAsync(seconds: 0.6)
        guard axFindText(where: { $0.contains("GitHub REST") }),
              axFindText(where: { $0.contains("1 stale") }),
              axFindText(where: { $0.contains("OpenAI") || $0.contains("Codex") }),
              axFindText(where: { $0.localizedCaseInsensitiveContains("spent") || $0.contains("100%") || $0.contains("0% left") }),
              axFindText(where: { $0.contains("DeepSeek") || $0.contains("OpenCode") }) else {
            let seen = axSampleLabels(limit: 25).joined(separator: " | ")
            throw HarnessError("Stale/Exhausted/DevLimits state did not render expected indicators (seen: \(seen))")
        }
        captures.append(try captureWindow(popoverWindow, name: "live-popover-stale-exhausted-devlimits").0)

        // Popover: edge states the judge found only in source until now — a
        // window whose reset passed with no reading since, a bonus-only pick,
        // a spent pool whose return is owed, and an account-wide block.
        try await replaceSnapshots(makeEdgeStateBatch(), applyStatusItemPresentation: applyStatusItemPresentation)
        await pumpEventsAsync(seconds: 0.6)
        // Expand the Claude group so its awaiting-reading row is on screen.
        _ = axPress { $0.hasPrefix("Claude") }
        await pumpEventsAsync(seconds: 0.4)
        guard axFindText(where: { $0.contains("On bonus allowance") }),
              axFindText(where: { $0.localizedCaseInsensitiveContains("awaiting") }),
              axFindText(where: { $0.contains("blocked") }) else {
            let seen = axSampleLabels(limit: 25).joined(separator: " | ")
            throw HarnessError("Edge-state popover did not render its bonus, awaiting-reading and blocked states (seen: \(seen))")
        }
        captures.append(try captureWindow(popoverWindow, name: "live-popover-edge-states").0)

        // Popover: Empty / all-hidden
        try await replaceSnapshots([], applyStatusItemPresentation: applyStatusItemPresentation)
        await pumpEventsAsync(seconds: 0.5)
        guard axFindText(where: { $0.contains("Nothing to show") }) else {
            throw HarnessError("Empty popover state did not render 'Nothing to show' (stale rows remained)")
        }
        captures.append(try captureWindow(popoverWindow, name: "live-popover-empty").0)

        popover.performClose(nil)
        await pumpEventsAsync(seconds: 0.3)
    }

    /// Clears all cached readings in `QuotaManager` before refreshing the next
    /// fixture batch so replacement batches never inherit earlier providers or
    /// hit `minPollInterval`.
    private func replaceSnapshots(
        _ snapshots: [QuotaSnapshot],
        applyStatusItemPresentation: @escaping @MainActor () -> Void
    ) async throws {
        for vendor in VendorIdentifier.allCases {
            await manager.forgetReadings(of: vendor)
        }
        fixtureSource.snapshots = snapshots
        await store.forceRefresh(allowInteractiveUnlock: false)
        applyStatusItemPresentation()
    }

    // MARK: - Fixtures

    private func bar(_ label: String, _ used: Double?, resetsInHours: Double?, windowHours: Double?,
                     blocked: Bool = false, role: AllowanceRole = .plan) -> DualBarMetrics {
        let reset = resetsInHours.map { now.addingTimeInterval($0 * 3600) }
        let length = windowHours.map { $0 * 3600 }
        let pace = length.flatMap { DualBarMetrics.proRataPace(resetsAt: reset, windowLength: $0, now: now) }
        return DualBarMetrics(primaryFraction: used, expectedPaceFraction: pace, label: label,
                              isBlocked: blocked, allowanceRole: role, resetsAt: reset, windowLength: length)
    }

    private func makePrimaryFixtureBatch() -> [QuotaSnapshot] {
        let primary = ClaudeAccount(id: "claude-primary", badge: "1", sourceLabel: "fixture",
                                    fallbackName: "Primary", planName: "Max (20x)")
        let secondary = ClaudeAccount(id: "claude-secondary", badge: "2", sourceLabel: "fixture",
                                      fallbackName: "Secondary")
        let burner = AntigravityAccount(id: "agy-burner", badge: "1", sourceLabel: "Google OAuth (this Mac)",
                                        fallbackName: "Account 1", planName: "Google AI Pro")
        let account2 = AntigravityAccount(id: "agy-account-2", badge: "2", sourceLabel: "CLI Proxy (localhost)",
                                          fallbackName: "Account 2", planName: "Google AI Pro")

        var claudePrimary = QuotaSnapshot(
            id: "claude-account:\(primary.id)", vendorId: .claude, displayName: primary.name,
            category: .aiSubscriptions, metric: .subscription(tierName: primary.planName, renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("5H", 0.14, resetsInHours: 3.2, windowHours: 5),
            row2: bar("WK", 0.58, resetsInHours: 112, windowHours: 168),
            planName: primary.planName
        )
        claudePrimary.claudeAccount = primary
        claudePrimary.resetCreditsAvailable = 1
        claudePrimary.resetCreditGroups = [
            ResetCreditGroup(scope: .model("Fable"), count: 1, expiries: [now.addingTimeInterval(42 * 86_400)])
        ]
        claudePrimary.scopedBars = [bar("Fable", 0.18, resetsInHours: 112, windowHours: 168)]
        claudePrimary.monthlyAPICredit = try? ClaudeMonthlyCredit.decode(Data(
            #"{"status":"linked","monthly_credit_usd":"200","next_grant_at":"2027-02-11T00:00:00Z"}"#.utf8),
            now: now
        )

        var claudeSecondary = QuotaSnapshot(
            id: "claude-account:\(secondary.id)", vendorId: .claude, displayName: secondary.name,
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("5H", 0.0, resetsInHours: nil, windowHours: 5),
            row2: bar("WK", 1.0, resetsInHours: 52, windowHours: 168)
        )
        claudeSecondary.claudeAccount = secondary

        var gemini1 = QuotaSnapshot(
            id: "\(burner.id):gemini", vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions, metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
            status: .measured(.warning), resetsAt: nil, lastUpdated: now,
            auxiliaryInfo: "Models within this group: Gemini 4 Neon, Gemini 4 Hydrogen",
            row1: bar("5H", 0.06, resetsInHours: 4.1, windowHours: 5),
            row2: bar("WK", 0.72, resetsInHours: 132, windowHours: 168),
            planName: "Google AI Pro"
        )
        gemini1.antigravityAccount = burner
        gemini1.cliSource = "Google OAuth (this Mac)"
        gemini1.geminiAPICredit = GeminiAPICredit(currencyCode: "AUD", monthlySpendCap: 25,
                                                  configuredAt: now.addingTimeInterval(-3 * 86_400))

        var gemini2 = QuotaSnapshot(
            id: "\(account2.id):gemini", vendorId: .gemini, displayName: "Gemini",
            category: .aiSubscriptions, metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("5H", 0.0, resetsInHours: 5.0, windowHours: 5),
            row2: bar("WK", 0.28, resetsInHours: 148, windowHours: 168),
            planName: "Google AI Pro"
        )
        gemini2.antigravityAccount = account2
        gemini2.cliSource = "CLI Proxy (localhost)"

        var openai = QuotaSnapshot(
            id: "openai", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("5H", 0.12, resetsInHours: 4.0, windowHours: 5),
            row2: bar("WK", 0.34, resetsInHours: 120, windowHours: 168),
            planName: "Pro"
        )
        openai.apiCredits = [APICreditEntry(
            id: "openai.api-credits", vendorId: .openai, label: "Usage credits",
            metric: .credits(remaining: 44_135, unitName: "credits"),
            creditGrant: OpenAICreditGrant(
                total: 62_500, expiresAt: now.addingTimeInterval(37 * 86_400),
                grantedAt: now.addingTimeInterval(-55 * 86_400)
            )
        )]
        openai.openAIMonthlyCredit = OpenAIMonthlyCredit(
            grantUSD: 100, remainingUSD: 64,
            periodStart: now.addingTimeInterval(-4 * 86_400),
            periodEnd: now.addingTimeInterval(26 * 86_400),
            measuredAt: now
        )

        var opencodeBlocked = QuotaSnapshot(
            id: "opencode-go:alpha", vendorId: .opencode, displayName: "Alpha",
            category: .aiSubscriptions, metric: .subscription(tierName: "OpenCode Go", renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("5H", 0.0, resetsInHours: 5.0, windowHours: 5),
            row2: bar("WK", 0.0, resetsInHours: 159, windowHours: 168),
            badgeText: "Blocked", planName: "OpenCode Go"
        )
        opencodeBlocked.row3 = bar("MO", 1.0, resetsInHours: 39.2, windowHours: 720, blocked: true)

        let openRouter = QuotaSnapshot(
            id: "openrouter", vendorId: .openrouter, displayName: "OpenRouter",
            category: .apiSpendAndCredits,
            metric: .currency(balance: Decimal(string: "18.42")!, limit: nil, spent: nil, currencyCode: "USD"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: "Account credit",
            row1: nil, row2: nil
        )

        let deepseekFailed = QuotaSnapshot(
            id: "deepseek", vendorId: .deepseek, displayName: "DeepSeek",
            category: .apiSpendAndCredits,
            metric: .subscription(tierName: nil, renewalDate: nil),
            status: .unavailable(.offline), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: nil, row2: nil
        )

        return [claudePrimary, claudeSecondary, gemini1, gemini2, openai, opencodeBlocked, openRouter, deepseekFailed]
    }

    private func makeStaleExhaustedDevLimitsBatch() -> [QuotaSnapshot] {
        var usableClaude = QuotaSnapshot(
            id: "claude-account:mixed-usable", vendorId: .claude, displayName: "Primary",
            category: .aiSubscriptions, metric: .subscription(tierName: "Max", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("5H", 0.12, resetsInHours: 3.5, windowHours: 5),
            row2: bar("WK", 0.42, resetsInHours: 112, windowHours: 168),
            planName: "Max"
        )
        usableClaude.claudeAccount = ClaudeAccount(id: "mixed-usable", badge: "1", sourceLabel: "fixture", fallbackName: "Primary", planName: "Max")

        var spentClaude = QuotaSnapshot(
            id: "claude-account:mixed-spent", vendorId: .claude, displayName: "Secondary",
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("WK", 1.0, resetsInHours: 40, windowHours: 168)
        )
        spentClaude.claudeAccount = ClaudeAccount(id: "mixed-spent", badge: "2", sourceLabel: "fixture", fallbackName: "Secondary")

        var staleClaude = QuotaSnapshot(
            id: "claude-account:stale", vendorId: .claude, displayName: "Tertiary",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.warning), resetsAt: nil, lastUpdated: now.addingTimeInterval(-1800),
            auxiliaryInfo: nil,
            row1: bar("WK", 0.65, resetsInHours: 80, windowHours: 168),
            planName: "Pro"
        )
        staleClaude.claudeAccount = ClaudeAccount(id: "stale", badge: "3", sourceLabel: "fixture", fallbackName: "Tertiary", planName: "Pro")
        staleClaude.staleReading = StaleReading(reason: .rateLimited(retryAfter: now.addingTimeInterval(300)), at: now)

        let spentOpenAI = QuotaSnapshot(
            id: "openai-spent", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("WK", 1.0, resetsInHours: 28, windowHours: 168),
            planName: "Pro"
        )

        var opencodeBlocked = QuotaSnapshot(
            id: "opencode-go:blocked-batch", vendorId: .opencode, displayName: "Alpha",
            category: .aiSubscriptions, metric: .subscription(tierName: "OpenCode Go", renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("5H", 0.0, resetsInHours: 5.0, windowHours: 5),
            row2: bar("WK", 0.0, resetsInHours: 159, windowHours: 168),
            badgeText: "Blocked", planName: "OpenCode Go"
        )
        opencodeBlocked.row3 = bar("MO", 1.0, resetsInHours: 39.2, windowHours: 720, blocked: true)

        let githubElevated = QuotaSnapshot(
            id: "githubRest", vendorId: .githubRest, displayName: "GitHub REST",
            category: .developerLimits, metric: .percentage(usedFraction: 0.84, displayDetails: "4,200 / 5,000"),
            status: .measured(.warning), resetsAt: now.addingTimeInterval(1800), lastUpdated: now,
            auxiliaryInfo: nil,
            row1: bar("1H", 0.84, resetsInHours: 0.5, windowHours: 1)
        )

        return [usableClaude, spentClaude, staleClaude, spentOpenAI, opencodeBlocked, githubElevated]
    }

    /// No current plan anywhere, so the pick is Kiro's bonus (a caveat pick):
    /// Claude's weekly window reset an hour ago with no reading since, Codex is
    /// spent with a reset that passed, and Command Code is blocked on its badge.
    private func makeEdgeStateBatch() -> [QuotaSnapshot] {
        var expiredClaude = QuotaSnapshot(
            id: "claude-account:edge-expired", vendorId: .claude, displayName: "Primary",
            category: .aiSubscriptions, metric: .subscription(tierName: "Max", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: now.addingTimeInterval(-7200), auxiliaryInfo: nil,
            row1: bar("WK", 0.45, resetsInHours: -1, windowHours: 168),
            planName: "Max"
        )
        expiredClaude.claudeAccount = ClaudeAccount(id: "edge-expired", badge: "1", sourceLabel: "fixture",
                                                    fallbackName: "Primary", planName: "Max")

        let kiroOnBonus = QuotaSnapshot(
            id: "kiro", vendorId: .kiro, displayName: "Kiro",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("MO", 1.0, resetsInHours: 300, windowHours: 720),
            row2: bar("BN", 0.3, resetsInHours: 100, windowHours: nil, role: .bonus),
            planName: "Pro"
        )

        let codexResetPassed = QuotaSnapshot(
            id: "openai-reset-passed", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now.addingTimeInterval(-3600), auxiliaryInfo: nil,
            row1: bar("WK", 1.0, resetsInHours: -0.5, windowHours: 168),
            planName: "Pro"
        )

        let commandLimited = QuotaSnapshot(
            id: "commandcode", vendorId: .commandcode, displayName: "Command Code",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("5H", 0.2, resetsInHours: 3, windowHours: 5),
            row2: bar("WK", 0.4, resetsInHours: 50, windowHours: 168),
            badgeText: QuotaSnapshot.accountBlockedBadge, planName: "Pro"
        )

        return [expiredClaude, kiroOnBonus, codexResetPassed, commandLimited]
    }

    private func sampleLiveMenuBarStates(
        button: NSStatusBarButton,
        applyStatusItemPresentation: @escaping @MainActor () -> Void
    ) async throws -> [MenuBarStateSummary] {
        let primary = makePrimaryFixtureBatch()
        let weak = QuotaSnapshot(
            id: "weak", vendorId: .opencode, displayName: "Low",
            category: .aiSubscriptions, metric: .subscription(tierName: "Go", renewalDate: nil),
            status: .measured(.warning), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("WK", 0.88, resetsInHours: 100, windowHours: 168)
        )
        let spent = QuotaSnapshot(
            id: "spent", vendorId: .openai, displayName: "OpenAI",
            category: .aiSubscriptions, metric: .subscription(tierName: "Pro", renewalDate: nil),
            status: .measured(.critical), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: bar("WK", 1.0, resetsInHours: 38, windowHours: 168)
        )
        let cases: [(String, [QuotaSnapshot])] = [
            ("normal", primary),
            ("caveat", [weak]),
            ("critical", [spent]),
            ("unknown", []),
        ]
        var summaries: [MenuBarStateSummary] = []
        for (name, snaps) in cases {
            try await replaceSnapshots(snaps, applyStatusItemPresentation: applyStatusItemPresentation)
            await pumpEventsAsync(seconds: 0.15)
            let p = MenuBarGlance.presentation(snapshots: store.snapshots, now: Date())
            let liveTitle = button.attributedTitle.string.trimmingCharacters(in: .whitespaces)
            let liveLabel = button.accessibilityLabel() ?? ""
            let observedTone = String(describing: p.tone)
            guard !liveTitle.isEmpty, !liveLabel.isEmpty else {
                throw HarnessError("Live NSStatusItem missing title or accessibility label for tone \(name)")
            }
            guard observedTone == name else {
                throw HarnessError("MenuBarGlance tone mismatch for \(name): got \(observedTone)")
            }
            guard liveTitle == p.text else {
                throw HarnessError("Live NSStatusItem title mismatch for \(name): live='\(liveTitle)' expected='\(p.text)'")
            }
            guard liveLabel == p.accessibilityLabel else {
                throw HarnessError("Live NSStatusItem label mismatch for \(name): live='\(liveLabel)' expected='\(p.accessibilityLabel)'")
            }
            summaries.append(MenuBarStateSummary(
                state: name,
                text: liveTitle,
                tone: observedTone,
                accessibilityLabel: liveLabel
            ))
        }
        guard Set(summaries.map(\.tone)).count == cases.count else {
            throw HarnessError("MenuBar state matrix did not cover all \(cases.count) distinct tones")
        }
        return summaries
    }

    private func seedHistory(for batch: [QuotaSnapshot]) async throws {
        // Record 12 readings over the last 6 hours so Burndown & History charts render real points
        for i in 0..<12 {
            let t = now.addingTimeInterval(-Double(11 - i) * 1800)
            let updated = batch.compactMap { snap -> QuotaSnapshot? in
                if snap.id == "openrouter" { return nil }
                var copy = snap
                if copy.vendorId == .claude, var wk = copy.row2, let frac = wk.primaryFraction {
                    let earlier = max(0.05, frac - Double(11 - i) * 0.018)
                    wk = DualBarMetrics(
                        primaryFraction: earlier, expectedPaceFraction: wk.expectedPaceFraction,
                        label: wk.label, resetsAt: wk.resetsAt, windowLength: wk.windowLength
                    )
                    copy.row2 = wk
                }
                return copy
            }
            try await historyStore.record(updated, now: t)
        }
        // Spread OpenRouter balance readings across 12 days so the 30d balance sparkline draws a real trend
        if let orSnap = batch.first(where: { $0.id == "openrouter" }) {
            for i in 0..<12 {
                let dayT = now.addingTimeInterval(-Double(11 - i) * 86_400)
                // Ends at the live reading ($18.42), so the headline balance
                // and the chart's last point are the same figure.
                let val = Decimal(string: "23.92")! - Decimal(i) * Decimal(string: "0.50")!
                let point = QuotaSnapshot(
                    id: orSnap.id, vendorId: orSnap.vendorId, displayName: orSnap.displayName,
                    category: orSnap.category,
                    metric: .currency(balance: val, limit: nil, spent: nil, currencyCode: "USD"),
                    status: orSnap.status, resetsAt: nil, lastUpdated: dayT, auxiliaryInfo: orSnap.auxiliaryInfo,
                    row1: nil, row2: nil
                )
                try await historyStore.record([point], now: dayT)
            }
        }
        let resetEvent = AIEvent(
            id: AIEvent.makeID(kind: .usageReset, vendorId: .claude, components: ["live-harness-reset"]),
            kind: .usageReset, vendorId: .claude, instanceId: "claude-account:claude-primary",
            title: "5-hour window reset", detail: "Allowance reset to 0% used",
            occurredAt: now.addingTimeInterval(-7200), observedAt: now.addingTimeInterval(-7200),
            source: .quotaPoll
        )
        _ = try await historyStore.recordEvents([resetEvent])
    }

    // MARK: - AppKit & AX Helpers

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { self.description = message }
    }

    private func requireAccessibilityClient() throws {
        guard AXIsProcessTrusted() else {
            throw HarnessError("AXIsProcessTrusted() is false; grant Accessibility to the runner host")
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true {
            throw HarnessError("Screen is locked; live native harness requires an unlocked desktop")
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            throw HarnessError("Display is asleep; live native harness requires an awake display")
        }
    }

    private func pumpEvents(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02),
                inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func pumpEventsAsync(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            while let event = NSApp.nextEvent(
                matching: .any, until: .distantPast,
                inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitUntilAsync(timeout: TimeInterval, description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await pumpEventsAsync(seconds: 0.05)
        }
        throw HarnessError("Timed out waiting for \(description)")
    }

    private func waitUntil(timeout: TimeInterval, description: String, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            pumpEvents(seconds: 0.05)
        }
        throw HarnessError("Timed out waiting for \(description)")
    }

    private func waitUntilVisible(_ window: NSWindow, timeout: TimeInterval) throws {
        try waitUntil(timeout: timeout, description: "NSPopover window to become visible") {
            window.occlusionState.contains(.visible)
        }
    }

    private func sendEscape(to window: NSWindow) throws {
        let pid = getpid()
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) {
            down.postToPid(pid)
            up.postToPid(pid)
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53
            ) else {
                throw HarnessError("Failed to synthesize Escape NSEvent")
            }
            window.sendEvent(event)
        }
    }

    private func axFind(where match: (String) -> Bool) -> Bool {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 3)
        for _ in 0..<8 {
            if Self.element(in: app, where: match) != nil {
                return true
            }
            pumpEvents(seconds: 0.15)
        }
        return false
    }

    private func axFindText(where match: (String) -> Bool) -> Bool {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 3)
        for _ in 0..<6 {
            var queue = Self.rootElements(from: app)
            var visited = 0
            while !queue.isEmpty, visited < 5_000 {
                let element = queue.removeFirst()
                visited += 1
                for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                       let text = value as? String, match(text) {
                        return true
                    }
                }
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                queue += (children as? [AXUIElement]) ?? []
            }
            pumpEvents(seconds: 0.15)
        }
        return false
    }

    private func axPress(where match: (String) -> Bool) -> Bool {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 3)
        for _ in 0..<8 {
            if let element = Self.element(in: app, where: match),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                pumpEvents(seconds: 0.25)
                return true
            }
            pumpEvents(seconds: 0.15)
        }
        return false
    }

    private func axSampleLabels(limit: Int) -> [String] {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 3)
        var labels: [String] = []
        var queue = Self.rootElements(from: app)
        var visited = 0
        while !queue.isEmpty, visited < 1_000, labels.count < limit {
            let element = queue.removeFirst()
            visited += 1
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let text = value as? String, !text.isEmpty {
                    labels.append(text)
                    break
                }
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            queue += (children as? [AXUIElement]) ?? []
        }
        return labels
    }

    private static func rootElements(from app: AXUIElement) -> [AXUIElement] {
        var roots: [AXUIElement] = [app]
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement] {
            roots.append(contentsOf: list)
        }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let win = focused {
            roots.append(win as! AXUIElement)
        }
        return roots
    }

    private static func element(in root: AXUIElement, where match: (String) -> Bool) -> AXUIElement? {
        var queue = rootElements(from: root)
        var visited = 0
        while !queue.isEmpty, visited < 5_000 {
            let element = queue.removeFirst()
            visited += 1
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let text = value as? String, match(text) {
                    return element
                }
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            queue += (children as? [AXUIElement]) ?? []
        }
        return nil
    }

    private func captureWindow(_ window: NSWindow, name: String) throws -> (String, String) {
        let outURL = outputDir.appendingPathComponent("\(name).png")
        let windowID = window.windowNumber
        if windowID > 0 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(windowID), outURL.path]
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
               let size = attrs[.size] as? Int, size > 1_000 {
                return (outURL.path, "screencapture-window")
            }
        }
        // Fallback to live window content view backing capture if Screen Recording is unavailable
        guard let contentView = window.contentView else {
            throw HarnessError("No contentView on NSPopover window for \(name)")
        }
        contentView.layoutSubtreeIfNeeded()
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            throw HarnessError("Failed to allocate bitmap for \(name)")
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw HarnessError("Failed to encode PNG for \(name)")
        }
        try png.write(to: outURL)
        return (outURL.path, "window-cacheDisplay")
    }
}
