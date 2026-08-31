import Foundation

// MARK: - A billing cycle the user told us about

/// A renewal schedule the user entered by hand, for a subscription whose
/// vendor does not publish one.
///
/// This is not a fabricated quota. It reports no usage at all — only the one
/// thing a renewal date can answer on its own: how much of the period you have
/// already paid for is left. Every figure in it came from the user, and the UI
/// labels the row `CYCLE` so it is never mistaken for vendor telemetry.
///
/// It exists because several vendors meter usage but publish no period. DevPass
/// is the clearest case: `/v1/key` reports cycle credits and a weekly premium
/// reset, but never says when the monthly cycle itself turns over.
public struct SubscriptionCycle: Sendable, Equatable, Codable {

    /// How often the subscription renews.
    public enum Cadence: String, Sendable, Equatable, Codable, CaseIterable {
        case weekly
        case monthly
        case annual

        /// Two-letter code for the bar's right-hand column.
        public var windowCode: String {
            switch self {
            case .weekly:  "WK"
            case .monthly: "MO"
            case .annual:  "YR"
            }
        }

        public var displayName: String {
            switch self {
            case .weekly:  "Weekly"
            case .monthly: "Monthly"
            case .annual:  "Annual"
            }
        }

        /// The calendar unit one period advances by.
        var unit: Calendar.Component {
            switch self {
            case .weekly:  .weekOfYear
            case .monthly: .month
            case .annual:  .year
            }
        }
    }

    /// Any date the subscription renewed on, or will renew on. Every other
    /// renewal is derived from it by stepping whole `cadence` periods, so the
    /// day of the month is preserved across 28–31 day months rather than
    /// drifting the way a fixed 30-day interval would.
    public var anchorDate: Date

    public var cadence: Cadence

    /// What the subscription costs per period. Optional — a user who only
    /// wants the countdown should not have to invent a number.
    public var cost: Decimal?

    public var currencyCode: String

    public init(
        anchorDate: Date,
        cadence: Cadence = .monthly,
        cost: Decimal? = nil,
        currencyCode: String = "USD"
    ) {
        self.anchorDate = anchorDate
        self.cadence = cadence
        self.cost = cost
        self.currencyCode = currencyCode
    }

    // MARK: - Derived schedule

    /// Guard on the correction loops below. A handful of steps is normal; this
    /// only stops a pathological calendar from spinning.
    private static let maxCorrectionSteps = 64

    /// The first renewal strictly after `now`.
    ///
    /// Estimates the elapsed period count arithmetically, then corrects with
    /// the calendar — the estimate alone cannot survive short months, leap
    /// years, or a DST boundary landing inside the period.
    public func renewal(after now: Date, calendar: Calendar = .current) -> Date? {
        var periods = estimatedElapsedPeriods(until: now, calendar: calendar)
        guard var candidate = calendar.date(byAdding: cadence.unit, value: periods, to: anchorDate) else {
            return nil
        }

        var steps = 0
        while candidate <= now, steps < Self.maxCorrectionSteps {
            periods += 1
            steps += 1
            guard let next = calendar.date(byAdding: cadence.unit, value: periods, to: anchorDate) else {
                return nil
            }
            candidate = next
        }
        while steps < Self.maxCorrectionSteps,
              let previous = calendar.date(byAdding: cadence.unit, value: periods - 1, to: anchorDate),
              previous > now
        {
            periods -= 1
            steps += 1
            candidate = previous
        }
        return candidate > now ? candidate : nil
    }

