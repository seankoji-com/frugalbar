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
        /// A poll recorded after the snapshot could not be read. The
        /// snapshot's figures are from before it, and the summary does not
        /// present them as the provider's state now.
        case lastPollFailed(at: Date)
        case healthy
        case runningLow
        case critical
        case exhausted
        case blocked
    }

    /// The words and shape a state leads with. Settings' legend reads this
    /// too, so it cannot name a state the inspector does not draw.
    public static func headlineAndSymbol(for state: State) -> (headline: String, symbol: String) {
        switch state {
        case .healthy:    ("Healthy", "checkmark.circle.fill")
        case .runningLow: ("Running low", "exclamationmark.circle.fill")
        case .critical:   ("Critically low", "exclamationmark.octagon.fill")
        case .exhausted:  ("Exhausted", "xmark.octagon.fill")
        case .blocked:    ("Blocked by the vendor", BlockedGlyph.symbolName)
        case .lastPollFailed: ("The last poll could not be read", "exclamationmark.triangle.fill")
        case .unavailable: ("", "minus.circle")
        }
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
        /// What to do about an unreadable provider, or why the figures below
        /// are not current.
        public let remedy: String?
        /// The vendor blocked the focus window. The hero figure then wears a
        /// `BlockedGlyph`, as the bar's percentage does everywhere else.
        public var focusIsBlocked: Bool { state == .blocked }
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
    /// When the windows are from a snapshot that a later failed poll
    /// superseded: the instant they were fetched, which the card then names.
    /// Nil while they are the newest thing recorded.
    public let windowsAsOf: Date?
    public let provenance: [ProvenanceRow]

    /// What the inspector knows about this instance's recorded readings.
    public enum RecordedHistory: Equatable, Sendable {
        /// Not read yet: the row is left out rather than guessed.
        case loading
        /// The read failed. Said as such, never as zero readings.
        case unreadable
        /// This instance's readings recorded since `since`, the instant the
        /// read started from.
        case counted(Int, since: Date)

        /// The figure the provenance shows and Copy JSON exports, from one
        /// read: this instance's readings only, since the instant the read
        /// started from. The vendor-wide read also returns every sibling
        /// OpenCode Go workspace, and the inspector's own lookback reaches
        /// past 30 days to the start of a longer published window.
        public static func of(
            readings: [QuotaHistoryStore.ReadingRecord]?, instanceID: String, since: Date
        ) -> RecordedHistory {
            guard let readings else { return .unreadable }
            return .counted(readings.filter { $0.vendor == instanceID }.count, since: since)
        }

        /// The count, when there is one to report.
        public var count: Int? {
            if case .counted(let count, _) = self { return count }
            return nil
        }

        /// Where the counted read started, when there is a count.
        public var since: Date? {
            if case .counted(_, let since) = self { return since }
            return nil
        }
    }

    /// - Parameter readings: this vendor's recorded readings, when they were
    ///   read. A failed poll among them newer than the snapshot outranks it:
    ///   the inspector holds the snapshot it was opened with, and a provider
    ///   that has failed since must not keep reading "Healthy". A snapshot
    ///   newer than the failure is the provider's state, and stands.
    ///
    ///   A snapshot that already carries `staleReading` states the failure
    ///   itself, reason included, and needs no history read to be honest about
    ///   it — that path is what the popover row and the inspector share, so a
    ///   stale figure is never described as current even between the failed
    ///   poll and the history write that records it.
    public init(
        snapshot: QuotaSnapshot,
        history: RecordedHistory = .loading,
        readings: [QuotaHistoryStore.ReadingRecord]? = nil,
        now: Date
    ) {
        let stale = snapshot.staleReading
        let failedPoll = stale?.at ?? Self.failedPollAfter(snapshot, readings: readings)
        self.summary = Self.summary(
            for: snapshot, failedPollAt: failedPoll, staleReason: stale?.reason, now: now)
        self.windows = snapshot.status.confidence == .measured
            ? snapshot.displayBars.map { Self.windowLine($0, isCurrent: failedPoll == nil, now: now) }
            : []
        self.windowsAsOf = failedPoll == nil || windows.isEmpty ? nil : snapshot.lastUpdated
        self.provenance = Self.provenance(
            for: snapshot, history: history, failedPollAt: failedPoll,
            staleReason: stale?.reason, now: now)
    }

    /// The instance's newest recorded poll, when it failed after `snapshot`
    /// was fetched. The same rule the burndown and History read a window's
    /// current state by (`HistoryPresentation.failedLatestPoll`).
    static func failedPollAfter(_ snapshot: QuotaSnapshot, readings: [QuotaHistoryStore.ReadingRecord]?) -> Date? {
        guard let readings,
              let failed = HistoryPresentation.failedLatestPoll(readings: readings, instanceID: snapshot.id),
              failed > snapshot.lastUpdated else { return nil }
        return failed
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

    static func summary(
        for snapshot: QuotaSnapshot, failedPollAt: Date? = nil,
        staleReason: UnavailableReason? = nil, now: Date
    ) -> Summary {
        if let reason = snapshot.status.unavailableReason {
            return Summary(
                state: .unavailable(reason), headline: reason.headline, symbol: "minus.circle",
                focusLabel: nil, percentUsed: nil, figure: nil, resetText: nil, paceVerdict: nil,
                remedy: reason.remedy,
                accessibilityLabel: "\(snapshot.displayName), \(reason.headline), \(reason.remedy)")
        }
        // No hero figure, reset or pace: each would read as the provider's
        // state now, and the newest poll says nothing about that.
        if let failedPollAt {
            let state = State.lastPollFailed(at: failedPollAt)
            let (headline, symbol) = Self.headlineAndSymbol(for: state)
            // Naming the reason is the difference between "something is wrong"
            // and "your key was rejected" — the row under the bar has no room
            // for it, and it is the first thing anyone opens this card to find.
            let why = staleReason.map { " (\($0.headline))" } ?? ""
            let note = "Polled at \(clockText(failedPollAt, now: now)) without a reading\(why). "
                + "The figures below are from \(clockText(snapshot.lastUpdated, now: now)), before it, "
                + "and may be out of date."
            return Summary(
                state: state, headline: headline, symbol: symbol,
                focusLabel: nil, percentUsed: nil, figure: nil, resetText: nil, paceVerdict: nil,
                remedy: note,
                accessibilityLabel: "\(snapshot.displayName), \(headline), \(note)")
        }

        let row = MetricRowPresentation(snapshot: snapshot, now: now)
        let focus = focusBar(of: snapshot)
        let state: State
        // The focus is a blocked window whenever the vendor blocked one, with
        // or without a percentage: a 97% the vendor has cut off is not "low",
        // it is unusable, and the glance must say which.
        if focus?.isBlocked == true || snapshot.isFullyBlockedWithoutReading {
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

        let (headline, symbol) = Self.headlineAndSymbol(for: state)

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
        guard let standing = bar.paceStanding, let pace = bar.paceMarker else { return nil }
        let elapsed = Int((pace * 100).rounded())
        switch standing {
        case .ahead: return "Ahead of even pace (\(elapsed)% of the window elapsed)"
        case .behind: return "Behind even pace (\(elapsed)% of the window elapsed)"
        case .even: return "On even pace (\(elapsed)% of the window elapsed)"
        }
    }

    // MARK: - Windows

    /// `isCurrent` false for a window a later failed poll superseded: its
    /// figure is kept, as of when it was fetched, but its burn rate and
    /// run-out are forecasts from it, and are left out.
    static func windowLine(_ bar: DualBarMetrics, isCurrent: Bool = true, now: Date) -> WindowLine {
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
        if isCurrent, !bar.measuresElapsedTimeOnly, !bar.isBlocked,
           (bar.primaryFraction ?? 0) < QuotaSnapshot.exhaustionThreshold,
           bar.paceMarker != nil, let rate = bar.burnRateMultiplier {
            parts.append("burning \(String(format: "%.1f", rate))× even pace")
        }
        // Never for a blocked window: "runs out in 4h" beside "blocked" reads
        // as headroom the vendor has already withdrawn.
        if isCurrent, !bar.measuresElapsedTimeOnly, !bar.isBlocked, bar.paceMarker != nil,
           let date = bar.projectedExhaustionDate, date > now {
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

    static func provenance(
        for snapshot: QuotaSnapshot, history: RecordedHistory, failedPollAt: Date? = nil,
        staleReason: UnavailableReason? = nil, now: Date
    ) -> [ProvenanceRow] {
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
        if let failedPollAt {
            rows.append(ProvenanceRow(
                label: "Last poll",
                value: "Could not be read\(staleReason.map { " (\($0.headline))" } ?? ""), "
                    + "\(lastFetchedText(failedPollAt, now: now))"))
        }
        if let key = snapshot.keyMasked {
            rows.append(ProvenanceRow(label: "Key", value: key))
        }
        if let credits = BurndownPresentation.resetCreditsText(
            available: snapshot.resetCreditsAvailable, applicable: snapshot.resetCreditsApplicable) {
            rows.append(ProvenanceRow(label: "Reset credits", value: credits))
        }
        switch history {
        case .loading:
            break
        case .unreadable:
            rows.append(ProvenanceRow(label: "History", value: "Could not be read"))
        case .counted(let count, let since):
            rows.append(ProvenanceRow(
                label: "History",
                value: "\(count) reading\(count == 1 ? "" : "s") recorded since \(sinceText(since, now: now))"))
        }
        return rows
    }

    /// "14 Sep", or "14 Sep 2025" when the year differs from now's.
    static func sinceText(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "d MMM" : "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// "14:05 (3 min ago)" — the instant this snapshot was taken.
    static func lastFetchedText(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        let ago = minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
        return "\(clockText(date, now: now)) (\(ago))"
    }

    /// "14:05", or "14 Sep, 14:05" on another day than now's.
    static func clockText(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    /// The metric as the vendor reported it, unrounded where it matters.
    static func rawFigure(_ snapshot: QuotaSnapshot) -> String? {
        switch snapshot.metric {
        case .percentage(let used, let details):
            let base = String(format: "%.1f%% used", used * 100)
            return details.map { "\(base) · \($0)" } ?? base
        case .count(let remaining, let limit, let unit):
            return "\(remaining.formatted()) of \(limit.formatted()) \(unit) remaining"
        case .credits(let remaining, let unit):
            // The vendor's own unit, verbatim. Never reformatted as money.
            return remaining.map { "\($0.formatted()) \(unit) remaining" } ?? "\(unit) unlimited"
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
