import Foundation
import QuotaBarCore

/// Pure presentation for the inspector, top to bottom: a one-line summary,
/// one line per window, and the provenance of the figures.
///
/// Every figure here is either one the vendor published or absent. The
/// summary names a pace only where `DualBarMetrics.paceMarker` would draw the
/// tick on the bar, so the inspector can never claim a pace the popover does
/// not show, and a provider we could not read gets its reason and remedy, never
/// a calm-looking empty card.
public struct MetricDetailPresentation: Equatable, Sendable {

    /// The state the summary leads with. Confidence gates urgency: an
    /// unreadable provider never reads as healthy because its unread urgency
    /// defaults to `.none`.
    public enum State: Equatable, Sendable {
        case unavailable(UnavailableReason)
        case healthy
        case runningLow
        case critical
        case exhausted
        case blocked
    }

    public struct Summary: Equatable, Sendable {
        public let state: State
        public let headline: String
        /// SF Symbol carrying the state, so it is never colour alone.
        public let symbol: String
        /// The window the hero figure describes, e.g. "WK".
        public let focusLabel: String?
        /// Percent used of `focusLabel`, when the vendor gave one.
        public let percentUsed: Int?
        /// A measured figure that is not a share of a window — a balance, a
        /// count — for providers that publish no window at all.
        public let figure: String?
        /// When the focus window resets, only when the vendor published it.
        public let resetText: String?
        /// "Ahead of even pace" and its kin, only when the pace tick is drawn.
        public let paceVerdict: String?
        /// What to do about an unreadable provider.
        public let remedy: String?
        public let accessibilityLabel: String
    }

    /// One window line in the breakdown.
    public struct WindowLine: Identifiable, Equatable, Sendable {
        public var id: String { label }
        public let label: String
        public let metrics: DualBarMetrics
        /// "42%" used (or elapsed, for a billing cycle); nil with no figure.
        public let percentText: String?
        /// Shown instead of a figure when there is none.
        public let noFigureText: String?
        public let detail: String
        public let isCycle: Bool
        public let accessibilityLabel: String
    }

    public struct ProvenanceRow: Identifiable, Equatable, Sendable {
        public var id: String { label }
        public let label: String
        /// nil renders as "Not reported", never as a placeholder value.
        public let value: String?
    }

    public let summary: Summary
    public let windows: [WindowLine]
    public let provenance: [ProvenanceRow]

    public init(snapshot: QuotaSnapshot, readingsRecorded: Int? = nil, now: Date) {
        self.summary = Self.summary(for: snapshot, now: now)
        self.windows = snapshot.status.confidence == .measured
            ? snapshot.displayBars.map { Self.windowLine($0, now: now) }
            : []
        self.provenance = Self.provenance(for: snapshot, readingsRecorded: readingsRecorded, now: now)
    }

    // MARK: - Summary

    /// The window the summary is about: a blocked one first (it decides
    /// whether the provider can be used at all), then the most consumed.
    /// Billing cycles measure elapsed time and are never the focus.
    static func focusBar(of snapshot: QuotaSnapshot) -> DualBarMetrics? {
        let bars = snapshot.quotaBars
        return bars.first(where: \.isBlocked)
            ?? bars.max { $0.primaryFractionForWorstBarRanking < $1.primaryFractionForWorstBarRanking }
    }

