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
            }
        }

        // Clean only when every adapter read everything it found.
        lastPassIncomplete = firstError != nil || skipped > 0
        if !lastPassIncomplete { completedCleanPass = true }

        if let firstError { throw firstError }
        return totalRecorded
    }

    private func ingest(_ adapter: ActivityAdapter) async throws -> (recorded: Int, skipped: Int) {
        let existing = try await store.watermarks(for: adapter.sourceIdentifier)
        let result = try await adapter.collectActivities(watermarks: existing)

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

        return (result.records.count, result.skipped)
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

        public init(hasCompletedCleanPass: Bool, lastPassIncomplete: Bool, isRunning: Bool) {
            self.hasCompletedCleanPass = hasCompletedCleanPass
            self.lastPassIncomplete = lastPassIncomplete
            self.isRunning = isRunning
        }
    }

    public func status() -> Status {
        Status(
            hasCompletedCleanPass: completedCleanPass,
            lastPassIncomplete: lastPassIncomplete,
            isRunning: isIngesting)
    }
}
