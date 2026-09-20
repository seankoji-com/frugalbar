import Foundation

/// Deterministic PRNG (SplitMix64) so two runs of the fixture produce identical
/// data. The generator previously used `Double.random` and `UUID()`, so a
/// "fixture" could not be replayed to reproduce a reported bug, and the random
/// record ids defeated the activity table's `(source, record_id)` dedup — every
/// `force:` regeneration appended a fresh copy of the whole table.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Generates synthetic fixture history data for sample-mode demonstrations and edge-case testing.
public enum SampleDataGenerator {

    /// Fixed seed. Changing it changes the fixture; nothing else does.
    public static let seed: UInt64 = 0x5EED_1234_ABCD_0001

    /// Number of days of fixture data, ending today.
    public static let daysToGenerate = 7

    /// The fixture day (0-based from the oldest) that shows an exhausted window.
    ///
    /// An offset from the start of the fixture, not `Calendar.component(.weekday)`:
    /// the previous version keyed this off a weekday ordinal, which made the
    /// "exhaustion event" wander onto whichever day happened to match, and made
    /// the fixture depend on the calendar in use.
    public static let exhaustionDayIndex = 2   // the third of seven days

    /// Serialises fixture generation, per target store.
    ///
    /// `ensureSampleData` is a check-then-write with an `await` between the two,
    /// so concurrent callers each observed an empty store and each wrote a full
    /// fixture. The History window used to start three of these at once (one per
    /// `.task(id:)`), which tripled the generated activity rows.
    ///
    /// Keyed on the database path rather than applied globally, and callers that
    /// arrive while a generation is running *wait* for it rather than returning:
    /// a no-op would leave them observing an empty store.
    private actor Gate {
        private var inFlight: [String: Task<Void, Error>] = [:]

        func run(for key: String, _ body: @escaping @Sendable () async throws -> Void) async throws {
            if let existing = inFlight[key] {
                try await existing.value
                return
            }

            let task = Task.detached { try await body() }
            inFlight[key] = task
            defer { inFlight[key] = nil }
            try await task.value
        }
    }

    private static let gate = Gate()

    /// Ensures that the sample database exists and is populated with fixtures.
    ///
    /// `now` is injected rather than read from the clock so the fixture is fully
    /// reproducible — including in tests, which must not depend on wall time.
    /// Does not overwrite existing data unless `force` is true; `force` clears
    /// the store first, so regeneration is idempotent rather than additive.
    public static func ensureSampleData(
        in store: QuotaHistoryStore,
        force: Bool = false,
        now: Date = Date()
    ) async throws {
        try await gate.run(for: store.databaseURL.path) {
            try await generate(in: store, force: force, now: now)
        }
    }

    private static func generate(
        in store: QuotaHistoryStore,
        force: Bool,
        now: Date
    ) async throws {
        if force {
            try await store.removeAll()
        } else {
            let existing = try await store.fetchReadings(since: Date.distantPast)
            if !existing.isEmpty { return }
        }

        let calendar = Calendar.current
        let oneDay: TimeInterval = 24 * 3600
        let fiveHours: TimeInterval = 5 * 3600
        let step: TimeInterval = 1800

        // Anchor to local midnight so the overnight gaps land at night, and so
        // the fixture covers whole days rather than a rolling window that shifts
        // with the clock.
        let todayStart = calendar.startOfDay(for: now)
        let startTime = calendar.date(
            byAdding: .day,
            value: -(daysToGenerate - 1),
            to: todayStart
        ) ?? now.addingTimeInterval(-Double(daysToGenerate - 1) * oneDay)

        var rng = SplitMix64(seed: seed)
        var sampleActivities: [ActivityRecord] = []
        var currentTime = startTime
        var slotIndex = 0

        while currentTime < now {
            let dayIndex = Int(currentTime.timeIntervalSince(startTime) / oneDay)
            let cycleIndex = Int(currentTime.timeIntervalSince1970) / Int(fiveHours)
            let windowResetsAt = Date(timeIntervalSince1970: TimeInterval((cycleIndex + 1) * Int(fiveHours)))

            // Overnight gap (01:00–07:00 local), so the chart's gap handling has
            // something real to break on.
            let hour = calendar.component(.hour, from: currentTime)
            let isOvernight = hour >= 1 && hour < 7

            if !isOvernight {
                let progressInCycle = min(1.0, max(0.0, 1.0 - (windowResetsAt.timeIntervalSince(currentTime) / fiveHours)))
                let isExhaustionDay = dayIndex == exhaustionDayIndex && progressInCycle > 0.6

                let fraction: Double = isExhaustionDay ? 1.0 : min(0.92, progressInCycle * 0.85 + 0.05)
                let isBlocked = isExhaustionDay

                let claudeBar = DualBarMetrics(
                    primaryFraction: fraction,
                    label: "5H",
                    isBlocked: isBlocked,
                    measuresElapsedTimeOnly: false,
                    resetsAt: windowResetsAt,
                    windowLength: fiveHours
                )

                let claudeStatus: ProviderStatus = isBlocked ? .critical : (fraction > 0.8 ? .warning : .healthy)
                let claudeSnapshot = QuotaSnapshot(
                    id: "sample_claude",
                    vendorId: .claude,
                    displayName: "Claude",
                    category: .aiSubscriptions,
                    metric: .percentage(usedFraction: fraction, displayDetails: "\(Int(fraction * 100))% used"),
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

                try await store.record([claudeSnapshot, openaiSnapshot], now: currentTime)

                if Double.random(in: 0...1, using: &rng) < 0.7 {
                    let projectChoice = Double.random(in: 0...1, using: &rng)
                    let projectPath: String
                    let tokens: Int

                    if projectChoice < 0.60 {
                        projectPath = "/Users/dev/repos/frugalbar"
                        tokens = Int.random(in: 15_000...45_000, using: &rng)
                    } else if projectChoice < 0.85 {
                        projectPath = "/Users/dev/repos/frontend-app"
                        tokens = Int.random(in: 8_000...25_000, using: &rng)
                    } else {
                        projectPath = "/Users/dev/repos/data-pipeline"
                        tokens = Int.random(in: 3_000...12_000, using: &rng)
                    }

                    let isClaude = Double.random(in: 0...1, using: &rng) < 0.7
                    let input = Int(Double(tokens) * 0.7)
                    let output = Int(Double(tokens) * 0.3)

                    sampleActivities.append(ActivityRecord(
                        source: isClaude ? "claude_code" : "codex",
                        // Derived from the fixture position, not a UUID: a stable
                        // id is what lets `force:` replace rather than duplicate.
                        recordId: "sample-\(dayIndex)-\(slotIndex)-\(isClaude ? "claude" : "codex")",
                        sessionId: "sample_sess_\(dayIndex)",
                        projectPath: projectPath,
                        observedAt: currentTime,
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0
                    ))
                }
            }

            slotIndex += 1
            currentTime = currentTime.addingTimeInterval(step)
        }

        if !sampleActivities.isEmpty {
            try await store.recordActivities(sampleActivities)
        }
    }
}
