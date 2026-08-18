import Foundation

// MARK: - QuotaManager actor

/// Actor-isolated orchestrator that manages all provider adapters, parallel fetch,
/// cache, and state distribution to the UI.
public actor QuotaManager {

    public static let shared = QuotaManager()

    // --- State ---
    private var cache: [VendorIdentifier: CacheEntry] = [:]
    private var lastCompleteFetch: Date?
    private let cachePolicy: CachePolicy
    private var activeTask: Task<[VendorIdentifier: QuotaSnapshot], Never>?

    private struct CacheEntry: Sendable {
        let snapshot: QuotaSnapshot
        let fetchedAt: Date
    }

    private init(cachePolicy: CachePolicy = .default) {
        self.cachePolicy = cachePolicy
    }

    // MARK: Public accessors

    /// Returns cached snapshots immediately (fast path for UI).
    public func cachedSnapshots() -> [VendorIdentifier: QuotaSnapshot] {
        cache.mapValues(\.snapshot)
    }

    /// Returns all snapshots sorted by the canonical provider order.
    public func sortedSnapshots() -> [QuotaSnapshot] {
        let order: [VendorIdentifier] = [
            .claude, .gemini, .opencode, .copilot,
            .openrouter,
            .githubRest, .githubGraphql,
        ]
        let dict = cache.mapValues(\.snapshot)
        return order.compactMap { dict[$0] }
    }

    /// Returns true if cache is still fresh.
    public func isCacheFresh() -> Bool {
        guard let last = lastCompleteFetch else { return false }
        return Date().timeIntervalSince(last) < cachePolicy.cacheTTL
    }

    /// Returns the overall worst status across all providers.
    public func overallStatus() -> ProviderStatus {
        let statuses = cache.values.map(\.snapshot.status)
        return statuses.max(by: { $0.severity < $1.severity }) ?? .healthy
    }

    // MARK: Fetch (with concurrency + dedup)

    /// Ensures only one fetch runs at a time.
    /// First returns cached data immediately, then refreshes in background.
    public func refresh() async -> [VendorIdentifier: QuotaSnapshot] {
        // If a fetch is already in-flight, await it
        if let existing = activeTask {
            return await existing.value
        }

        let task = Task { await self.parallelFetch() }
        activeTask = task
        let result = await task.value
        activeTask = nil
        return result
    }

    /// Force a fresh fetch (ignores cache), called on manual refresh.
    public func forceRefresh() async -> [VendorIdentifier: QuotaSnapshot] {
        activeTask?.cancel()
        activeTask = nil
        return await refresh()
    }

    // MARK: Private

    private func parallelFetch() async -> [VendorIdentifier: QuotaSnapshot] {
        let providers: [any QuotaProvider] = allProviders()
        var results: [VendorIdentifier: QuotaSnapshot] = [:]

        await withTaskGroup(of: (VendorIdentifier, QuotaSnapshot?).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let snapshot = try await provider.fetchSnapshot()
                        return (provider.vendorId, snapshot)
                    } catch {
                        // Return a degraded snapshot on failure
                        let degraded = QuotaSnapshot(
                            id: provider.vendorId.rawValue,
                            vendorId: provider.vendorId,
                            displayName: provider.displayName,
                            category: provider.category,
                            metric: .percentage(usedFraction: 0, displayDetails: nil),
                            status: .networkError(error.localizedDescription),
                            resetsAt: nil,
                            lastUpdated: Date(),
                            auxiliaryInfo: error.localizedDescription
                        )
                        return (provider.vendorId, degraded)
                    }
                }
            }

            for await (vendorId, snapshot) in group {
                if let snapshot {
                    results[vendorId] = snapshot
                }
            }
        }

        // Update cache
        let now = Date()
        for (id, snap) in results {
            cache[id] = CacheEntry(snapshot: snap, fetchedAt: now)
        }
        lastCompleteFetch = now

        return results
    }

    private func allProviders() -> [any QuotaProvider] {
        [
            ClaudeQuotaProvider(),
            GeminiQuotaProvider(),
            OpenCodeGoProvider(),
            GitHubCopilotProvider(),
            OpenRouterProvider(),
            GitHubRestProvider(),
            GitHubGraphQLProvider(),
        ]
    }
}

// MARK: - System health summary

public struct SystemHealthSummary: Sendable {
    public let overallStatus: ProviderStatus
    public let healthyCount: Int
    public let warningCount: Int
    public let criticalCount: Int
    public let errorCount: Int
    public let lastUpdated: Date?
    public let totalProviders: Int

    public static func compute(from snapshots: [QuotaSnapshot]) -> SystemHealthSummary {
        var h = 0, w = 0, c = 0, e = 0
        var worst: ProviderStatus = .healthy
        var last: Date?

        for snap in snapshots {
            switch snap.status {
            case .healthy: h += 1
            case .warning: w += 1
            case .critical, .rateLimited: c += 1
            case .unauthenticated, .networkError, .unsupported: e += 1
            }
            if snap.status.severity > worst.severity {
                worst = snap.status
            }
            if last.map({ snap.lastUpdated > $0 }) ?? true {
                last = snap.lastUpdated
            }
        }

        return SystemHealthSummary(
            overallStatus: worst,
            healthyCount: h,
            warningCount: w,
            criticalCount: c,
            errorCount: e,
            lastUpdated: last,
            totalProviders: snapshots.count
        )
    }
}