    static func summary(for snapshot: QuotaSnapshot, now: Date) -> Summary {
        if let reason = snapshot.status.unavailableReason {
            return Summary(
                state: .unavailable(reason), headline: reason.headline, symbol: "minus.circle",
                focusLabel: nil, percentUsed: nil, figure: nil, resetText: nil, paceVerdict: nil,
                remedy: reason.remedy,
                accessibilityLabel: "\(snapshot.displayName), \(reason.headline), \(reason.remedy)")
        }

        let row = MetricRowPresentation(snapshot: snapshot, now: now)
        let state: State
        if snapshot.isFullyBlockedWithoutReading {
            state = .blocked
        } else if row.isExhausted {
            state = .exhausted
        } else {
            switch snapshot.status.urgency {
            case .none: state = .healthy
            case .warning: state = .runningLow
            case .critical: state = .critical
            }
        }

        let focus = focusBar(of: snapshot)
        let percent = focus?.primaryFraction.map { Int((min(max($0, 0), 1) * 100).rounded()) }
        let reset = focus?.resetsAt.map { ResetCountdownBadge.description($0, now: now) }
            ?? (focus == nil ? snapshot.resetsAt.map { ResetCountdownBadge.description($0, now: now) } : nil)
        let pace = focus.flatMap(paceVerdict(for:))
        // A provider with no window still has a measured figure worth leading
        // with: a balance, a count. A subscription tier is not a figure.
        let figure: String? = {
            guard focus == nil else { return nil }
            if case .subscription = snapshot.metric { return nil }
            let value = MetricRowPresentation.value(for: snapshot.metric)
            return value.isEmpty ? nil : value
        }()

        let headline: String
        let symbol: String
        switch state {
        case .healthy:    (headline, symbol) = ("Healthy", "checkmark.circle.fill")
        case .runningLow: (headline, symbol) = ("Running low", "exclamationmark.circle.fill")
        case .critical:   (headline, symbol) = ("Critically low", "exclamationmark.octagon.fill")
        case .exhausted:  (headline, symbol) = ("Exhausted", "xmark.octagon.fill")
        case .blocked:    (headline, symbol) = ("Blocked by the vendor", BlockedGlyph.symbolName)
        case .unavailable: (headline, symbol) = ("", "minus.circle")
        }

        var spoken = [snapshot.displayName, headline]
        if let percent, let label = focus?.label {
            spoken.append("\(WindowColumn.column(forLabel: label)?.spokenName ?? label) window \(percent) percent used")
        } else if let figure {
            spoken.append(MetricRowPresentation.spoken(for: snapshot.metric).isEmpty
                          ? figure : MetricRowPresentation.spoken(for: snapshot.metric))
        }
        if let reset { spoken.append(reset) }
        if let pace { spoken.append(pace) }

        return Summary(
            state: state, headline: headline, symbol: symbol,
            focusLabel: focus?.label, percentUsed: percent, figure: figure,
            resetText: reset, paceVerdict: pace, remedy: nil,
            accessibilityLabel: spoken.joined(separator: ", "))
    }

    /// A verdict against an even pace, or nil whenever the bar would draw no
    /// pace tick: the claim and the geometry must agree.
    static func paceVerdict(for bar: DualBarMetrics) -> String? {
        guard let pace = bar.paceMarker, let used = bar.primaryFraction, !bar.isBlocked else { return nil }
        let elapsed = Int((pace * 100).rounded())
        let delta = used - pace
        if delta > DualBarMetrics.aheadOfPaceMargin {
            return "Ahead of even pace (\(elapsed)% of the window elapsed)"
        }
        if delta < -DualBarMetrics.aheadOfPaceMargin {
            return "Behind even pace (\(elapsed)% of the window elapsed)"
        }
        return "On even pace (\(elapsed)% of the window elapsed)"
    }

    // MARK: - Windows

