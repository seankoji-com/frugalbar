import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

/// R4/R5 presentation: source diagnostics are named, an unchanged-file skip
/// cannot hide them, and OpenCode tool activity is never presented as a
/// workspace's billed usage.
@Suite("Activity accounting presentation")
struct ActivityAccountingPresentationTests {

    private typealias T = TokenUsagePresentation

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func bucket(_ source: String, tokens: Int) -> QuotaHistoryStore.TokenBucket {
        .init(source: source, start: now.addingTimeInterval(-3600), tokens: tokens, records: 1)
    }

    private func status(
        _ source: String,
        readFailures: Int = 0,
        malformed: Int = 0,
        inconsistent: Int = 0,
        incomplete: Int = 0,
        lastSuccess: Date? = Date(timeIntervalSince1970: 1_790_000_000)
    ) -> ActivitySourceStatus {
        ActivitySourceStatus(
            source: source,
            lastScanAt: lastSuccess,
            lastSuccessfulScanAt: lastSuccess,
            readFailures: readFailures,
            malformedRecords: malformed,
            inconsistentRecords: inconsistent,
            incompleteRecords: incomplete,
            recordsObserved: 10,
            lastPassComplete: readFailures == 0)
    }

    @Test("source diagnostics name the source, the count and the last successful scan")
    func sourceNotes() {
        let notes = T.sourceNotes(
            sources: [status("codex", readFailures: 1, malformed: 2, inconsistent: 1, incomplete: 3)],
            shownSources: ["codex"])
        #expect(notes.contains("Codex: 1 input could not be read on the last scan."))
        #expect(notes.contains("Codex: 2 malformed records were not counted."))
        #expect(notes.contains("Codex: 1 record disagreed with the source's cumulative counter and was not reconciled."))
        #expect(notes.contains("Codex: 3 records had an incomplete token breakdown."))
        #expect(notes.contains { $0.hasPrefix("Last successful scan: Codex ") })
    }

    @Test("a source outside the drawn providers is not named")
    func sourceNotesFiltered() {
        let notes = T.sourceNotes(
            sources: [status("codex", malformed: 1), status("opencode", malformed: 9)],
            shownSources: ["codex"])
        #expect(notes.contains { $0.contains("Codex: 1 malformed") })
        #expect(!notes.contains { $0.contains("OpenCode") })
    }

    @Test("the chart draws retained source notes and the OpenCode provenance caveat")
    func chartNotes() {
        let chart = T.chart(
            usage: .init(buckets: [bucket("codex", tokens: 10), bucket("opencode", tokens: 5)],
                         uncountedRecords: [:]),
            filters: WidgetFilters(layout: .tokens), hidden: [], configured: [],
            ingestion: .complete, now: now, calendar: calendar,
            sources: [status("opencode", malformed: 1)])
        let notes = T.notes(for: chart)
        #expect(notes.contains("OpenCode: 1 malformed record was not counted."))
        #expect(notes.contains("OpenCode sessions are local tool activity; they do not record which account or workspace billed them."))
    }

    @Test("request-level Codex rows no longer claim the session-total caveat")
    func sessionTotalsOnlyWhenSessionGranularity() {
        func chart(_ usage: QuotaHistoryStore.TokenUsage) -> T.Chart {
            T.chart(usage: usage, filters: WidgetFilters(layout: .tokens), hidden: [],
                    configured: [], ingestion: .complete, now: now, calendar: calendar)
        }
        let requestRows = QuotaHistoryStore.TokenUsage(
            buckets: [bucket("codex", tokens: 10)], uncountedRecords: [:],
            sessionTotalRecords: [:], granularityKnown: true)
        #expect(!chart(requestRows).hasSessionTotals)
        #expect(!T.notes(for: chart(requestRows)).contains { $0.contains("counts tokens per session") })

        let sessionRows = QuotaHistoryStore.TokenUsage(
            buckets: [bucket("codex", tokens: 10)], uncountedRecords: [:],
            sessionTotalRecords: ["codex": 1], granularityKnown: true)
        #expect(chart(sessionRows).hasSessionTotals)
    }

    @Test("the history breakdown words source diagnostics and unknown billing identity")
    func historyWording() {
        let notes = HistoryPresentation.activitySourceNotes(
            [status("opencode", malformed: 2, incomplete: 1)], vendor: .opencode)
        #expect(notes.contains("OpenCode: 2 malformed records could not be counted."))
        #expect(notes.contains("OpenCode: 1 record had an incomplete token breakdown."))

        let unknown = HistoryPresentation.activityEmptyMessage(
            .complete, vendorName: "OpenCode Go", recordsWithoutTokenTotals: 0,
            recordsWithoutBillingIdentity: 4)
        #expect(unknown.contains("4 local session records"))
        #expect(unknown.contains("did not publish a billing account or workspace"))
        #expect(!unknown.contains("No local"))

        // A different vendor gets no OpenCode lines.
        #expect(HistoryPresentation.activitySourceNotes([status("opencode", malformed: 2)], vendor: .claude).isEmpty)
    }
}
