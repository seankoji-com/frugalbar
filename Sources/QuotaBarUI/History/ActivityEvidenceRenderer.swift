import AppKit
import SwiftUI
import Foundation
import QuotaBarCore

/// Controlled-data evidence for the activity accounting behaviour.
///
/// This is a production seam, not a test helper: a downloaded `frugalbar`
/// executable can be launched with `FRUGALBAR_ACTIVITY_EVIDENCE_DIR` set and
/// will render these views from a throwaway store, write PNG and accessibility
/// artefacts, and exit before the menu bar or any poll starts. It never opens
/// the live history database, preferences or credentials, and it injects no
/// quota.
public enum ActivityEvidenceRenderer {

    public static let environmentKey = "FRUGALBAR_ACTIVITY_EVIDENCE_DIR"

    /// What the controlled render actually contained, so a caller can assert
    /// the released binary drew the same figures rather than only producing a
    /// file.
    public struct Report: Sendable, Equatable {
        public let chartTotalTokens: Int
        public let chartLayers: [String]
        public let hasSessionTotals: Bool
        public let sourceNotes: [String]
        public let openAIProjects: [String]
        public let openCodeProjects: [String]
        public let openCodeUnattributedMessage: String

        public init(
            chartTotalTokens: Int,
            chartLayers: [String],
            hasSessionTotals: Bool,
            sourceNotes: [String],
            openAIProjects: [String],
            openCodeProjects: [String],
            openCodeUnattributedMessage: String
        ) {
            self.chartTotalTokens = chartTotalTokens
            self.chartLayers = chartLayers
            self.hasSessionTotals = hasSessionTotals
            self.sourceNotes = sourceNotes
            self.openAIProjects = openAIProjects
            self.openCodeProjects = openCodeProjects
            self.openCodeUnattributedMessage = openCodeUnattributedMessage
        }
    }

