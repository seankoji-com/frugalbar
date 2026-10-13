import Testing
import Foundation
import AppKit
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("Inspector presentation")
struct MetricDetailPresentationTests {

    private let now = Date(timeIntervalSince1970: 1_791_848_000)

    private func snapshot(
        status: ProviderStatus = .measured(.none),
        metric: MetricType = .percentage(usedFraction: 0.42, displayDetails: nil),
        bars: [DualBarMetrics] = [],
        plan: String? = nil
    ) -> QuotaSnapshot {
        var s = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: metric, status: status, resetsAt: nil, lastUpdated: now.addingTimeInterval(-180),
            auxiliaryInfo: nil,
            row1: bars.count > 0 ? bars[0] : nil, row2: bars.count > 1 ? bars[1] : nil)
        s.planName = plan
        return s
    }

    /// A weekly window with a published reset and length: the pace tick is
    /// drawn, so a verdict may be given.
    private func weekly(used: Double?, elapsed: Double, isBlocked: Bool = false) -> DualBarMetrics {
        let length = 7 * 86_400.0
        return DualBarMetrics(
            primaryFraction: used, expectedPaceFraction: elapsed, label: "WK", isBlocked: isBlocked,
            resetsAt: now.addingTimeInterval(length * (1 - elapsed)), windowLength: length)
    }

    @Test("the summary leads with state, the busiest window's share and its reset")
    func summaryLeadsWithMeasuredFigures() {
        let five = DualBarMetrics(primaryFraction: 0.2, label: "5H", resetsAt: now.addingTimeInterval(3600),
                                  windowLength: 5 * 3600)
        let p = MetricDetailPresentation(snapshot: snapshot(bars: [weekly(used: 0.6, elapsed: 0.5), five]), now: now)

        #expect(p.summary.state == .healthy)
        #expect(p.summary.symbol == "checkmark.circle.fill")
        #expect(p.summary.focusLabel == "WK")
        #expect(p.summary.percentUsed == 60)
        #expect(p.summary.resetText?.hasPrefix("Resets") == true)
        #expect(p.summary.paceVerdict?.hasPrefix("Ahead of even pace") == true)
        #expect(p.summary.accessibilityLabel.contains("weekly window 60 percent used"))
    }

    @Test("no pace verdict without the tick: no window length, or a spent window")
    func paceOnlyWhereTheTickIsDrawn() {
        // A pace fraction with nothing behind it is not a pace.
        let bare = DualBarMetrics(primaryFraction: 0.6, expectedPaceFraction: 0.3, label: "WK")
        #expect(MetricDetailPresentation(snapshot: snapshot(bars: [bare]), now: now).summary.paceVerdict == nil)
        // A spent window draws no tick.
        let spent = weekly(used: 1.0, elapsed: 0.5)
        let p = MetricDetailPresentation(snapshot: snapshot(status: .measured(.critical), bars: [spent]), now: now)
        #expect(p.summary.paceVerdict == nil)
        #expect(p.summary.state == .exhausted)
        // Behind and on pace are named as such.
        #expect(MetricDetailPresentation.paceVerdict(for: weekly(used: 0.2, elapsed: 0.5))?
            .hasPrefix("Behind even pace") == true)
        #expect(MetricDetailPresentation.paceVerdict(for: weekly(used: 0.5, elapsed: 0.5))?
            .hasPrefix("On even pace") == true)
    }

    @Test("an unreadable provider gets its reason and remedy, and no figure at all")
    func unavailableSaysWhy() {
        let p = MetricDetailPresentation(
            snapshot: snapshot(status: .unavailable(.credentialRejected), bars: [weekly(used: 0.6, elapsed: 0.5)]),
            now: now)
        #expect(p.summary.state == .unavailable(.credentialRejected))
        #expect(p.summary.headline == UnavailableReason.credentialRejected.headline)
        #expect(p.summary.remedy == UnavailableReason.credentialRejected.remedy)
        #expect(p.summary.percentUsed == nil)
        #expect(p.summary.figure == nil)
        #expect(p.windows.isEmpty)
        #expect(!p.provenance.contains { $0.label == "Raw figure" })
    }

    @Test("a blocked window with no percentage is the focus, says blocked, and invents no share")
    func blockedWithoutReading() {
        let blocked = weekly(used: nil, elapsed: 0.5, isBlocked: true)
        let p = MetricDetailPresentation(
            snapshot: snapshot(status: .measured(.critical), metric: .subscription(tierName: "Go", renewalDate: nil),
                               bars: [blocked]),
            now: now)
        #expect(p.summary.state == .blocked)
        #expect(p.summary.symbol == BlockedGlyph.symbolName)
        #expect(p.summary.percentUsed == nil)
        #expect(p.summary.paceVerdict == nil)
        #expect(p.windows.first?.percentText == nil)
        #expect(p.windows.first?.noFigureText == "Blocked")
    }

    @Test("a provider with no window leads with its measured figure, and a tier is not a figure")
    func noWindowFigure() {
        let money = MetricDetailPresentation(
            snapshot: snapshot(metric: .currency(balance: 12.5, limit: nil, spent: nil, currencyCode: "USD")),
            now: now)
        #expect(money.summary.figure == MetricRowPresentation.currency(12.5, "USD"))
        #expect(money.summary.percentUsed == nil)
        let tier = MetricDetailPresentation(
            snapshot: snapshot(metric: .subscription(tierName: "Pro", renewalDate: nil)), now: now)
        #expect(tier.summary.figure == nil)
    }

    @Test("provenance reports what was measured and says when something was not")
    func provenance() {
        let p = MetricDetailPresentation(
            snapshot: snapshot(metric: .count(remaining: 600, limit: 1000, unitName: "points")),
            readingsRecorded: 12, now: now)
        let rows = Dictionary(uniqueKeysWithValues: p.provenance.map { ($0.label, $0.value) })
        #expect(rows["Plan"] == .some(nil))
        #expect(rows["Source"] == .some(nil))
        #expect(rows["Raw figure"] == "600 of 1,000 points remaining")
        #expect(rows["History"] == "12 readings recorded, last 30 days")
        #expect(rows["Last fetched"]??.contains("3 min ago") == true)
    }

    @Test("a billing cycle is labelled elapsed time, never consumption")
    func cycleWindow() {
        let cycle = DualBarMetrics(primaryFraction: 0.9, label: "CYCLE", measuresElapsedTimeOnly: true)
        let line = MetricDetailPresentation.windowLine(cycle, now: now)
        #expect(line.isCycle)
        #expect(line.accessibilityLabel.contains("90 percent elapsed"))
        #expect(!line.accessibilityLabel.contains("used"))
    }

    @Test("every SF Symbol the new surfaces draw exists, so no state loses its shape")
    func symbolsResolve() {
        let reasons: [UnavailableReason] = [
            .notConfigured, .credentialRejected, .unsupported("x"), .offline, .timedOut, .badResponse,
            .rateLimited(retryAfter: nil),
        ]
        var names = reasons.map(ProviderConnectionPresentation.symbol(for:))
        names += ["checkmark.circle.fill", "exclamationmark.circle.fill", "exclamationmark.octagon.fill",
                  "xmark.octagon.fill", BlockedGlyph.symbolName, "minus.circle", "eye.slash", "clock",
                  "pause.circle", "square.fill", "triangle.fill", "diamond.fill", "circle.fill"]
        names += SettingsView.Pane.allCases.map(\.symbol)
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}

