import AppKit
import SwiftUI
import Testing
import QuotaBarCore
@testable import QuotaBarUI

// Opt-in offscreen renders of production views. Fixtures never enter a live store.
@Suite("UX renders", .enabled(if: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"] != nil))
@MainActor
struct UXRenderTests {
    private struct FixtureProvider: QuotaProvider {
        let snapshot: QuotaSnapshot
        var vendorId: VendorIdentifier { snapshot.vendorId }
        var displayName: String { snapshot.displayName }
        var category: MetricCategory { snapshot.category }
        var instanceID: String { snapshot.id }
        func fetchSnapshot() async throws -> QuotaSnapshot { snapshot }
    }

    @Test func render() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_791_848_000)
        func snapshot(_ vendor: VendorIdentifier, _ name: String, _ fraction: Double) -> QuotaSnapshot {
            QuotaSnapshot(id: vendor == .opencode ? "opencode.gamma" : vendor.rawValue,
                vendorId: vendor, displayName: name, category: .aiSubscriptions,
                metric: .subscription(tierName: "Review fixture", renewalDate: nil), status: .measured(.none),
                resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: DualBarMetrics(primaryFraction: fraction, expectedPaceFraction: 0.5, label: "WK",
                    usedText: "\(Int(fraction * 100))% used", resetText: "Resets in 3d",
                    resetsAt: now.addingTimeInterval(3.5 * 86400), windowLength: 7 * 86400),
                row2: DualBarMetrics(primaryFraction: 0.2, label: "5H", usedText: "20% used",
                    resetText: "Resets in 1h", resetsAt: now.addingTimeInterval(3600)))
        }
        let snapshots = [snapshot(.claude, "Claude", 0.65), snapshot(.opencode, "OpenCode Go · Gamma workspace", 0.45),
                         snapshot(.commandcode, "Command Code", 0.9)]
        try save(VStack(spacing: 12) {
            Text("Review fixtures · no live account data").font(.caption).foregroundStyle(Theme.outline)
            AdviceSectionView(advice: .evaluate(from: snapshots), onActionTap: {})
            MetricSectionView(category: .aiSubscriptions, snapshots: snapshots, onSelect: { _ in })
            FooterActionsView(summary: .compute(from: snapshots), isRefreshing: false,
                onOpenSettings: {}, onQuit: {}, onRefresh: {})
        }.padding(12).frame(width: 384).background(Theme.surface), name: "popover", directory: directory)
        try save(MetricDetailModalView(snapshot: snapshots[1], readingsLoader: { _, _ in [] },
            eventsLoader: { _, _, _, _, _ in [] }, onClose: {}).frame(width: 384, height: 400),
            name: "inspector-short", directory: directory)
        let history = QuotaHistoryStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        try save(HistoryRootView(liveStore: history, sampleStore: history).frame(width: 640, height: 460),
                 name: "history-minimum", directory: directory)
        let graphQL = QuotaSnapshot(id: "github_graphql", vendorId: .githubGraphql, displayName: "GitHub GraphQL",
            category: .developerLimits, metric: .count(remaining: 600, limit: 1000, unitName: "points"),
            status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.4, label: "GraphQL", usedText: "40% used"))
        let providers = (snapshots + [graphQL]).map { FixtureProvider(snapshot: $0) }
        let store = QuotaStore(manager: QuotaManager(providerFactory: { providers }, displayPreferences: { .default }))
        await store.load()
        try save(DesktopWidgetView(store: store, filters: WidgetFilters(metric: .used, layout: .overview))
            .frame(width: 320, height: 300), name: "widget-used", directory: directory)
        try save(DesktopWidgetView(store: store, filters: WidgetFilters(vendors: [.githubGraphql], metric: .remaining, layout: .overview))
            .frame(width: 320, height: 240), name: "widget-graphql", directory: directory)
        try save(DesktopWidgetView(store: store, filters: WidgetFilters(metric: .remaining, layout: .overview))
            .frame(width: 360, height: 300), name: "widget-two-columns", directory: directory)
        let tokenChart = TokenUsagePresentation.chart(usage: .init(buckets: [
            .init(source: "codex", start: TokenUsagePresentation.window(range: .last24Hours, now: now).since.addingTimeInterval(7200),
                  tokens: 1234, records: 1)
        ], uncountedRecords: ["claude_code": 3]), filters: WidgetFilters(layout: .tokens), hidden: [],
            configured: [.claude, .openai, .gemini, .grok, .kiro], ingestion: .incomplete, now: now)
        try save(TokenUsageChartView(chart: tokenChart, range: .last24Hours).padding(14)
            .frame(width: 320, height: 240).background(Theme.surface), name: "token-caveats", directory: directory)
    }

    private func save<V: View>(_ view: V, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        window.close()
    }
}
