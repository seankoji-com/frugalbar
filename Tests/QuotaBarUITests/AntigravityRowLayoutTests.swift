import AppKit
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Antigravity row layout")
@MainActor
struct AntigravityRowLayoutTests {
    @Test("the shared pool icon contains Claude and Gemini halves with a divider")
    func sharedPoolIconHalves() throws {
        func bitmap(_ vendor: VendorIdentifier) throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: VendorAvatarView(vendorId: vendor, status: .healthy, size: 28)
                .background(Theme.surface).environment(\.colorScheme, .dark))
            host.frame.size = CGSize(width: 28, height: 28)
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            return image
        }
        let split = try bitmap(.antigravityClaude)
        let claude = try bitmap(.claude)
        let gemini = try bitmap(.gemini)
        var differentFromClaude = 0
        var differentFromGemini = 0
        var dividerPixels = 0
        for y in 0..<split.pixelsHigh {
            for x in 0..<split.pixelsWide {
                func difference(_ other: NSBitmapImageRep) throws -> CGFloat {
                    let a = try #require(split.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let b = try #require(other.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                        + abs(a.blueComponent - b.blueComponent)
                }
                let fromClaude = try difference(claude)
                let fromGemini = try difference(gemini)
                if fromClaude > 0.1 { differentFromClaude += 1 }
                if fromGemini > 0.1 { differentFromGemini += 1 }
                let diagonal = x + y - split.pixelsWide
                if diagonal < -3 { #expect(fromClaude < 0.05) }
                if diagonal > 3 { #expect(fromGemini < 0.05) }
                if abs(diagonal) < 2 && fromClaude > 0.1 && fromGemini > 0.1 { dividerPixels += 1 }
            }
        }
        #expect(differentFromClaude > 20)
        #expect(differentFromGemini > 20)
        #expect(dividerPixels > 10)
    }

    @Test("grouped titles fit the 112pt name column without truncation at 384pt")
    func groupedTitlesFit() {
        let titles: [(VendorIdentifier, String)] = [(.gemini, "Gemini"), (.antigravityArgon, "Argon"),
            (.antigravityClaude, "Claude"), (.claude, "Claude Code"), (.openai, "Codex")]
        for (vendor, title) in titles {
            let snap = QuotaSnapshot(id: vendor.rawValue, vendorId: vendor, displayName: vendor.displayName,
                category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
                status: .measured(.none), resetsAt: nil,
                lastUpdated: Date(timeIntervalSince1970: 1_700_000_000), auxiliaryInfo: nil)
            let row = MetricRowView(snapshot: snap, isGrouped: true)
            #expect(PopoverRowGrouping.rowTitle(for: snap) == title)
            let actual = NSHostingView(rootView: row.titleView.frame(width: Theme.nameColumnWidth))
            let full = NSHostingView(rootView: Text(title).font(Theme.Typography.subtitle)
                .fixedSize(horizontal: false, vertical: true).frame(width: Theme.nameColumnWidth))
            actual.layoutSubtreeIfNeeded()
            full.layoutSubtreeIfNeeded()
            #expect(abs(actual.fittingSize.height - full.fittingSize.height) < 1)
            #expect(actual.fittingSize.width == 112)
            if vendor == .antigravityClaude { #expect(actual.fittingSize.height < 25) }
        }
        #expect(Theme.popoverWidth - 2 * Theme.edgeMargin - 2 * Theme.cardPadding == 332)
        #expect(Theme.rowAvatarSize + 2 * Theme.rowSpacing + Theme.nameColumnWidth + 176 == 332)
    }

    @Test("the row's composed accessibility label retains service, pool, usage and failure")
    func composedAccessibilityLabels() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for status: ProviderStatus in [.measured(.warning), .unavailable(.badResponse)] {
            let snapshot = QuotaSnapshot(id: "antigravity_claude", vendorId: .antigravityClaude,
                displayName: "AGY Claude/GPT", category: .aiSubscriptions,
                metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
                status: status, resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: status.confidence == .measured ? DualBarMetrics(primaryFraction: 0.8, label: "5H") : nil)
            let row = MetricRowView(snapshot: snapshot, isGrouped: true)
            let label = row.combinedAccessibilityLabel(grid: WindowGridPresentation(snapshot: snapshot, now: now),
                presentation: MetricRowPresentation(snapshot: snapshot, now: now))
            #expect(label.hasPrefix("Antigravity shared Claude/GPT pool. "))
            #expect(label.contains("AGY Claude/GPT"))
            if status.confidence == .measured { #expect(label.contains("80")) }
            else { #expect(label.contains("Unexpected response")) }
        }
    }

    @Test("the shared Claude/GPT name gets room to wrap at the real row width")
    func sharedPoolTitleWraps() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func rowHeight(name: String) -> CGFloat {
            let snapshot = QuotaSnapshot(id: "antigravity_claude", vendorId: .antigravityClaude,
                displayName: name, category: .aiSubscriptions,
                metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
                status: .measured(.none), resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
                row1: DualBarMetrics(primaryFraction: 0.2, label: "5H"),
                row2: DualBarMetrics(primaryFraction: 0.4, label: "WK"), planName: "Google AI Pro")
            let host = NSHostingView(rootView: MetricRowView(snapshot: snapshot)
                .frame(width: Theme.popoverWidth - 2 * Theme.edgeMargin - 2 * Theme.cardPadding))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        // Measure the production view, not a copy of its Text modifiers. The
        // previous one-line truncation gives both names the same row height.
        #expect(rowHeight(name: "AGY Claude/GPT") > rowHeight(name: "AGY Claude") + 8)
    }
}