    static func windowLine(_ bar: DualBarMetrics, now: Date) -> WindowLine {
        let percent = bar.primaryFraction.map { Int((min(max($0, 0), 1) * 100).rounded()) }
        let percentText = percent.map { "\($0)%" }
        let noFigure: String? = percent != nil ? nil : (bar.isBlocked ? "Blocked" : "No figure")

        var parts: [String] = []
        if bar.measuresElapsedTimeOnly {
            parts.append("Billing cycle you entered, elapsed time only")
        }
        if let resetsAt = bar.resetsAt {
            parts.append(ResetCountdownBadge.description(resetsAt, now: now))
        } else if let text = bar.resetText {
            parts.append(text)
        }
        if !bar.measuresElapsedTimeOnly, !bar.isBlocked,
           (bar.primaryFraction ?? 0) < QuotaSnapshot.exhaustionThreshold,
           bar.paceMarker != nil, let rate = bar.burnRateMultiplier {
            parts.append("burning \(String(format: "%.1f", rate))× even pace")
        }
        if !bar.measuresElapsedTimeOnly, bar.paceMarker != nil, let date = bar.projectedExhaustionDate, date > now {
            parts.append("runs out \(ResetCountdownBadge.description(date, now: now).replacingOccurrences(of: "Resets ", with: ""))")
        }
        if bar.isBlocked, percent != nil { parts.insert("Blocked by the vendor", at: 0) }

        let name = WindowColumn.column(forLabel: bar.label)?.spokenName ?? bar.label
        var spoken = [bar.measuresElapsedTimeOnly ? "\(name) cycle" : "\(name) window"]
        if let percent {
            spoken.append(bar.measuresElapsedTimeOnly ? "\(percent) percent elapsed" : "\(percent) percent used")
        } else if let noFigure {
            spoken.append(noFigure.lowercased())
        }
        spoken.append(contentsOf: parts)

        return WindowLine(
            label: bar.label, metrics: bar, percentText: percentText, noFigureText: noFigure,
            detail: parts.joined(separator: " · "), isCycle: bar.measuresElapsedTimeOnly,
            accessibilityLabel: spoken.joined(separator: ", "))
    }

    // MARK: - Provenance

    static func provenance(for snapshot: QuotaSnapshot, readingsRecorded: Int?, now: Date) -> [ProvenanceRow] {
        var rows: [ProvenanceRow] = [
            ProvenanceRow(label: "Source", value: snapshot.cliSource),
            ProvenanceRow(label: "Last fetched", value: lastFetchedText(snapshot.lastUpdated, now: now)),
            ProvenanceRow(label: "Latency", value: snapshot.latencyMs.map { "\($0) ms" }),
            // Only a real `planName`: a badge or vendor name in this slot is a
            // plan nobody measured.
            ProvenanceRow(label: "Plan", value: snapshot.planName),
        ]
        if snapshot.status.confidence == .measured {
            rows.append(ProvenanceRow(label: "Raw figure", value: rawFigure(snapshot)))
        }
        if let key = snapshot.keyMasked {
            rows.append(ProvenanceRow(label: "Key", value: key))
        }
        if let credits = BurndownPresentation.resetCreditsText(
            available: snapshot.resetCreditsAvailable, applicable: snapshot.resetCreditsApplicable) {
            rows.append(ProvenanceRow(label: "Reset credits", value: credits))
        }
        if let readingsRecorded {
            rows.append(ProvenanceRow(
                label: "History", value: "\(readingsRecorded) reading\(readingsRecorded == 1 ? "" : "s") recorded, last 30 days"))
        }
        return rows
    }

    /// "14:05 (3 min ago)" — the instant this snapshot was taken.
    static func lastFetchedText(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM, HH:mm"
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        let ago = minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
        return "\(formatter.string(from: date)) (\(ago))"
    }

    /// The metric as the vendor reported it, unrounded where it matters.
    static func rawFigure(_ snapshot: QuotaSnapshot) -> String? {
        switch snapshot.metric {
        case .percentage(let used, let details):
            let base = String(format: "%.1f%% used", used * 100)
            return details.map { "\(base) · \($0)" } ?? base
        case .count(let remaining, let limit, let unit):
            return "\(remaining.formatted()) of \(limit.formatted()) \(unit) remaining"
        case .currency(let balance, let limit, let spent, let code):
            var parts = ["\(snapshot.currencyBasis?.balanceLabel ?? "Balance:") \(MetricRowPresentation.currency(balance, code))"]
            if let limit { parts.append("cap \(MetricRowPresentation.currency(limit, code))") }
            if let spent {
                parts.append("\(snapshot.currencyBasis?.spendLabel ?? "Spent:") \(MetricRowPresentation.currency(spent, code))")
            }
            return parts.joined(separator: " · ")
        case .subscription(let tier, let renewal):
            var parts: [String] = []
            if let tier { parts.append(tier) }
            if let renewal { parts.append("renews \(renewal.formatted(date: .abbreviated, time: .omitted))") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}
