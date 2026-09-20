import Foundation

/// Coordinates collecting activity from CLI adapters and committing them to the history store.
public actor ActivityIngestionEngine {
    private let store: QuotaHistoryStore
    private let adapters: [ActivityAdapter]
    private var isIngesting = false

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

        if let firstError { throw firstError }
        return totalRecorded
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