    public enum RenderError: Error, LocalizedError {
        case missingDirectory
        case imageEncodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingDirectory:
                "\(ActivityEvidenceRenderer.environmentKey) is not set."
            case .imageEncodingFailed(let name):
                "Could not encode the controlled render \(name)."
            }
        }
    }

    /// The controlled ledger's clock. It is explicit and fixed for the
    /// production evidence route, so the same binary renders the same figures
    /// at any local hour, date or daylight-saving transition: both days are
    /// already behind the reference before any view is built.
    public struct Fixture: Sendable, Equatable {
        public let referenceDate: Date
        public let calendar: Calendar
        public let dayOne: Date
        public let dayTwo: Date
        public let claudeObservedAt: Date
        public let openCodeObservedAt: Date

        /// Derives two local 10:00 days that are strictly before `reference`.
        /// Calendar arithmetic (not fixed 24-hour steps) is what keeps this
        /// true across a daylight-saving transition.
        public static func around(reference: Date, calendar: Calendar) -> Fixture {
            let todayTen = calendar.date(
                bySettingHour: 10, minute: 0, second: 0, of: reference
            ) ?? reference
            let dayTwo = todayTen < reference
                ? todayTen
                : calendar.date(byAdding: .day, value: -1, to: todayTen) ?? todayTen
            let dayOne = calendar.date(byAdding: .day, value: -1, to: dayTwo) ?? dayTwo
            return Fixture(
                referenceDate: reference,
                calendar: calendar,
                dayOne: dayOne,
                dayTwo: dayTwo,
                claudeObservedAt: reference.addingTimeInterval(-3600),
                openCodeObservedAt: reference.addingTimeInterval(-1800))
        }

        /// 2026-10-20T12:00:00Z with both requests on 2026-10-19 and
        /// 2026-10-20 at 10:00Z. A fixed instant, not `Date()`, so a morning
        /// run cannot omit the second day's observation.
        public static let standard: Fixture = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            return Fixture.around(
                reference: Date(timeIntervalSince1970: 1_792_497_600), calendar: calendar)
        }()
    }

    /// Renders every controlled view to `directory` and returns what was drawn.
    @MainActor
    public static func render(
        to directory: URL,
        fixture: Fixture = .standard
    ) async throws -> Report {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("frugalbar-activity-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let now = fixture.referenceDate
        let calendar = fixture.calendar
        let dayOne = fixture.dayOne
        let dayTwo = fixture.dayTwo
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let codexDir = fixtureRoot.appendingPathComponent("codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let rollout = """
        {"type":"session_meta","timestamp":"\(iso.string(from: dayOne.addingTimeInterval(-60)))","payload":{"session_id":"fixture-session","cwd":"/controlled/codex-alpha","model_provider":"openai","creator_account_id":"fixture-account"}}
        {"type":"turn_context","timestamp":"\(iso.string(from: dayOne.addingTimeInterval(-30)))","payload":{"model":"gpt-6.1-sol","cwd":"/controlled/codex-alpha"}}
        {"type":"token_usage_record","timestamp":"\(iso.string(from: dayOne))","payload":{"session_id":"fixture-session","thread_id":"fixture-session","response_id":"fixture-day-one","turn_id":"fixture-turn-one","usage":{"input_tokens":700000,"cached_input_tokens":650000,"cache_write_input_tokens":0,"output_tokens":300000,"reasoning_output_tokens":0,"total_tokens":1000000},"thread_token_usage":{"input_tokens":700000,"output_tokens":300000,"total_tokens":1000000}}}
        {"type":"turn_context","timestamp":"\(iso.string(from: dayTwo.addingTimeInterval(-30)))","payload":{"model":"gpt-5.6-luna","cwd":"/controlled/codex-beta"}}
        {"type":"token_usage_record","timestamp":"\(iso.string(from: dayTwo))","payload":{"session_id":"fixture-session","thread_id":"fixture-session","response_id":"fixture-day-two","turn_id":"fixture-turn-two","usage":{"input_tokens":70000,"cached_input_tokens":65000,"cache_write_input_tokens":0,"output_tokens":30000,"reasoning_output_tokens":0,"total_tokens":100000},"thread_token_usage":{"input_tokens":770000,"output_tokens":330000,"total_tokens":1100000}}}
        """
        try rollout.write(
            to: codexDir.appendingPathComponent("rollout-fixture.jsonl"),
            atomically: true, encoding: .utf8)

        let store = QuotaHistoryStore(
            databaseURL: fixtureRoot.appendingPathComponent("history.sqlite3"), isTestHost: true)
        let engine = ActivityIngestionEngine(store: store, adapters: [CodexAdapter(baseURL: codexDir)])
        _ = try await engine.ingestAll()

        // Claude adds its components. OpenCode publishes a provider and model
        // but no account/workspace, so it must not be assigned to one.
        try await store.recordActivities([
            ActivityRecord(
                source: "claude_code", recordId: "fixture-claude", sessionId: "fixture-claude-session",
                projectPath: "/controlled/claude", gitBranch: "main", model: "claude-sonnet",
                observedAt: fixture.claudeObservedAt,
                inputTokens: 10, outputTokens: 20, cacheReadTokens: 5, cacheWriteTokens: 15),
            ActivityRecord(
                source: "opencode", recordId: "fixture-opencode", sessionId: "fixture-opencode-session",
                projectPath: "/controlled/opencode", model: "gpt-5.6-luna",
                observedAt: fixture.openCodeObservedAt,
                inputTokens: 100, outputTokens: 20, cacheReadTokens: 5, cacheWriteTokens: 2,
                totalTokens: 127, billingProvider: "litellm"),
        ])

        let statuses = [
            ActivitySourceStatus(source: "codex", lastScanAt: now, lastSuccessfulScanAt: now,
                                 malformedRecords: 1, incompleteRecords: 0,
                                 recordsObserved: 2, lastPassComplete: true),
            ActivitySourceStatus(source: "claude_code", lastScanAt: now, lastSuccessfulScanAt: now,
                                 recordsObserved: 1, lastPassComplete: true),
            ActivitySourceStatus(source: "opencode", lastScanAt: now, lastSuccessfulScanAt: now,
                                 recordsObserved: 1, lastPassComplete: true),
        ]
        let status = ActivityIngestionEngine.Status(
            hasCompletedCleanPass: true, lastPassIncomplete: false, isRunning: false, sources: statuses)

        let window = TokenUsagePresentation.window(range: .last7Days, now: now, calendar: calendar)
        let usage = try await store.fetchTokenUsage(
            since: window.since, until: now,
            bucketSeconds: TokenUsagePresentation.bucketSeconds(for: .last7Days), anchor: window.anchor)
        let chart = TokenUsagePresentation.chart(
            usage: usage, filters: WidgetFilters(range: .last7Days, layout: .tokens), hidden: [],
            configured: [.claude, .openai, .opencode], ingestion: .complete, now: now,
            calendar: calendar, sources: statuses)
        try await save(
            VStack(spacing: 8) {
                Text("Controlled ledger · Codex request rows across two days and mixed models; OpenCode billed through litellm, not a Go workspace")
                    .font(.caption).foregroundStyle(Theme.outline)
                TokenUsageChartView(chart: chart, range: .last7Days)
            }.padding(14).frame(width: 420, height: 300).background(Theme.surface),
            name: "activity-tokens-ledger", directory: directory)

        let openAI = HistoryOverviewPresentation.Subject(
            id: VendorIdentifier.openai.rawValue, vendor: .openai,
            name: VendorIdentifier.openai.displayName)
        let openCode = HistoryOverviewPresentation.Subject(
            id: "opencode.fixture-workspace", vendor: .opencode,
            name: "OpenCode Go · Fixture workspace")
        let statusLoader: @Sendable () async -> ActivityIngestionEngine.Status? = { status }

        try await save(
            HistoryRootView(
                liveStore: store, sampleStore: store, initialRange: .last7Days,
                subjectSource: { ([openAI], []) }, activityStatus: statusLoader)
                .frame(width: 880, height: 820),
            name: "activity-attribution-openai", directory: directory)
        try await save(
            HistoryRootView(
                liveStore: store, sampleStore: store, initialRange: .last7Days,
                subjectSource: { ([openCode], []) }, activityStatus: statusLoader)
                .frame(width: 880, height: 820),
            name: "activity-attribution-opencode", directory: directory)

        let activities = try await store.fetchActivities(since: window.since, until: now)
        let openAIAttribution = AttributionEngine.computeAttribution(
            windowStart: window.since, windowEnd: now,
            startConsumptionFraction: nil, endConsumptionFraction: nil,
            activities: activities.filter { $0.source == "codex" })
        let openCodeAttribution = AttributionEngine.computeAttribution(
            windowStart: window.since, windowEnd: now,
            startConsumptionFraction: nil, endConsumptionFraction: nil,
            activities: activities.filter { $0.source == "opencode" },
            billingScope: .matchingPublishedIdentity(AttributionBillingTarget()))

        return Report(
            chartTotalTokens: chart.totalTokens,
            chartLayers: chart.layers.map(\.vendorId.rawValue),
            hasSessionTotals: chart.hasSessionTotals,
            sourceNotes: chart.sourceNotes,
            openAIProjects: openAIAttribution.projectAttributions.map(\.projectPath),
            openCodeProjects: openCodeAttribution.projectAttributions.map(\.projectPath),
            openCodeUnattributedMessage: HistoryPresentation.activityEmptyMessage(
                .complete,
                vendorName: openCode.vendor.displayName,
                recordsWithoutTokenTotals: openCodeAttribution.recordsWithoutTokenTotals,
                recordsWithoutMatchingBillingIdentity:
                    openCodeAttribution.recordsWithoutMatchingBillingIdentity))
    }

    /// Runs the renderer for the environment variable, then terminates the
    /// process. Called from the app's entry point before the GUI starts.
    @MainActor
    public static func runFromEnvironmentAndExit() -> Never {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey], !raw.isEmpty else {
            FileHandle.standardError.write(Data("\(environmentKey) is not set.\n".utf8))
            exit(64)
        }
        let directory = URL(fileURLWithPath: raw)
        // The hosted views are AppKit objects; create the application object
        // but never run it, so no delegate, status item or poll starts.
        _ = NSApplication.shared
        var finished = false
        var code: Int32 = 1
        Task { @MainActor in
            do {
                let report = try await render(to: directory)
                print("RENDERED total=\(report.chartTotalTokens) layers=\(report.chartLayers.joined(separator: ",")) openai=\(report.openAIProjects.joined(separator: ",")) opencode=\(report.openCodeProjects.joined(separator: ","))")
                print("OPENCODE_MESSAGE \(report.openCodeUnattributedMessage)")
                code = 0
            } catch {
                FileHandle.standardError.write(Data("activity evidence render failed: \(error)\n".utf8))
            }
            finished = true
        }
        // The app has not started its run loop yet; drive the main queue just
        // long enough for the hosted views and ingestion to finish.
        while !finished {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        exit(code)
    }

    // MARK: - Rendering

    @MainActor
    private static func save<V: View>(
        _ view: V,
        name: String,
        directory: URL
    ) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderError.imageEncodingFailed(name)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.imageEncodingFailed(name)
        }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        let accessibility = accessibilityDump(host)
        try accessibility.joined(separator: "\n").write(
            to: directory.appendingPathComponent("\(name)-accessibility.txt"),
            atomically: true, encoding: .utf8)
        window.close()
    }

    private static func accessibilityDump(_ object: Any, depth: Int = 0) -> [String] {
        guard depth < 16, let element = object as? NSAccessibilityProtocol else { return [] }
        let role = element.accessibilityRole()?.rawValue ?? "unknown"
        let label = element.accessibilityLabel() ?? ""
        var lines = [String(repeating: "  ", count: depth) + role + ": " + label]
        for child in element.accessibilityChildren() ?? [] {
            lines += accessibilityDump(child, depth: depth + 1)
        }
        return lines
    }
}
