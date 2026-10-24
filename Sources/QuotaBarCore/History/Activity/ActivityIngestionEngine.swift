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

        // Per-input accounting. An input this pass did not read (unchanged)
        // keeps its own row; an input it did read replaces (or, for an
        // appended region, adds to) its row. A different file's clean pass
        // therefore cannot erase this file's malformed count.
        let existingInputs = (try? await store.activityInputStatuses(source: adapter.sourceIdentifier)) ?? []
        let priorByPath = Dictionary(uniqueKeysWithValues: existingInputs.map { ($0.filePath, $0) })
        var mergedInputs: [ActivityInputStatus] = []
        var emittedPaths = Set<String>()
        for input in result.inputDiagnostics {
            let prior = priorByPath[input.filePath]
            let merged: ActivityInputStatus
            if input.readFailure, let prior {
                // A failed read says nothing new about what is inside: keep
                // the figures it previously yielded and charge the failure.
                // An appended-region read that failed part-way still saw the
                // records it counted before the failure.
                let appending = input.coverage == .appendedRegion
                merged = ActivityInputStatus(
                    source: adapter.sourceIdentifier,
                    filePath: input.filePath,
                    malformedRecords: prior.malformedRecords + (appending ? input.malformedRecords : 0),
                    inconsistentRecords: prior.inconsistentRecords + (appending ? input.inconsistentRecords : 0),
                    incompleteRecords: prior.incompleteRecords + (appending ? input.incompleteRecords : 0),
                    recordsObserved: prior.recordsObserved + (appending ? input.recordsObserved : 0),
                    readFailure: true,
                    lastScannedAt: now)
            } else if input.coverage == .appendedRegion, let prior {
                merged = ActivityInputStatus(
                    source: adapter.sourceIdentifier,
                    filePath: input.filePath,
                    malformedRecords: prior.malformedRecords + input.malformedRecords,
                    inconsistentRecords: prior.inconsistentRecords + input.inconsistentRecords,
                    incompleteRecords: prior.incompleteRecords + input.incompleteRecords,
                    recordsObserved: prior.recordsObserved + input.recordsObserved,
                    readFailure: input.readFailure,
                    lastScannedAt: now)
            } else {
                merged = ActivityInputStatus(
                    source: adapter.sourceIdentifier,
                    filePath: input.filePath,
                    malformedRecords: input.malformedRecords,
                    inconsistentRecords: input.inconsistentRecords,
                    incompleteRecords: input.incompleteRecords,
                    recordsObserved: input.recordsObserved,
                    readFailure: input.readFailure,
                    lastScannedAt: now)
            }
            mergedInputs.append(merged)
            emittedPaths.insert(input.filePath)
        }
        // Unchanged inputs were not re-read, so their rows stay as they were.
        // An input that was already known but has no diagnostic row yet gets a
        // zero row: it was read before this accounting existed.
        for path in result.inputsConsidered where !emittedPaths.contains(path) {
            if let prior = priorByPath[path] {
                mergedInputs.append(prior)
            } else {
                mergedInputs.append(ActivityInputStatus(
                    source: adapter.sourceIdentifier, filePath: path, lastScannedAt: now))
            }
        }
        // Inputs no longer present are dropped with the input set.
        try await store.replaceActivityInputStatuses(
            source: adapter.sourceIdentifier, inputs: mergedInputs)

        let readFailures = mergedInputs.filter(\.readFailure).count
        let status = ActivitySourceStatus(
            source: adapter.sourceIdentifier,
            lastScanAt: now,
            lastSuccessfulScanAt: readEverything && readFailures == 0
                ? now : previous?.lastSuccessfulScanAt,
            readFailures: readFailures,
            malformedRecords: mergedInputs.map(\.malformedRecords).reduce(0, +),
            inconsistentRecords: mergedInputs.map(\.inconsistentRecords).reduce(0, +),
            incompleteRecords: mergedInputs.map(\.incompleteRecords).reduce(0, +),
            recordsObserved: mergedInputs.map(\.recordsObserved).reduce(0, +),
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
