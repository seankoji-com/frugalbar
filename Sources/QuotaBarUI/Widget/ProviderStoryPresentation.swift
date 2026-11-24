import Foundation
import QuotaBarCore

/// The desktop widget's story about one pool (owner, 23 Nov 2026: "a
/// detailed view that tells a story about the provider").
///
/// Plain sentences built only from what was measured or published: the
/// fraction, the window's reset and length, recorded history and recorded
/// events. Each sentence that projects (the run-out) names its basis; nothing
/// else projects. Units follow the glance: "% left", one time unit.
struct ProviderStoryPresentation: Equatable, Sendable {

    enum Tone: Equatable, Sendable { case good, caution, spent, unknown }

    struct Line: Equatable, Sendable, Identifiable {
        var id: String { symbol + text }
        let symbol: String
        let text: String
        var tone: Tone = .good
    }

    let poolID: String
    let title: String
    let subtitle: String
    /// "Your top pick right now", "Ranked 4th in Use now", "Back in 39h".
    let standing: String
    let tone: Tone
    /// The window the story is about, and its "% left" (nil when unmeasured).
    let window: GlancePresentation.Window?
    let windowName: String?
    let lines: [Line]

    init(pool: GlancePresentation.Pool, glance: GlancePresentation,
         readings: [QuotaHistoryStore.ReadingRecord]?, now: Date) {
        poolID = pool.id
        title = pool.name == pool.service ? pool.service : pool.name
        let plan = pool.snapshot.claudeAccount != nil ? (pool.snapshot.planName ?? "") : pool.snapshot.shortPlanName
        // "OpenCode Go Plus" already names its service: say it once.
        let service: String? = pool.name == pool.service || plan.hasPrefix(pool.service) ? nil : pool.service
        subtitle = ([service, plan.isEmpty ? nil : plan].compactMap { $0 }).joined(separator: " · ")

        let rank = glance.ranking.firstIndex { $0.pool.id == pool.id }
        let entry = glance.backSoon.first { $0.pool.id == pool.id }
        // The window the story follows: the pick's binding window, else the
        // spent window, else the pool's least-remaining long window.
        let chosen: GlancePresentation.Window? = rank.map { glance.ranking[$0].binding }
            ?? pool.windows.first(where: \.isSpent)
            ?? pool.windows.filter(\.isLong).min { ($0.remaining ?? 2) < ($1.remaining ?? 2) }
            ?? pool.windows.first
        window = chosen
        windowName = chosen.map { WindowColumn.column(forLabel: $0.bar.label)?.spokenName ?? $0.bar.label }

        switch (rank, entry, pool.state) {
        case (let r?, _, _) where glance.ranking[r].isCaveat:
            standing = "Best of what's left: nothing has 20% to spare"
            tone = .caution
        case (0?, _, _):
            standing = "Your top pick right now"
            tone = pool.isAheadOfPace ? .caution : .good
        case (let r?, _, _):
            standing = "Ranked \(Self.ordinal(r + 1)) in Use now"
            tone = pool.isAheadOfPace ? .caution : .good
        case (_, let e?, _):
            standing = e.pool.returnsAt != nil && !e.returnText.hasPrefix("Reset passed")
                ? "\(e.isBlocked ? "Blocked" : "Spent") · back in \(e.returnText)"
                : (e.isBlocked ? "Blocked · \(e.returnText.lowercased())" : e.returnText)
            tone = .spent
        case (_, _, .unreadable):
            standing = pool.snapshot.status.unavailableReason?.headline ?? "No reading"
            tone = .unknown
        case (_, _, .onBonus):
            standing = "Plan spent · running on its bonus allowance"
            tone = .caution
        default:
            standing = pool.isStale ? "Figures from an earlier poll" : "Usable, below the 20% floor"
            tone = pool.isStale ? .unknown : .caution
        }

        var lines: [Line] = []
        if pool.isStale, let stale = pool.snapshot.staleReading {
            lines.append(Line(symbol: "clock.badge.exclamationmark",
                text: "The last poll failed (\(stale.reason.headline.lowercased())). These figures are from "
                    + MetricDetailPresentation.clockText(pool.snapshot.lastUpdated, now: now) + ".", tone: .unknown))
        }
        if let w = chosen, let name = windowName {
            lines += Self.windowStory(w, name: name, pool: pool, readings: readings, now: now)
        }
        for other in pool.windows where other.bar.label != chosen?.bar.label {
            let name = WindowColumn.column(forLabel: other.bar.label)?.spokenName ?? other.bar.label
            let reset = other.bar.resetsAt.map { ", resets in \(GlancePresentation.countdown($0, now: now))" } ?? ""
            if other.isSpent {
                lines.append(Line(symbol: "nosign", text: "The \(name) window is spent\(reset).", tone: .spent))
            } else if let left = other.remaining {
                lines.append(Line(symbol: "square.stack",
                    text: "The \(name) window has \(GlancePresentation.percent(left))% left\(reset)."))
            }
        }
        if pool.hasPaidOverage {
            lines.append(Line(symbol: "creditcard", text: "Paid overage is still open; using it costs money.",
                              tone: .caution))
        }
        self.lines = lines
    }