@Suite("Provider connection in Preferences")
struct ProviderConnectionPresentationTests {

    private let now = Date(timeIntervalSince1970: 1_791_848_000)

    private func snapshot(_ status: ProviderStatus, id: String = "claude") -> QuotaSnapshot {
        QuotaSnapshot(
            id: id, vendorId: id.hasPrefix("opencode") ? .opencode : .claude, displayName: id,
            category: .aiSubscriptions, metric: .percentage(usedFraction: 0.1, displayDetails: nil),
            status: status, resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil)
    }

    @Test("a hidden provider is described as hidden, whatever its last reading said")
    func hiddenWins() {
        let status = ProviderConnectionPresentation.status(
            vendorSnapshots: [snapshot(.unavailable(.credentialRejected))], isHidden: true, hasPolled: true, now: now)
        #expect(status.title == "Hidden")
        #expect(status.tone == .inactive)
    }

    @Test("an unreadable provider shows its headline, a shape, and the remedy")
    func unreadable() {
        let status = ProviderConnectionPresentation.status(
            vendorSnapshots: [snapshot(.unavailable(.offline))], isHidden: false, hasPolled: true, now: now)
        #expect(status.title == UnavailableReason.offline.headline)
        #expect(status.detail == UnavailableReason.offline.remedy)
        #expect(status.symbol == "wifi.slash")
        #expect(status.tone == .attention)
    }

    @Test("before a poll, only what is known is said")
    func beforePoll() {
        let unknown = ProviderConnectionPresentation.status(
            vendorSnapshots: [], isHidden: false, hasPolled: false, now: now)
        #expect(unknown.title == "Not read yet")
        let absent = ProviderConnectionPresentation.status(
            vendorSnapshots: [], isHidden: false, hasPolled: false, credentialSource: .absent, now: now)
        #expect(absent.title == UnavailableReason.notConfigured.headline)
        #expect(absent.detail == UnavailableReason.notConfigured.remedy)
    }

    @Test("several workspaces summarise how many could not be read, naming the first")
    func severalInstances() {
        let all = ProviderConnectionPresentation.status(
            vendorSnapshots: [snapshot(.measured(.none), id: "opencode-go:a"), snapshot(.measured(.none), id: "opencode-go:b")],
            isHidden: false, hasPolled: true, now: now)
        #expect(all.title == "Connected")
        #expect(all.detail == "All 2 read")

        let one = ProviderConnectionPresentation.status(
            vendorSnapshots: [snapshot(.measured(.none), id: "opencode-go:a"),
                              snapshot(.unavailable(.credentialRejected), id: "opencode-go:b")],
            isHidden: false, hasPolled: true, now: now)
        #expect(one.title == "1 of 2 unreadable")
        #expect(one.detail?.contains(UnavailableReason.credentialRejected.remedy) == true)
        #expect(one.tone == .attention)
    }
}
