import Foundation

/// Coordinates collecting activity from CLI adapters and committing them to the history store.
public actor ActivityIngestionEngine {
    private let store: QuotaHistoryStore
    private let adapters: [ActivityAdapter]

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
    /// Returns the total number of newly recorded records.
    @discardableResult
    public func ingestAll() async throws -> Int {
        var totalRecorded = 0

        for adapter in adapters {
            let watermarkMtime = try await store.maxWatermarkMtime(for: adapter.sourceIdentifier)
            let (records, maxMtime) = try await adapter.collectActivities(since: watermarkMtime)

            if !records.isEmpty {
                try await store.recordActivities(records)
                totalRecorded += records.count
            }

            if let maxMtime, maxMtime > (watermarkMtime ?? 0) {
                try await store.setWatermark(
                    source: adapter.sourceIdentifier,
                    filePath: "*",
                    modifiedAt: maxMtime
                )
            }
        }

        return totalRecorded
    }
}