    /// So far, pace, and what comes next, for the story's window.
    static func windowStory(_ w: GlancePresentation.Window, name: String, pool: GlancePresentation.Pool,
                            readings: [QuotaHistoryStore.ReadingRecord]?, now: Date) -> [Line] {
        var lines: [Line] = []
        let bar = w.bar
        let resetWhen = bar.resetsAt.map {
            "\(GlancePresentation.countdown($0, now: now)) (\(dayText($0)))"
        }
        if w.isSpent {
            lines.append(Line(symbol: "nosign", text: bar.isBlocked
                ? "The vendor has blocked the \(name) window."
                : "The \(name) allowance is used up.", tone: .spent))
            if let resetWhen {
                lines.append(Line(symbol: "arrow.clockwise",
                    text: bar.resetsAt! > now ? "It resets in \(resetWhen)."
                        : "Its reset was due \(dayText(bar.resetsAt!)); waiting for a reading that confirms it.",
                    tone: .unknown))
            } else {
                lines.append(Line(symbol: "questionmark.circle", text: "The vendor has not published when it resets.",
                                  tone: .unknown))
            }
            return lines
        }
        guard let used = bar.primaryFraction else {
            lines.append(Line(symbol: "questionmark.circle", text: "The vendor published no figure for this window.",
                              tone: .unknown))
            return lines
        }
        let usedPct = Int((min(max(used, 0), 1) * 100).rounded())
        // Elapsed share only where the pace tick is drawn: the same figures.
        if let elapsed = bar.paceMarker, let length = bar.windowLength {
            let elapsedSpan = GlancePresentation.countdown(now.addingTimeInterval(elapsed * length), now: now)
            lines.append(Line(symbol: "chart.line.downtrend.xyaxis",
                text: "You've used \(usedPct)% of the \(name) allowance in \(elapsedSpan); "
                    + "\(Int((elapsed * 100).rounded()))% of the window has gone."))
            if let multiplier = bar.burnRateMultiplier {
                if w.isAheadOfPace {
                    lines.append(Line(symbol: "arrowtriangle.up.fill",
                        text: "That's \(String(format: "%.1f", multiplier))× an even pace: well ahead.", tone: .caution))
                } else if multiplier > 1.05 {
                    lines.append(Line(symbol: "gauge.with.needle",
                        text: "That's \(String(format: "%.1f", multiplier))× an even pace."))
                } else {
                    lines.append(Line(symbol: "leaf", text: "That's at or under an even pace."))
                }
            }
        } else {
            lines.append(Line(symbol: "chart.line.downtrend.xyaxis",
                text: "You've used \(usedPct)% of the \(name) allowance."))
        }
        if let runOut = InspectorRunOut.compute(for: bar, in: pool.snapshot, readings: readings, now: now) {
            lines.append(Line(symbol: "hourglass", text: runOut.text + ".",
                              tone: runOut.warns ? .caution : .good))
        }
        if let resetWhen {
            lines.append(Line(symbol: "arrow.clockwise", text: "It resets in \(resetWhen)."))
        } else {
            lines.append(Line(symbol: "questionmark.circle", text: "The vendor has not published when it resets.",
                              tone: .unknown))
        }
        return lines
    }

    static func dayText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: date)
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = switch n % 100 {
        case 11, 12, 13: "th"
        default: switch n % 10 { case 1: "st"; case 2: "nd"; case 3: "rd"; default: "th" }
        }
        return "\(n)\(suffix)"
    }
}
