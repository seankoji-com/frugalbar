import Foundation
import QuotaBarCore

/// Pure presentation logic for one metric row.
///
/// Extracted from the view so it can be tested for real. Assertions against a
/// `View` value can only re-read the data they were handed — they cannot tell
/// you what the row would actually display, which is how a previous revision
/// shipped "UI tests" that would have passed against an `EmptyView` body.
public struct MetricRowPresentation: Equatable, Sendable {

    public let name: String
    /// nil means draw no bar: there is no denominator.
    public let fraction: Double?
    public let valueLabel: String
    public let resetLabel: String
    public let isMeasured: Bool
    public let urgency: Urgency
    public let accessibilityLabel: String
    /// `accessibilityLabel` without the headline percentage, for a row whose
    /// window grid already speaks each window's share: "42 percent used"
    /// followed by "5-hour 42% used" says the same figure twice. Only a
    /// percentage is dropped; a plan name or a balance is not in the grid.
    public let accessibilityLabelOmittingPercentage: String
    /// A window the vendor reports as fully spent. Deliberately narrower than
    /// `.critical` urgency, which also covers "nearly gone" — the struck-through
    /// logo is reserved for nothing-left-at-all.
    public let isExhausted: Bool
    /// What the vendor published about when the exhausted window reopens, e.g.
    /// "Resets on 1st of month". nil when it published nothing, in which case
    /// the row keeps showing the plan name rather than inventing a date.
    public let exhaustedResetText: String?

    /// One line naming figures that are not the newest poll's — the failure
    /// behind them and when they were really measured — or nil while they are
    /// current. Drawn under the row by `MetricRowView`: the bare percentages
    /// look identical whether they arrived seconds or an hour ago, so this is
    /// the only thing that says which.
    public let staleNote: String?
    /// The same fact as a sentence for VoiceOver, where the row's figures are
    /// spoken in one breath and a reader has no way to notice an absence of
    /// change. Always set and cleared together with `staleNote`.
    public let staleSpoken: String?

    /// A bar is only exhausted at the top of its range. `>= 1` would miss the
    /// floating-point residue of a percentage that arrived as 100.
    /// Defined in `QuotaSnapshot` so the popover's idea of "spent" and the
    /// sort order's cannot drift apart.
    static let exhaustionThreshold = QuotaSnapshot.exhaustionThreshold

    public init(snapshot: QuotaSnapshot, now: Date = Date()) {
        self.name = snapshot.displayName
        self.fraction = snapshot.consumptionFraction
        self.isMeasured = snapshot.status.confidence == .measured
        self.urgency = snapshot.status.urgency

        // An unreadable provider has no bars, so this reads false there — a
        // quota we could not fetch is not a quota we know is spent.
        let spentBar = snapshot.quotaBars.first { $0.primaryFractionOrUnmeasured >= Self.exhaustionThreshold }
        // A fully rate-limited account (every window blocked, no percentage
        // published) has no spent bar, but is every bit as unusable as a spent
        // one — arguably more, since nothing is "left" to measure. It counts as
        // exhausted so the avatar strikes the logo and the ✗ shows, matching
        // the energetic weight the vendor actually declared. (The spoken copy
        // below distinguishes "exhausted" from "blocked".)
        self.isExhausted = spentBar != nil || snapshot.isFullyBlockedWithoutReading
        // Reset text from a spent bar, or the first blocked bar when the whole
        // account is cut off.
        self.exhaustedResetText = spentBar?.resetText
            ?? snapshot.quotaBars.first(where: { $0.isBlocked })?.resetText

        // A reading carried over through a failed poll is not this poll's
        // reading, and is marked as such before the branches below can return:
        // the figures, the inspector's provenance and the history all have to
        // agree that they are old.
        if let stale = Self.staleDisplay(snapshot.staleReading, figuresAt: snapshot.lastUpdated, now: now) {
            self.staleNote = stale.visible
            self.staleSpoken = stale.spoken
        } else {
            self.staleNote = nil
            self.staleSpoken = nil
        }

        if let reason = snapshot.status.unavailableReason {
            self.valueLabel = reason.headline
            self.resetLabel = "—"
            // A placeholder never carries a stale figure, but if one ever did,
            // the eye and the spoken label must still agree.
            var spoken = [snapshot.displayName, reason.headline, reason.remedy]
            if let staleSpoken { spoken.append(staleSpoken) }
            self.accessibilityLabel = spoken.joined(separator: ", ")
            self.accessibilityLabelOmittingPercentage = accessibilityLabel
            return
        }

        // A subscription can publish an account state without a plan or a
        // quota figure, such as Muse's "Payment required". Keep that state
        // visible and spoken rather than drawing an empty status pill.
        let metricValue = Self.value(for: snapshot.metric)
        self.valueLabel = metricValue.isEmpty ? (snapshot.badgeText ?? metricValue) : metricValue
        self.resetLabel = ResetCountdownBadge.format(snapshot.resetsAt, now: now)

        let metricSpeech = Self.spoken(for: snapshot.metric)
        let spokenMetric = metricSpeech.isEmpty ? (snapshot.badgeText ?? metricSpeech) : metricSpeech
        var parts = [snapshot.displayName, spokenMetric].filter { !$0.isEmpty }
        if snapshot.isFullyBlockedWithoutReading {
            // The bars' own language. A screen reader must hear "blocked", not
            // "critically low" — the vendor cut the account off; it is not
            // merely low-but-usable. (Same distinction the bars draw between
            // CASE B blocked and CASE B' unmeasured.)
            parts.append("blocked")
            if let exhaustedResetText {
                parts.append(exhaustedResetText)
            }
        } else {
            if isExhausted {
                // Said outright rather than left to "critically low", which a
                // screen reader user cannot distinguish from 5% remaining.
                parts.append("exhausted")
                if let exhaustedResetText {
                    parts.append(exhaustedResetText)
                }
            }
            switch snapshot.status.urgency {
            case .none:     break
            case .warning:  parts.append("running low")
            case .critical: parts.append("critically low")
            }
        }
        if snapshot.resetsAt != nil {
            parts.append(ResetCountdownBadge.description(snapshot.resetsAt, now: now))
        }
        // Before both labels are built, so the short form the window grid uses
        // speaks it too: a row whose figures are stale must say so whichever
        // label is read out.
        if let staleSpoken {
            parts.append(staleSpoken)
        }
        self.accessibilityLabel = parts.joined(separator: ", ")
        if case .percentage = snapshot.metric, !spokenMetric.isEmpty, parts.count > 1, parts[1] == spokenMetric {
            parts.remove(at: 1)
        }
        self.accessibilityLabelOmittingPercentage = parts.joined(separator: ", ")
    }

