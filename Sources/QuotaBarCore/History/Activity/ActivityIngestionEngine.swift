import Foundation

/// Coordinates collecting activity from CLI adapters and committing them to the history store.
public actor ActivityIngestionEngine {
    private let store: QuotaHistoryStore
    private let adapters: [ActivityAdapter]
    private var isIngesting = false
    /// A pass in which every adapter read everything has finished in THIS
    /// process. Never persisted: after a restart the table lacks whatever the
    /// tools wrote while the app was closed, and a flag from an earlier run
    /// would vouch for a table nothing has caught up yet.
    private var completedCleanPass = false
    /// The most recent pass could not read everything: an adapter threw, or
    /// reported an input it had to skip. Forgotten on restart like the above,
    /// which is safe because `completedCleanPass` is forgotten with it.
    private var lastPassIncomplete = false

    public init(
        store: QuotaHistoryStore,
        adapters: [ActivityAdapter]? = nil
    ) {
        self.store = store
        if let adapters {
            self.adapters = adapters
        } else {
            self.adapters = [
                ClaudeCodeAdapter(),
                CodexAdapter(),
                OpenCodeAdapter()
            ]
        }
    }

    /// Ingests new records from all configured adapters.
    /// Returns the total number of records submitted for storage.
    ///
    /// One adapter failing does not abandon the others, but it does propagate:
    /// the caller is told the pass was incomplete rather than being handed a
    /// success that silently omitted a whole source. Sources that succeeded
    /// before the failure keep their records and their watermarks.
    ///
    /// An adapter that read what it could but had to skip an input (a file it
    /// may not open, a database whose table is gone) does not throw, but the
    /// pass is still recorded as incomplete: see `status()`.
    ///
    /// A pass already in flight makes this a no-op. Ingestion runs off its own
    /// task now, and without this two overlapping passes would interleave at the
    /// store's `await`s and duplicate the scanning work.
    @discardableResult
    public func ingestAll() async throws -> Int {
        guard !isIngesting else { return 0 }
        isIngesting = true
        defer { isIngesting = false }

        var totalRecorded = 0
        var skipped = 0
        var firstError: Error?

        for adapter in adapters {
            do {
                let pass = try await ingest(adapter)
                totalRecorded += pass.recorded
                skipped += pass.skipped
            } catch {
                if firstError == nil { firstError = error }
                try? await recordFailedScan(for: adapter)
            }
        }

        // Clean only when every adapter read everything it found.
        lastPassIncomplete = firstError != nil || skipped > 0
        if !lastPassIncomplete { completedCleanPass = true }

        if let firstError { throw firstError }
        return totalRecorded
    }

    private func priorStatus(for source: String) async -> ActivitySourceStatus? {
        guard let statuses = try? await store.activitySourceStatuses() else { return nil }
        return statuses.first { $0.source == source }
    }

    private func ingest(_ adapter: ActivityAdapter) async throws -> (recorded: Int, skipped: Int) {
        let existing = try await store.watermarks(for: adapter.sourceIdentifier)
        // Codex rebuilt from session aggregates: an install upgrading from the
        // pre-ledger build has watermarks saying every unchanged rollout was
        // read, but those rows are session totals. Re-read the still-present
        // files once, so request history exists; files that are gone keep their
        // legacy row honestly.
        let needsLedgerRebuild: Bool
        if adapter.sourceIdentifier == "codex" {
            needsLedgerRebuild = !(try await store.hasActivityRequests(source: adapter.sourceIdentifier))
        } else {
            needsLedgerRebuild = false
        }
        let result = try await adapter.collectActivities(
            watermarks: needsLedgerRebuild ? [:] : existing)

        // Records before watermarks, deliberately: the store de-duplicates on
        // `(source, record_id)`, so re-reading a region is harmless, whereas
        // advancing the cursor past records that were never written loses them.
        if !result.records.isEmpty {
            try await store.recordActivities(result.records)
        }

        for watermark in result.watermarks {
            try await store.setWatermark(
                source: adapter.sourceIdentifier,
                filePath: watermark.filePath,
                fileSize: watermark.fileSize,
                modifiedAt: watermark.modifiedAt,
                byteOffset: watermark.cursor
            )
        }

        let diagnostics = result.diagnostics
        let previous = await priorStatus(for: adapter.sourceIdentifier)
        let now = Date()
        let readEverything = diagnostics.skippedInputs == 0
        let scannedSomething = diagnostics.scannedInputs > 0
        // An unchanged-file skip must not erase what a previous pass found in
        // that file. Only a pass that actually read input replaces the counts.
        let status = ActivitySourceStatus(
            source: adapter.sourceIdentifier,
            lastScanAt: now,
            lastSuccessfulScanAt: readEverything ? now : previous?.lastSuccessfulScanAt,
            readFailures: diagnostics.skippedInputs,
            malformedRecords: scannedSomething ? diagnostics.malformedRecords : (previous?.malformedRecords ?? 0),
            inconsistentRecords: scannedSomething ? diagnostics.inconsistentRecords : (previous?.inconsistentRecords ?? 0),
            incompleteRecords: scannedSomething ? diagnostics.incompleteRecords : (previous?.incompleteRecords ?? 0),
            recordsObserved: scannedSomething ? diagnostics.recordsObserved : (previous?.recordsObserved ?? 0),
            lastPassComplete: readEverything
        )
        try await store.recordActivitySourceStatus(status)

        return (result.records.count, diagnostics.skippedInputs)
    }

    /// A source that threw produced no `ActivityIngestResult`. Its last
    /// successful scan and what it previously could not represent are retained;
    /// only the failure itself is new.
    private func recordFailedScan(for adapter: ActivityAdapter) async throws {
        let previous = await priorStatus(for: adapter.sourceIdentifier)
        try await store.recordActivitySourceStatus(ActivitySourceStatus(
            source: adapter.sourceIdentifier,
            lastScanAt: Date(),
            lastSuccessfulScanAt: previous?.lastSuccessfulScanAt,
            readFailures: max(1, previous?.readFailures ?? 0),
            malformedRecords: previous?.malformedRecords ?? 0,
            inconsistentRecords: previous?.inconsistentRecords ?? 0,
            incompleteRecords: previous?.incompleteRecords ?? 0,
            recordsObserved: previous?.recordsObserved ?? 0,
            lastPassComplete: false
        ))
    }

    /// What the activity table can be trusted to contain right now.
    ///
    /// Everything that displays it needs this: the table is empty or stale
    /// until a pass has finished in this run, and while an input keeps failing
    /// some tokens are missing from every total. Both are in-memory facts about
    /// this process, so a relaunch starts again from "not yet" instead of
    /// inheriting a clean bill of health from a run that has since gone stale.
    public struct Status: Sendable, Equatable {
        /// A pass in which every adapter read everything has finished since
        /// this process started.
        public let hasCompletedCleanPass: Bool
        /// The most recent pass could not read everything.
        public let lastPassIncomplete: Bool
        /// A pass is running now.
        public let isRunning: Bool
        /// The retained per-source account of the last scan. Persisted, so a
        /// relaunch still says when each source was last read and what it could
        /// not represent, even before this run's first pass.
        public let sources: [ActivitySourceStatus]

        public init(
            hasCompletedCleanPass: Bool,
            lastPassIncomplete: Bool,
            isRunning: Bool,
            sources: [ActivitySourceStatus] = []
        ) {
            self.hasCompletedCleanPass = hasCompletedCleanPass
            self.lastPassIncomplete = lastPassIncomplete
            self.isRunning = isRunning
            self.sources = sources
        }

        public func status(for source: String) -> ActivitySourceStatus? {
            sources.first { $0.source == source }
        }
    }

    public func status() async -> Status {
        let sources = (try? await store.activitySourceStatuses()) ?? []
        return Status(
            hasCompletedCleanPass: completedCleanPass,
            lastPassIncomplete: lastPassIncomplete,
            isRunning: isIngesting,
            sources: sources)
    }
}
