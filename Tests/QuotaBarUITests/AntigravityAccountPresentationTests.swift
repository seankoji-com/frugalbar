import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Antigravity account presentation")
@MainActor
struct AntigravityAccountPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var primary: AntigravityAccount {
        AntigravityAccount(
            id: "agy-account:primary-fixture",
            badge: "1",
            sourceLabel: "This Mac's Google OAuth session",
            fallbackName: "This Mac",
            nickname: "Personal",
            planName: "Google AI Ultra",
            isPrimary: true
        )
    }

    private var secondary: AntigravityAccount {
        AntigravityAccount(
            id: "agy-account:secondary-fixture",
            badge: "2",
            sourceLabel: "CLI Proxy (proxy.example.test) · work@example.test",
            fallbackName: "Account 2",
            nickname: "Work",
            planName: "Google AI Ultra",
            isPrimary: false
        )
    }

    private func makeSnapshot(
        account: AntigravityAccount,
        allowance: GeminiQuotaProvider.Allowance,
        fraction: Double = 0.25,
        plan: String? = "Google AI Ultra"
    ) -> QuotaSnapshot {
        let vendor: VendorIdentifier = switch allowance {
        case .gemini: .gemini
        case .claude: .antigravityClaude
        case .argon:  .antigravityArgon
        }
        var snap = QuotaSnapshot(
            id: account.poolInstanceID(for: allowance),
            vendorId: vendor,
            displayName: vendor.displayName,
            category: .aiSubscriptions,
            metric: .subscription(tierName: plan, renewalDate: nil),
            status: .measured(.none),
            resetsAt: now.addingTimeInterval(3600),
            lastUpdated: now,
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: fraction, label: "5H",
                resetsAt: now.addingTimeInterval(3600), windowLength: 18000),
            planName: plan
        )
        snap.antigravityAccount = account
        return snap
    }

    @Test("single Antigravity account preserves shared headerPlan; multiple accounts suppress headerPlan and label rows")
    func groupingHeaderPlanAndSubtitles() {
        let singleRows = [
            makeSnapshot(account: primary, allowance: .gemini),
            makeSnapshot(account: primary, allowance: .claude)
        ]
        let singleGroup = PopoverRowGrouping.groups(for: singleRows)[0]
        #expect(singleGroup.header == "Antigravity")
        #expect(singleGroup.headerPlan == "Google AI Ultra")
        #expect(singleGroup.suppressPlan)
        #expect(!singleGroup.showAntigravityAccountBadge)

        let multiRows = [
            makeSnapshot(account: primary, allowance: .gemini),
            makeSnapshot(account: primary, allowance: .claude),
            makeSnapshot(account: secondary, allowance: .gemini, fraction: 0.70),
            makeSnapshot(account: secondary, allowance: .claude, fraction: 0.80)
        ]
        let multiGroup = PopoverRowGrouping.groups(for: multiRows)[0]
        #expect(multiGroup.header == "Antigravity")
        #expect(multiGroup.headerPlan == nil)
        #expect(!multiGroup.suppressPlan)
        #expect(multiGroup.showAntigravityAccountBadge)
        #expect(multiGroup.rowSubtitle(for: multiRows[0]) == "Personal · AI Ultra")
        #expect(multiGroup.rowSubtitle(for: multiRows[2]) == "Work · AI Ultra")
    }

    @Test("accessibility label includes account badge and name only in multi-account mode")
    func accessibilityLabelIncludesAccount() {
        let snap = makeSnapshot(account: secondary, allowance: .gemini, fraction: 0.70)
        let singleRow = MetricRowView(snapshot: snap, isGrouped: true, showAntigravityAccountBadge: false, now: now)
        let singleLabel = singleRow.combinedAccessibilityLabel(
            grid: WindowGridPresentation(snapshot: snap, now: now),
            presentation: MetricRowPresentation(snapshot: snap, now: now)
        )
        #expect(!singleLabel.contains("Account 2"))

        let multiRow = MetricRowView(snapshot: snap, isGrouped: true, showAntigravityAccountBadge: true, now: now)
        let multiLabel = multiRow.combinedAccessibilityLabel(
            grid: WindowGridPresentation(snapshot: snap, now: now),
            presentation: MetricRowPresentation(snapshot: snap, now: now)
        )
        #expect(multiLabel.contains("Account 2"))
        #expect(multiLabel.contains("Work"))
        #expect(multiLabel.contains("Gemini"))
    }

    @Test("HistoryOverviewPresentation emits per-account subjects with legacy key continuity and proxy-only fallback")
    func historySubjectsAndLegacyContinuity() {
        let subjects = HistoryOverviewPresentation.subjects(
            order: [.gemini, .antigravityClaude, .antigravityArgon],
            hidden: [],
            workspaces: [],
            claudeAccounts: [],
            antigravityAccounts: [primary, secondary]
        )
        #expect(subjects.count == 6)

        let geminiSubjects = subjects.filter { $0.vendor == .gemini }
        #expect(geminiSubjects.count == 2)
        #expect(geminiSubjects[0].name == "Gemini · Personal")
        #expect(geminiSubjects[0].keys.contains("gemini"))
        #expect(geminiSubjects[1].name == "Gemini · Work")
        #expect(!geminiSubjects[1].keys.contains("gemini"))

        let claudeSubjects = subjects.filter { $0.vendor == .antigravityClaude }
        #expect(claudeSubjects[0].keys.contains("antigravity_claude"))
        #expect(!claudeSubjects[1].keys.contains("antigravity_claude"))

        let argonSubjects = subjects.filter { $0.vendor == .antigravityArgon }
        #expect(argonSubjects[0].keys.contains("antigravity_argon"))
        #expect(!argonSubjects[1].keys.contains("antigravity_argon"))

        // Proxy-only accounts keep an unattributed fallback subject for legacy readings.
        let proxyOnlySubjects = HistoryOverviewPresentation.subjects(
            order: [.gemini],
            hidden: [],
            workspaces: [],
            claudeAccounts: [],
            antigravityAccounts: [secondary]
        )
        #expect(proxyOnlySubjects.count == 2)
        #expect(proxyOnlySubjects.contains { $0.id == "gemini" && $0.name == "Gemini (unattributed)" })
    }

    @Test("widget Overview tiles and AggregateBurndown series distinguish multi-account Antigravity labels")
    func widgetMultiAccountLabels() {
        let snaps = [
            makeSnapshot(account: primary, allowance: .gemini, fraction: 0.25),
            makeSnapshot(account: secondary, allowance: .gemini, fraction: 0.75)
        ]
        let tiles = OverviewPresentation.tiles(snapshots: snaps, filters: WidgetFilters())
        #expect(tiles.map(\.name) == ["Gemini · Personal", "Gemini · Work"])

        let readings = [
            QuotaHistoryStore.ReadingRecord(
                vendor: primary.poolInstanceID(for: .gemini), barLabel: "5H",
                measuredAt: now.addingTimeInterval(-600), fraction: 0.25, isBlocked: false,
                confidence: .measured, urgency: .none, resetsAt: now.addingTimeInterval(3600),
                windowLength: 18000, elapsedOnly: false),
            QuotaHistoryStore.ReadingRecord(
                vendor: secondary.poolInstanceID(for: .gemini), barLabel: "5H",
                measuredAt: now.addingTimeInterval(-600), fraction: 0.75, isBlocked: false,
                confidence: .measured, urgency: .none, resetsAt: now.addingTimeInterval(3600),
                windowLength: 18000, elapsedOnly: false)
        ]
        let series = AggregateBurndownPresentation.series(
            readings: readings,
            snapshots: snaps,
            filters: WidgetFilters(),
            now: now
        )
        #expect(series.map(\.displayName) == ["Gemini · Personal", "Gemini · Work"])
    }

    @Test(
        "render Antigravity multi-account screenshots",
        .enabled(if: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"] != nil)
    )
    func renderAntigravityScreenshots() async throws {
        let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func savePNG<V: View>(_ view: V, width: CGFloat, name: String) async throws {
            let framed = view
                .frame(width: width)
                .padding(14)
                .background(Theme.surface)
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: framed)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: dir.appendingPathComponent("\(name).png"))
            window.close()
        }

        // 1. Multi-account popover card (Personal + Work, including 403 restriction example)
        let workRestricted = AntigravityAccount(
            id: "agy-account:tertiary-fixture",
            badge: "3",
            sourceLabel: "CLI Proxy (proxy.example.test) · lab@example.test",
            fallbackName: "Account 3",
            nickname: "Lab",
            planName: "Google AI Pro",
            isPrimary: false
        )
        var restrictedSnap = QuotaSnapshot(
            id: workRestricted.poolInstanceID(for: .gemini),
            vendorId: .gemini,
            displayName: "Gemini",
            category: .aiSubscriptions,
            metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
            status: .unavailable(.unsupported("Google account verification required")),
            resetsAt: nil,
            lastUpdated: now,
            auxiliaryInfo: nil,
            planName: "Google AI Pro"
        )
        restrictedSnap.antigravityAccount = workRestricted

        let multiSnaps = [
            makeSnapshot(account: primary, allowance: .gemini, fraction: 0.22, plan: "Google AI Ultra"),
            makeSnapshot(account: primary, allowance: .claude, fraction: 0.45, plan: "Google AI Ultra"),
            makeSnapshot(account: primary, allowance: .argon, fraction: 0.10, plan: "Google AI Ultra"),
            makeSnapshot(account: secondary, allowance: .gemini, fraction: 0.78, plan: "Google AI Pro"),
            makeSnapshot(account: secondary, allowance: .claude, fraction: 0.61, plan: "Google AI Pro"),
            restrictedSnap
        ]
        try await savePNG(
            MetricSectionView(category: .aiSubscriptions, snapshots: multiSnaps, now: now),
            width: 390,
            name: "agy-popover-multi-account"
        )

        // 2. Single-account popover card (unchanged single-account look)
        let singleSnaps = [
            makeSnapshot(account: primary, allowance: .gemini, fraction: 0.22, plan: "Google AI Ultra"),
            makeSnapshot(account: primary, allowance: .claude, fraction: 0.45, plan: "Google AI Ultra"),
            makeSnapshot(account: primary, allowance: .argon, fraction: 0.10, plan: "Google AI Ultra")
        ]
        try await savePNG(
            MetricSectionView(category: .aiSubscriptions, snapshots: singleSnaps, now: now),
            width: 390,
            name: "agy-popover-single-account"
        )

        // 3. Settings — Antigravity accounts nickname editor
        try await savePNG(
            Form {
                AntigravityAccountSettingsView(
                    accounts: [primary, secondary],
                    load: nil,
                    saveNickname: { _, _ in }
                )
            }
            .formStyle(.grouped)
            .frame(height: 360),
            width: 480,
            name: "agy-settings-accounts"
        )
    }
}