    // MARK: - Formatting

    /// The two forms of "these figures are not this poll's": one line for the
    /// row, one sentence for VoiceOver. Built together so they cannot state
    /// different failures or different times.
    ///
    /// `figuresAt` is the snapshot's own `lastUpdated` — when the figures were
    /// measured — never the failed poll's instant. The clock text comes from
    /// `MetricDetailPresentation`, so the row under the bar and the inspector
    /// behind it name the same time for the same reading.
    static func staleDisplay(
        _ reading: StaleReading?, figuresAt: Date, now: Date
    ) -> (visible: String, spoken: String)? {
        guard let reading else { return nil }
        let at = MetricDetailPresentation.clockText(figuresAt, now: now)
        return (
            "Stale — last poll failed (\(reading.reason.headline)), figures from \(at)",
            "stale, the last poll failed (\(reading.reason.headline)), figures from \(at)"
        )
    }

    static func value(for metric: MetricType) -> String {
        switch metric {
        case .percentage(let used, _):
            "\(Int((used * 100).rounded()))%"
        case .count(let remaining, let limit, _):
            "\(remaining.formatted())/\(limit.formatted())"
        case .currency(let balance, let limit, let spent, let code):
            // An uncapped key has no "left of" to show. Falling back to
            // `spent ?? balance` printed the *balance* under a spend label —
            // real money, described as the wrong thing.
            if let limit {
                "\(currency(balance, code)) left of \(currency(limit, code))"
            } else if let spent {
                "\(currency(spent, code)) spent"
            } else {
                currency(balance, code)
            }
        case .subscription(let tierName, _):
            tierName ?? ""
        }
    }

    static func spoken(for metric: MetricType) -> String {
        switch metric {
        case .percentage(let used, _):
            "\(Int((used * 100).rounded())) percent used"
        case .count(let remaining, let limit, let unit):
            "\(remaining) of \(limit) \(unit) remaining"
        case .currency(let balance, let limit, let spent, let code):
            if let limit {
                "\(currency(balance, code)) of \(currency(limit, code)) remaining"
            } else if let spent {
                "\(currency(spent, code)) spent"
            } else {
                "\(currency(balance, code)) balance"
            }
        case .subscription(let tier, _):
            tier ?? ""
        }
    }

    static func currency(_ value: Decimal, _ code: String) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(2)))
    }
}
