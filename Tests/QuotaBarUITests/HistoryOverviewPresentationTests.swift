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
        #expect(card.sampleCount == 3)
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

    // MARK: - The last poll gates the headline

    private func makeStore() -> QuotaHistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrugalBarTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("overview.sqlite3")
        return QuotaHistoryStore(databaseURL: url, isTestHost: true)
    }

    private func claude(used: Double?, status: ProviderStatus = .measured(.none), at now: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: used ?? 0, displayDetails: nil),
            status: status, resetsAt: nil, lastUpdated: now, auxiliaryInfo: nil,
            row1: used == nil && status.unavailableReason != nil
                ? nil : DualBarMetrics(primaryFraction: used, label: "WK", windowLength: 7 * 86_400))
    }

    @Test("a failed poll recorded after a measured one leaves the card with no figure, not the old one")
    func failedPollGatesHeadline() async throws {
        // Rows as production writes them: the failed poll has no bars, so it is
        // recorded under DEFAULT, not under WK.
        let store = makeStore()
        try await store.record([claude(used: 0.62, at: base)], now: base)
        try await store.record([claude(used: nil, status: .unavailable(.offline), at: base)],
                               now: base.addingTimeInterval(600))
        let sampled = try await store.fetchSampledReadings(
            since: base.addingTimeInterval(-3_600), until: base.addingTimeInterval(3_600), bucketSeconds: 720)
        #expect(sampled.contains { $0.barLabel == "DEFAULT" && $0.confidence != .measured })

        let subjects = HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: [])
        let card = try #require(
            HistoryOverviewPresentation.overview(subjects: subjects, readings: sampled, bucketSeconds: 720).cards.first)
        #expect(card.latest.fraction == 0.62)
        #expect(!card.latestIsCurrent)
        #expect(card.latestPercent == nil)
        #expect(card.noFigureText == "Could not be read at the last poll")
        #expect(card.lastPoll.measuredAt == base.addingTimeInterval(600))

        // Read again once it answers, and the figure is back.
        try await store.record([claude(used: 0.64, at: base)], now: base.addingTimeInterval(1_200))
        let recovered = try await store.fetchSampledReadings(
            since: base.addingTimeInterval(-3_600), until: base.addingTimeInterval(3_600), bucketSeconds: 720)
        let current = try #require(
            HistoryOverviewPresentation.overview(subjects: subjects, readings: recovered, bucketSeconds: 720).cards.first)
        #expect(current.latestPercent == 64)
    }

    @Test("a sampled long-range sparkline is a line, while a genuine outage still breaks it")
    func sampledSparklineIsContinuous() throws {
        let subjects = HistoryOverviewPresentation.subjects(order: [.claude], hidden: [], workspaces: [])
        let bucket = HistoryOverviewPresentation.sampleBucketSeconds(range: .last30Days, retention: 0)
        // Ten six-hour samples, then four silent days, then three more.
        var readings = (0..<10).map { record("claude", at: Double($0 * bucket), 0.1 + Double($0) * 0.02) }
        readings += (0..<3).map { record("claude", at: Double((9 + 16 + $0) * bucket), 0.5) }

        let card = try #require(
            HistoryOverviewPresentation.overview(subjects: subjects, readings: readings, bucketSeconds: bucket).cards.first)
        #expect(card.segments.map(\.points.count) == [10, 3])

        // All Time at the default retention: eighteen-hour buckets.
        let wide = HistoryOverviewPresentation.sampleBucketSeconds(range: .allTime, retention: 90 * 86_400)
        let sparse = (0..<9).map { record("claude", at: Double($0 * wide), 0.3) }
        let allTime = try #require(
            HistoryOverviewPresentation.overview(subjects: subjects, readings: sparse, bucketSeconds: wide).cards.first)
        #expect(allTime.segments.count == 1)
    }

    // MARK: - Inspecting a point

    @Test("the readout groups only one poll's windows, under that poll's timestamp")
    func nearestPollGroupsOnePoll() throws {
        let readings = [
            record("claude", "5H", at: 0, 0.1, windowLength: 5 * 3600),
            record("claude", "WK", at: 0, 0.4),
            record("claude", "5H", at: 600, 0.2, windowLength: 5 * 3600),
            record("claude", "WK", at: 600, 0.5),
            // A WK-only reading five minutes after the 600 poll: a different poll.
            record("claude", "WK", at: 900, 0.55),
        ]
        let segments = HistoryPresentation.segments(from: readings)

        let same = try #require(HistoryOverviewPresentation.nearestPoll(
            to: base.addingTimeInterval(620), in: segments, tolerance: 300))
        #expect(same.timestamp == base.addingTimeInterval(600))
        #expect(same.rows.map(\.barLabel) == ["5H", "WK"])
        #expect(same.rows.map(\.point.fraction) == [0.2, 0.5])
        #expect(same.rows.allSatisfy { $0.point.timestamp == same.timestamp })

        // Nearer the WK-only poll: the 5H figure from 600 is not put under it.
        let other = try #require(HistoryOverviewPresentation.nearestPoll(
            to: base.addingTimeInterval(860), in: segments, tolerance: 300))
        #expect(other.timestamp == base.addingTimeInterval(900))
        #expect(other.rows.map(\.barLabel) == ["WK"])

        #expect(HistoryOverviewPresentation.nearestPoll(
            to: base.addingTimeInterval(5_000), in: segments, tolerance: 300) == nil)
    }

    @Test("the keyboard steps poll by poll, starting at the newest and stopping at either end")
    func steppingThroughPolls() {
        let segments = HistoryPresentation.segments(from: [
            record("claude", "5H", at: 0, 0.1, windowLength: 5 * 3600),
            record("claude", "WK", at: 0, 0.4),
            record("claude", "WK", at: 600, 0.5),
            record("claude", "WK", at: 1_200, 0.6),
        ])
        let at = { (offset: TimeInterval) in self.base.addingTimeInterval(offset) }

        #expect(HistoryOverviewPresentation.steppedPoll(from: nil, by: -1, in: segments) == at(1_200))
        #expect(HistoryOverviewPresentation.steppedPoll(from: nil, by: 1, in: segments) == at(1_200))
        #expect(HistoryOverviewPresentation.steppedPoll(from: at(1_200), by: -1, in: segments) == at(600))
        #expect(HistoryOverviewPresentation.steppedPoll(from: at(600), by: -1, in: segments) == at(0))
        #expect(HistoryOverviewPresentation.steppedPoll(from: at(0), by: -1, in: segments) == at(0))
        #expect(HistoryOverviewPresentation.steppedPoll(from: at(1_200), by: 1, in: segments) == at(1_200))
        // From where the pointer left it, between two polls.
        #expect(HistoryOverviewPresentation.steppedPoll(from: at(700), by: 1, in: segments) == at(1_200))
        #expect(HistoryOverviewPresentation.steppedPoll(from: at(700), by: -1, in: segments) == at(600))
        #expect(HistoryOverviewPresentation.steppedPoll(from: at(9_000), by: -1, in: segments) == at(1_200))
        #expect(HistoryOverviewPresentation.steppedPoll(from: nil, by: 1, in: []) == nil)
    }

    @Test("the readout states the recorded figure and the second it was taken")
    func exactReadout() {
        #expect(ReadingReadout.exactPercentText(0.62) == "62%")
        #expect(ReadingReadout.exactPercentText(0.62346) == "62.35%")
        #expect(ReadingReadout.exactPercentText(0.625) == "62.5%")
        #expect(ReadingReadout.exactPercentText(1.03) == "103%")

        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 10, 14)
        (components.hour, components.minute, components.second) = (14, 5, 32)
        let date = Calendar.current.date(from: components)!
        let text = ReadingReadout.exactTimestampText(date)
        #expect(text.contains("2026"))
        #expect(text.hasSuffix("14:05:32"))

        let poll = HistoryOverviewPresentation.InspectedPoll(timestamp: date, rows: [
            .init(barLabel: "WK", point: .init(timestamp: date, fraction: 0.6234, isBlocked: true,
                                               confidence: .measured, urgency: .warning)),
        ])
        let spoken = ReadingReadout.spoken(poll)
        #expect(spoken.contains("62.34 percent used"))
        #expect(spoken.contains("blocked"))
        #expect(spoken.contains("14:05:32"))
    }
}
