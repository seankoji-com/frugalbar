import Foundation

/// Coordinates collecting activity from CLI adapters and committing them to the history store.
public actor ActivityIngestionEngine {
    private let store: QuotaHistoryStore
    private let adapters: [ActivityAdapter]
    private var isIngesting = false
    /// The most recent pass finished with an adapter having failed.
    private var lastPassFailed = false

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
    /// A pass already in flight makes this a no-op. Ingestion runs off its own
    /// task now, and without this two overlapping passes would interleave at the
    /// store's `await`s and duplicate the scanning work.
    @discardableResult
    public func ingestAll() async throws -> Int {
        guard !isIngesting else { return 0 }
        isIngesting = true
        defer { isIngesting = false }

        var totalRecorded = 0
        var firstError: Error?

        for adapter in adapters {
            do {
                totalRecorded += try await ingest(adapter)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // A pass only counts as complete when every adapter read its source.
        // A failure to record that fact is a failed pass too: the claim is
        // never made on evidence that was not stored.
        if firstError == nil {
            do {
                try await store.markActivityFullPassCompleted()
            } catch {
                firstError = error
            }
        }

        lastPassFailed = firstError != nil
        if let firstError { throw firstError }
        return totalRecorded
    }

    /// What the activity table can be trusted to contain.
    ///
    /// Everything that reads it for display needs this: until a first full
    /// pass has finished the table is empty or partly filled, which is not the
    /// same as "nothing happened", and while an adapter keeps failing a source
    /// is silently missing.
    public struct Status: Sendable, Equatable {
        /// A pass in which every adapter succeeded has finished at least once.
        /// Stored in the history database, so it survives a restart and is
        /// cleared with the data.
        public let hasCompletedFullPass: Bool
        /// The most recent pass finished with an adapter having failed.
        public let lastPassFailed: Bool
        /// A pass is running now.
        public let isRunning: Bool

        public init(hasCompletedFullPass: Bool, lastPassFailed: Bool, isRunning: Bool) {
            self.hasCompletedFullPass = hasCompletedFullPass
            self.lastPassFailed = lastPassFailed
            self.isRunning = isRunning
        }
    }

    public func status() async -> Status {
        // A database that cannot be read cannot vouch for anything: not complete.
        let completed = ((try? await store.activityFullPassCompletedAt()) ?? nil) != nil
        return Status(
            hasCompletedFullPass: completed,
            lastPassFailed: lastPassFailed,
            isRunning: isIngesting)
    }

    private func ingest(_ adapter: ActivityAdapter) async throws -> Int {
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

        return result.records.count
    }
}
