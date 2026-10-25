import AppKit
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("OpenCode Go Plus decoration")
@MainActor
struct OpenCodeGoPlusTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        name: String = "Gamma", vendor: VendorIdentifier = .opencode,
        plan: String? = "OpenCode Go Plus", blocked: Bool = false
    ) -> QuotaSnapshot {
        QuotaSnapshot(id: "opencode-go:\(name)", vendorId: vendor, displayName: name,
            category: .aiSubscriptions, metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(blocked ? .critical : .none), resetsAt: nil,
            lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: blocked ? 1 : 0.2, label: "MO",
                                 isBlocked: blocked, resetText: blocked ? "Resets in 1 day" : nil),
            planName: plan)
    }

    @Test("only an explicitly identified OpenCode Go Plus plan gets the badge")
    func badgeRequiresConfirmedPlan() {
        #expect(PopoverRowGrouping.planBadge(for: snapshot()) == "Plus")
        for plan: String? in [nil, "", "OpenCode Go", "Go", "Plus", "OpenCode Go Plus Preview"] {
            #expect(PopoverRowGrouping.planBadge(for: snapshot(plan: plan)) == nil)
        }
        #expect(PopoverRowGrouping.planBadge(for: snapshot(vendor: .openai)) == nil)
    }

    @Test("the production title draws the violet badge at the real name width",
          arguments: [false, true])
    func renderedBadge(blocked: Bool) throws {
        func violetPixels(plan: String?) throws -> Int {
            let row = MetricRowView(snapshot: snapshot(plan: plan, blocked: blocked), isGrouped: true)
            let host = NSHostingView(rootView: row.titleView
                .frame(width: Theme.nameColumnWidth, alignment: .leading)
                .background(Theme.card).environment(\.colorScheme, .dark))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width == 112)
            #expect(host.fittingSize.height < 24)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.blueComponent - color.greenComponent > 0.14,
                       color.redComponent - color.greenComponent > 0.04,
                       color.blueComponent > 0.3 { count += 1 }
                }
            }
            return count
        }
        #expect(try violetPixels(plan: "OpenCode Go Plus") > 10)
        #expect(try violetPixels(plan: "OpenCode Go") == 0)
        #expect(try violetPixels(plan: nil) == 0)
    }

    @Test("mixed tiers retain one OpenCode Go heading, reset text and a spoken Plus plan")
    func mixedPlansAndAccessibility() {
        let plain = snapshot(name: "Delta", plan: "OpenCode Go")
        let plus = snapshot(blocked: true)
        let groups = PopoverRowGrouping.groups(for: [plain, plus])
        #expect(groups.count == 1)
        #expect(groups[0].header == "OpenCode Go")
        #expect(groups[0].suppressPlan)
        #expect(PopoverRowGrouping.subtitle(for: plain, suppressPlan: true,
            presentation: MetricRowPresentation(snapshot: plain, now: now)).isEmpty)
        #expect(PopoverRowGrouping.subtitle(for: plus, suppressPlan: true,
            presentation: MetricRowPresentation(snapshot: plus, now: now)) == "Resets in 1 day")
        let row = MetricRowView(snapshot: plus, isGrouped: true)
        let label = row.combinedAccessibilityLabel(grid: WindowGridPresentation(snapshot: plus, now: now),
            presentation: MetricRowPresentation(snapshot: plus, now: now))
        #expect(label.hasPrefix("OpenCode Go Plus. "))
        #expect(label.contains("Gamma"))
        #expect(label.lowercased().contains("blocked"))
    }
}
