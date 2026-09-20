import Foundation

/// Generates synthetic fixture history data for sample-mode demonstrations and edge-case testing.
public enum SampleDataGenerator {

    /// Ensures that the sample database exists and is populated with rich fixtures.
    /// Does not overwrite if data is already present unless `force` is true.
    public static func ensureSampleData(in store: QuotaHistoryStore, force: Bool = false) async throws {
        let existing = try await store.fetchReadings(since: Date.distantPast)
        if !existing.isEmpty && !force {
            return
        }

        let now = Date()
        let fiveHours: TimeInterval = 5 * 3600
        let oneDay: TimeInterval = 24 * 3600

        var sampleActivities: [ActivityRecord] = []

        // Generate 7 days of 5-hour rolling windows with realistic ramps and resets
        let daysToGenerate = 7
        let startTime = now.addingTimeInterval(-Double(daysToGenerate) * oneDay)

        var currentTime = startTime
        while currentTime < now {
            // Determine window start and reset for this 5-hour cycle
            let cycleIndex = Int(currentTime.timeIntervalSince1970) / Int(fiveHours)
            let windowResetsAt = Date(timeIntervalSince1970: TimeInterval((cycleIndex + 1) * Int(fiveHours)))

            // Check if this cycle represents an overnight gap (e.g. 01:00 to 07:00 local time)
            let hour = Calendar.current.component(.hour, from: currentTime)
            let isOvernight = hour >= 1 && hour < 7

            if !isOvernight {
                let progressInCycle = min(1.0, max(0.0, 1.0 - (windowResetsAt.timeIntervalSince(currentTime) / fiveHours)))
                // Create ramp up to ~75% or 100% on day 3 (exhaustion event)
                let isExhaustionDay = Calendar.current.component(.weekday, from: currentTime) == 4 && progressInCycle > 0.6
                let fraction: Double? = isExhaustionDay ? 1.0 : min(0.92, progressInCycle * 0.85 + 0.05)
                let isBlocked = isExhaustionDay

                let claudeBar = DualBarMetrics(
                    primaryFraction: fraction,
                    label: "5H",
                    isBlocked: isBlocked,
                    measuresElapsedTimeOnly: false,
                    resetsAt: windowResetsAt,
                    windowLength: fiveHours
                )

                let claudeStatus: ProviderStatus = isBlocked ? .critical : ((fraction ?? 0) > 0.8 ? .warning : .healthy)
                let claudeSnapshot = QuotaSnapshot(
                    id: "sample_claude",
                    vendorId: .claude,
                    displayName: "Claude",
                    category: .aiSubscriptions,
                    metric: .percentage(usedFraction: fraction ?? 0, displayDetails: "\(Int((fraction ?? 0) * 100))% used"),
                    status: claudeStatus,
                    resetsAt: windowResetsAt,
                    lastUpdated: currentTime,
                    auxiliaryInfo: nil,
                    row1: claudeBar
                )

                // OpenAI daily bar
                let openaiFraction = min(0.80, progressInCycle * 0.50 + 0.10)
                let openaiBar = DualBarMetrics(
                    primaryFraction: openaiFraction,
                    label: "DAILY",
                    isBlocked: false,
                    measuresElapsedTimeOnly: false,
                    resetsAt: currentTime.addingTimeInterval(oneDay),
                    windowLength: oneDay
                )
                let openaiSnapshot = QuotaSnapshot(
                    id: "sample_openai",
                    vendorId: .openai,
                    displayName: "OpenAI",
                    category: .aiSubscriptions,
                    metric: .percentage(usedFraction: openaiFraction, displayDetails: "\(Int(openaiFraction * 100))% used"),
                    status: .healthy,
                    resetsAt: currentTime.addingTimeInterval(oneDay),
                    lastUpdated: currentTime,
                    auxiliaryInfo: nil,
                    row1: openaiBar
                )

                // Record snapshots into store at `currentTime`
                try await store.record([claudeSnapshot, openaiSnapshot], now: currentTime)

                // Create associated activity records
                if Double.random(in: 0...1) < 0.7 {
                    let projectChoice = Double.random(in: 0...1)
                    let projectPath: String
                    let tokens: Int

                    if projectChoice < 0.60 {
                        projectPath = "/Users/dev/repos/frugalbar"
                        tokens = Int.random(in: 15_000...45_000)
                    } else if projectChoice < 0.85 {
                        projectPath = "/Users/dev/repos/frontend-app"
                        tokens = Int.random(in: 8_000...25_000)
                    } else {
                        projectPath = "/Users/dev/repos/data-pipeline"
                        tokens = Int.random(in: 3_000...12_000)
                    }

                    let rec = ActivityRecord(
                        source: Double.random(in: 0...1) < 0.7 ? "claude_code" : "codex",
                        recordId: UUID().uuidString,
                        sessionId: "sample_sess_\(cycleIndex)",
                        projectPath: projectPath,
                        observedAt: currentTime,
                        inputTokens: Int(Double(tokens) * 0.7),
                        outputTokens: Int(Double(tokens) * 0.3)
                    )
                    sampleActivities.append(rec)
                }
            }

            // Advance by 30 minutes
            currentTime = currentTime.addingTimeInterval(1800)
        }

        if !sampleActivities.isEmpty {
            try await store.recordActivities(sampleActivities)
        }
    }
}
