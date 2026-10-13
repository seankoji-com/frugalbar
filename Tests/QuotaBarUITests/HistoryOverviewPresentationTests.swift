import Testing
import Foundation
@testable import QuotaBarCore
@testable import QuotaBarUI

@Suite("History overview")
struct HistoryOverviewPresentationTests {

    private let legacy = OpenCodeGoWorkspaceStore.legacy
    private let beta = OpenCodeGoWorkspace(id: "beta", name: "Go Beta")
    private let off = OpenCodeGoWorkspace(id: "off", name: "Go Off", isEnabled: false)
    private let base = Date(timeIntervalSince1970: 1_791_849_600)

    private func record(
        _ key: String, _ label: String = "WK", at offset: TimeInterval, _ fraction: Double?,
        windowLength: TimeInterval? = 7 * 86_400, elapsedOnly: Bool = false
    ) -> QuotaHistoryStore.ReadingRecord {
        QuotaHistoryStore.ReadingRecord(
            vendor: key, barLabel: label, measuredAt: base.addingTimeInterval(offset), fraction: fraction,
            isBlocked: false, confidence: .measured, urgency: .none, resetsAt: nil,
            windowLength: windowLength, elapsedOnly: elapsedOnly)
    }

    // MARK: - Subjects

    @Test("subjects follow the user's provider order and workspace order; hidden and disabled are left out")
    func subjectsOrder() {
        let order: [VendorIdentifier] = [.opencode, .claude, .grok, .openai]
        let subjects = HistoryOverviewPresentation.subjects(
            order: order, hidden: [.grok], workspaces: [beta, off, legacy])

        #expect(subjects.map(\.id) == [beta.instanceID, legacy.instanceID, "claude", "openai"])
        #expect(subjects.map(\.name) == ["Go Beta", "OpenCode", "Claude", "OpenAI"])
        // The workspace that kept the pre-workspace key also owns its rows.
        #expect(subjects[1].keys == [legacy.instanceID, "opencode"])
        #expect(subjects[0].keys == [beta.instanceID])
        #expect(HistoryOverviewPresentation.hiddenNames(order: order, hidden: [.grok]) == ["Grok"])
    }

    // MARK: - Cards

    @Test("each card is its own longest window, in subject order, with no figure carried over")
    func cardsAreHonest() throws {
        let subjects = HistoryOverviewPresentation.subjects(
            order: [.claude, .opencode], hidden: [], workspaces: [beta])
        let readings = [
            record("claude", "5H", at: 0, 0.2, windowLength: 5 * 3600),
            record("claude", "WK", at: 0, 0.4),
            record("claude", "WK", at: 600, 0.45),
            // The newest weekly poll got no figure: the card must say so, not
            // fall back to 45%.
            record("claude", "WK", at: 1200, nil),
            // A sibling key is not this card's.
            record("opencode-go:other", at: 0, 0.9),
        ]
        let overview = HistoryOverviewPresentation.overview(subjects: subjects, readings: readings)

        #expect(overview.cards.map(\.subject.id) == ["claude"])
        let card = try #require(overview.cards.first)
        #expect(card.barLabel == "WK")
        #expect(card.latestPercent == nil)
        #expect(card.readingCount == 3)
        #expect(card.segments.flatMap(\.points).map(\.fraction) == [0.4, 0.45])
        #expect(overview.empty.map(\.id) == [beta.instanceID])
    }

    @Test("an elapsed-time billing cycle never becomes a card's consumption figure")
    func cyclesAreNotConsumption() {
        let subjects = HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: [])
        let overview = HistoryOverviewPresentation.overview(
            subjects: subjects,
            readings: [record("claude", "CYCLE", at: 0, 0.9, windowLength: 30 * 86_400, elapsedOnly: true)])
        #expect(overview.cards.isEmpty)
        #expect(overview.empty.map(\.id) == ["claude"])
    }

    @Test("sparkline buckets hold about 120 points and never go below a poll")
    func bucketSize() {
        #expect(HistoryOverviewPresentation.sampleBucketSeconds(range: .last24Hours, retention: 0) == 720)
        #expect(HistoryOverviewPresentation.sampleBucketSeconds(range: .last30Days, retention: 0) == 21_600)
        #expect(HistoryOverviewPresentation.sampleBucketSeconds(range: .allTime, retention: 90 * 86_400) == 64_800)
        #expect(HistoryOverviewPresentation.sampleBucketSeconds(range: .allTime, retention: 60) == 120)
    }

    @Test("the empty explanation names the range rather than leaving a blank chart")
    func emptyExplanation() {
        #expect(HistoryOverviewPresentation.emptyExplanation(isSampleMode: false, range: .last7Days)
            .contains("last 7 days"))
        #expect(HistoryOverviewPresentation.emptyExplanation(isSampleMode: true, range: .last7Days)
            .contains("sample data"))
    }

    // MARK: - Inspecting a point

    @Test("the readout claims the nearest reading per window, and none from too far away")
    func nearestPoints() {
        let readings = [
            record("claude", "5H", at: 0, 0.1, windowLength: 5 * 3600),
            record("claude", "5H", at: 600, 0.2, windowLength: 5 * 3600),
            record("claude", "WK", at: 0, 0.4),
            record("claude", "WK", at: 600, 0.5),
        ]
        let segments = HistoryPresentation.segments(from: readings)

        let near = HistoryOverviewPresentation.nearestPoints(
            to: base.addingTimeInterval(500), in: segments, tolerance: 300)
        #expect(near.map(\.barLabel) == ["5H", "WK"])
        #expect(near.map(\.point.fraction) == [0.2, 0.5])

        let far = HistoryOverviewPresentation.nearestPoints(
            to: base.addingTimeInterval(5_000), in: segments, tolerance: 300)
        #expect(far.isEmpty)
    }
}