    /// When the period ending at `renewal` began.
    public func periodStart(endingAt renewal: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: cadence.unit, value: -1, to: renewal)
    }

    /// How long the current period runs, in seconds. Measured between the two
    /// real calendar dates rather than assumed, so a 28-day February and a
    /// 31-day March each get their own length.
    public func windowLength(endingAt renewal: Date, calendar: Calendar = .current) -> TimeInterval? {
        guard let start = periodStart(endingAt: renewal, calendar: calendar) else { return nil }
        let length = renewal.timeIntervalSince(start)
        return length > 0 ? length : nil
    }

    /// Whole days between `now` and the next renewal, rounded up: a renewal
    /// eight hours away is "1 day left", not "0".
    public func daysRemaining(from now: Date, calendar: Calendar = .current) -> Int? {
        guard let renewal = renewal(after: now, calendar: calendar) else { return nil }
        let seconds = renewal.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return Int((seconds / 86_400).rounded(.up))
    }

    /// A rough count of whole periods between the anchor and `now`, before
    /// calendar correction. Never negative: an anchor in the future is period
    /// zero, and `renewal(after:)` walks back from there.
    private func estimatedElapsedPeriods(until now: Date, calendar: Calendar) -> Int {
        let elapsed: Int? = switch cadence {
        case .weekly:  calendar.dateComponents([.weekOfYear], from: anchorDate, to: now).weekOfYear
        case .monthly: calendar.dateComponents([.month], from: anchorDate, to: now).month
        case .annual:  calendar.dateComponents([.year], from: anchorDate, to: now).year
        }
        return max(0, elapsed ?? 0)
    }
}

// MARK: - Rendering

extension SubscriptionCycle {

    /// The `CYCLE` bar for a snapshot: how far through the paid-for period we
    /// are, and when it turns over.
    ///
    /// The fraction is time elapsed, not quota consumed. That is why the label
    /// is `CYCLE` rather than a window name — nothing here claims to know how
    /// much of the subscription has actually been used.
    public func cycleRow(now: Date = Date(), calendar: Calendar = .current) -> DualBarMetrics? {
        guard let renewal = renewal(after: now, calendar: calendar),
              let windowLength = windowLength(endingAt: renewal, calendar: calendar),
              let elapsed = DualBarMetrics.proRataPace(
                  resetsAt: renewal, windowLength: windowLength, now: now)
        else { return nil }

        let days = daysRemaining(from: now, calendar: calendar)
        let costText = cost.map { " • \(Self.formatCost($0, currencyCode: currencyCode))/\(cadence.displayName.lowercased())" } ?? ""

        return DualBarMetrics(
            primaryFraction: elapsed,
            // Labelled by the period it measures, like every other window in
            // the popover — a cycle that renews monthly reads "MO".
            label: cadence.windowCode,
            measuresElapsedTimeOnly: true,
            usedText: days.map { "\($0) day\($0 == 1 ? "" : "s") left in \(cadence.displayName.lowercased()) cycle\(costText)" },
            resetText: "Renews \(RelativeDateTimeFormatter().localizedString(for: renewal, relativeTo: now))",
            resetsAt: renewal,
            windowLength: windowLength
        )
    }

    /// Matches how the popover already renders a `.currency` metric, so a cost
    /// typed in here and a balance read from a vendor read the same way.
    public static func formatCost(_ amount: Decimal, currencyCode: String) -> String {
        amount.formatted(.currency(code: currencyCode).precision(.fractionLength(2)))
    }
}

// MARK: - Persistence

/// Where hand-entered renewal schedules live.
///
/// Keyed by vendor, and stored in the same `UserDefaults` suite as the rest of
/// FrugalBar's preferences — a renewal date is not a secret, so it does not
/// belong in the Keychain alongside credentials.
public enum SubscriptionCycleStore {

    public static let defaultsKey = "QuotaBarSubscriptionCycles"

    /// Every configured cycle, keyed by vendor.
    public static func all() -> [VendorIdentifier: SubscriptionCycle] {
        guard let data = CredentialStore.preferences.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: SubscriptionCycle].self, from: data)
        else { return [:] }

        return decoded.reduce(into: [:]) { result, entry in
            guard let vendor = VendorIdentifier(rawValue: entry.key) else { return }
            result[vendor] = entry.value
        }
    }

    public static func cycle(for vendor: VendorIdentifier) -> SubscriptionCycle? {
        all()[vendor]
    }

    /// Saves a cycle, or clears the vendor's cycle when `cycle` is nil.
    public static func set(_ cycle: SubscriptionCycle?, for vendor: VendorIdentifier) {
        var stored = all()
        stored[vendor] = cycle
        let encodable = stored.reduce(into: [String: SubscriptionCycle]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        CredentialStore.preferences.set(data, forKey: defaultsKey)
    }
}
