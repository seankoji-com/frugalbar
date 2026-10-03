import Foundation

/// "Is it safe to start a long run?" answered from recent history.
///
/// `DualBarMetrics.projectedExhaustionDate` extrapolates the *average* rate
/// since the window opened. A long run cares about the rate right now, so this
/// fits a line through the readings recorded in the last `defaultLookback`
/// and projects when that pace reaches the limit.
///
/// Every input is a measured reading. With too few readings, too short a
/// span, or no reset time to compare against where one matters, the forecast
/// is nil or says less — it never fills a gap with an assumed rate.
public struct BurnRateForecast: Sendable, Equatable {

    public enum Outcome: Sendable, Equatable {
        /// Usage is flat (or falling) over the lookback.
        case notBurning
        /// At the recent pace the window runs out at this date. Also used when
        /// the vendor published no reset time, since nothing says it resets first.
        case limitAt(Date)
        /// At the recent pace the window resets before it runs out.
        case resetsFirst(resetsAt: Date)
    }

    public let vendorId: VendorIdentifier
    public let barLabel: String
    /// Share of the window consumed per hour over the lookback.
    public let fractionPerHour: Double
    public let sampleCount: Int
    public let outcome: Outcome

    public init(
        vendorId: VendorIdentifier,
        barLabel: String,
        fractionPerHour: Double,
        sampleCount: Int,
        outcome: Outcome
    ) {
        self.vendorId = vendorId
        self.barLabel = barLabel
        self.fractionPerHour = fractionPerHour
        self.sampleCount = sampleCount
        self.outcome = outcome
    }

    /// How much history the pace is read from.
    public static let defaultLookback: TimeInterval = 60 * 60
    /// Fewer readings than this cannot tell a trend from one noisy poll.
    public static let minimumSamples = 3
    /// Readings must span at least this long.
    public static let minimumSpan: TimeInterval = 10 * 60
    /// Below this rate (0.1% of the window per hour) usage counts as flat.
    static let flatRatePerHour = 0.001
    /// A fall larger than this between consecutive readings is a new window
    /// (or a vendor revision); samples before it are not this window's pace.
    static let dropTolerance = 0.02

    // MARK: - Computation

    /// Forecast for one window from its recorded readings.
    ///
    /// `readings` may include other vendors and labels; they are filtered here.
    /// Returns nil when there is not enough measured history, or the window is
    /// already spent (there is nothing left to forecast).
    public static func compute(
        vendorId: VendorIdentifier,
        barLabel: String,
        readings: [QuotaHistoryStore.ReadingRecord],
        resetsAt: Date?,
        now: Date,
        lookback: TimeInterval = defaultLookback
    ) -> BurnRateForecast? {
        let windowStart = now.addingTimeInterval(-lookback)
        let usable: [(t: Date, f: Double)] = readings
            .filter {
                $0.vendor == vendorId.rawValue && $0.barLabel == barLabel
                    && $0.confidence == .measured && !$0.elapsedOnly
                    && $0.measuredAt >= windowStart && $0.measuredAt <= now
            }
            .compactMap { r in r.fraction.map { (r.measuredAt, $0) } }
            .sorted { $0.t < $1.t }

        // Keep only the samples after the last reset-sized drop, so a window
        // rolling over never reads as negative consumption.
        var segmentStart = 0
        for i in usable.indices.dropFirst() where usable[i].f < usable[i - 1].f - dropTolerance {
            segmentStart = i
        }
        let samples = Array(usable[segmentStart...])

        guard samples.count >= minimumSamples,
              let first = samples.first, let last = samples.last,
              last.t.timeIntervalSince(first.t) >= minimumSpan,
              last.f < QuotaSnapshot.exhaustionThreshold
        else { return nil }

        // Least-squares slope, fraction per second.
        let xs = samples.map { $0.t.timeIntervalSince(first.t) }
        let ys = samples.map(\.f)
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - meanX) * (y - meanY)
            den += (x - meanX) * (x - meanX)
        }
        guard den > 0 else { return nil }
        let perSecond = num / den
        let perHour = perSecond * 3600

        let outcome: Outcome
        if perHour < flatRatePerHour {
            outcome = .notBurning
        } else {
            let limitDate = last.t.addingTimeInterval((1 - last.f) / perSecond)
            if let resetsAt, resetsAt <= limitDate {
                outcome = .resetsFirst(resetsAt: resetsAt)
            } else {
                outcome = .limitAt(limitDate)
            }
        }
        return BurnRateForecast(
            vendorId: vendorId, barLabel: barLabel,
            fractionPerHour: perHour, sampleCount: samples.count, outcome: outcome
        )
    }

    /// The forecast that constrains a provider: whichever window runs out
    /// soonest; failing that, a window that is burning but resets first.
    /// Nil when no window has a forecast or none is burning.
    public static func binding(
        for snapshot: QuotaSnapshot,
        readings: [QuotaHistoryStore.ReadingRecord],
        now: Date,
        lookback: TimeInterval = defaultLookback
    ) -> BurnRateForecast? {
        guard snapshot.status.confidence == .measured else { return nil }
        let forecasts = snapshot.bars
            .filter { !$0.measuresElapsedTimeOnly }
            .compactMap {
                compute(vendorId: snapshot.vendorId, barLabel: $0.label, readings: readings,
                        resetsAt: $0.resetsAt, now: now, lookback: lookback)
            }
        let limited = forecasts.compactMap { f -> (BurnRateForecast, Date)? in
            if case .limitAt(let d) = f.outcome { return (f, d) }
            return nil
        }
        if let soonest = limited.min(by: { $0.1 < $1.1 }) { return soonest.0 }
        return forecasts.first { if case .resetsFirst = $0.outcome { return true }; return false }
    }

    // MARK: - Presentation

    /// One line for the popover, e.g. "Recent pace: 5H limit in 1h 20m".
    /// Nil when usage is flat — "nothing is happening" is not worth a line.
    public func summary(now: Date) -> String? {
        switch outcome {
        case .notBurning:
            return nil
        case .limitAt(let date):
            let remaining = date.timeIntervalSince(now)
            guard remaining > 0 else { return "Recent pace: \(barLabel) limit reached" }
            return "Recent pace: \(barLabel) limit in \(Self.formatDuration(remaining))"
        case .resetsFirst:
            return "Recent pace: \(barLabel) resets before limit"
        }
    }

    /// Rounded to the nearest minute: "45m", "1h 20m", "2d 3h".
    public static func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(1, Int((interval / 60).rounded()))
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let hours = totalMinutes / 60
        if hours < 48 { return "\(hours)h \(totalMinutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
