import SwiftUI
import QuotaBarCore

struct ProviderGridView: View {
    let presentation: ProviderGridPresentation
    var onSelect: (QuotaSnapshot) -> Void = { _ in }
    @State var expanded: VendorIdentifier?

    private let nameWidth: CGFloat = 129
    private let trackHeight: CGFloat = 3

    var body: some View {
        if !presentation.groups.isEmpty {
            GlanceCard {
                GlanceSectionHeader(title: "Subscriptions")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                Divider()
                line {
                    Text("% used").foregroundStyle(Theme.outline)
                } figures: {
                    columns { column in
                        Text(column.label)
                            .foregroundStyle(Theme.outline)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.vertical, 5)
                .accessibilityHidden(true)
                ForEach(presentation.groups) { group in
                    Divider()
                    groupButton(group)
                    if expanded == group.id {
                        VStack(spacing: 0) {
                            ForEach(group.pools) { pool in
                                Divider()
                                poolButton(pool)
                            }
                        }
                        .background(Theme.surfaceContainerHighest.opacity(0.25))
                    }
                }
                Divider()
                Text("Averages use reported windows. Ticks mark even pace.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.outline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
        }
    }

    private func groupButton(_ group: ProviderGridPresentation.Group) -> some View {
        Button {
            expanded = expanded == group.id ? nil : group.id
        } label: {
            line {
                identity(
                    group.title, subtitle: group.subtitle, vendor: group.id, status: .measured(.none),
                    spent: group.allSpent, reset: presentation.countdown(group.nextReturn), size: 23
                )
                .accessibilityHidden(true)
            } figures: {
                if group.pools.count == 1, let pool = group.pools.first,
                   let column = pool.spanningColumn, let window = pool.windows[column] {
                    windowCell(window, label: column.label, stale: pool.isStale)
                } else if group.pools.count == 1, let pool = group.pools.first,
                          pool.windows.isEmpty, let bar = pool.nonstandardPlanBar {
                    HStack(spacing: 7) {
                        Text(bar.label).font(.system(size: 10)).foregroundStyle(Theme.outline)
                        windowCell(GlancePresentation.window(for: bar, now: presentation.now),
                                   label: bar.label, stale: pool.isStale, showSpentPercent: true)
                    }
                } else {
                    columns { column in
                        if let summary = group.summary(for: column) {
                            summaryCell(summary, column: column, stale: group.pools.count == 1 && group.pools[0].isStale)
                        }
                    }
                }
            } trailing: {
                Image(systemName: expanded == group.id ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.outline)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .background(expanded == group.id ? Theme.surfaceContainerHighest.opacity(0.25) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(groupAccessibilityLabel(group))
        .accessibilityHint(expanded == group.id ? "Collapse accounts" : "Expand accounts")
    }

    private func poolButton(_ pool: ProviderGridPresentation.Pool) -> some View {
        Button { onSelect(pool.snapshot) } label: {
            VStack(alignment: .leading, spacing: 5) {
                line {
                    identity(
                        pool.name, subtitle: pool.source, vendor: pool.snapshot.vendorId,
                        status: pool.snapshot.status, spent: pool.state == .spent,
                        reset: presentation.countdown(pool.returnsAt, stale: pool.isStale), size: 18
                    )
                    .padding(.leading, 3)
                } figures: {
                    if let column = pool.spanningColumn, let window = pool.windows[column] {
                        windowCell(window, label: column.label, stale: pool.isStale)
                    } else if pool.state == .unreadable
                                || (pool.state == .spent && pool.windows.isEmpty && pool.nonstandardPlanBar == nil) {
                        Text(pool.snapshot.status.unavailableReason?.headline
                             ?? (pool.state == .spent ? "Blocked" : "No quota reading"))
                            .font(.system(size: 11))
                            .foregroundStyle(pool.state == .spent ? Theme.errorBold : Theme.outline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        columns { column in
                            if let window = pool.displayWindows[column] {
                                let showPercent = pool.displayWindows.values.filter(\.isSpent).count > 1
                                windowCell(window, label: column.label, stale: pool.isStale, showSpentPercent: showPercent)
                            }
                        }
                    }
                }
                if pool.isStale || pool.state == .onBonus {
                    Text(pool.isStale ? "Last reading · refresh failed" : "On bonus allowance")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 14)
                }
                if pool.windows.isEmpty, case .unsupported(let detail)? = pool.snapshot.status.unavailableReason {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.outline)
                        .padding(.horizontal, 14)
                }
                ForEach(Array(pool.extraBars.enumerated()), id: \.offset) { _, bar in
                    let window = GlancePresentation.window(for: bar, now: presentation.now)
                    if bar.measuresElapsedTimeOnly || bar.primaryFraction == nil && !bar.isBlocked {
                        if let caption = bar.balanceCaption ?? bar.usedText ?? bar.resetText {
                            Text("\(bar.label) · \(caption)")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.outline)
                                .padding(.horizontal, 14)
                        }
                    } else {
                        // The shared `line`, so this bar keeps the trailing
                        // slot every row reserves and ends where theirs do.
                        line {
                            // A model's reset tickets sit beside that model's
                            // line, in the account they reset (owner, 24 Nov 2026).
                            HStack(spacing: 4) {
                                Text(bar.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.outline)
                                if let tickets = MetricRowPresentation(snapshot: pool.snapshot, now: presentation.now)
                                    .modelResetCredits(for: bar.label) {
                                    ModelTicketsBadge(credits: tickets)
                                }
                            }
                        } figures: {
                            windowCell(window, label: bar.label, stale: pool.isStale, showSpentPercent: true)
                        }
                    }
                }
            }
            .padding(.vertical, 5)
            .frame(minHeight: 39)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open usage details")
    }

    /// A model's banked reset tickets, beside that model's line: one gold
    /// ticket per credit (capped, with an exact `+n`) and the soonest
    /// published expiry. Each ticket's tooltip gives its own expiry.
    struct ModelTicketsBadge: View {
        let credits: MetricRowPresentation.ResetCredits

        var body: some View {
            HStack(spacing: 2) {
                ForEach(0..<credits.tickets, id: \.self) { index in
                    GoldenTicketView(index: index)
                        .frame(width: 13)
                        .help(credits.expiryText(at: index, now: credits.now))
                }
                if credits.overflow > 0 {
                    Text("+\(credits.overflow)")
                }
                // The soonest published expiry, compact; nothing when none
                // was published (never the reset window's date).
                if let expiry = credits.expiries.compactMap({ $0 }).min(),
                   let compact = ResetCountdownBadge.compact(expiry, now: credits.now) {
                    Text(compact)
                }
            }
            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.onSurfaceVariant)
            .accessibilityLabel(credits.spoken)
        }
    }

    private func identity(
        _ title: String, subtitle: String?, vendor: VendorIdentifier, status: ProviderStatus,
        spent: Bool, reset: String?, size: CGFloat
    ) -> some View {
        HStack(spacing: 8) {
            VendorAvatarView(
                vendorId: vendor, status: status, isExhausted: spent,
                exhaustedReset: reset, showsResetOverlay: true, size: size
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onSurface)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.outline)
                }
            }
            .lineLimit(1)
        }
    }

    private func line<Name: View, Figures: View, Trailing: View>(
        @ViewBuilder name: () -> Name, @ViewBuilder figures: () -> Figures,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 7) {
            name().frame(width: nameWidth, alignment: .leading)
            figures().frame(maxWidth: .infinity, alignment: .leading)
            trailing().frame(width: 8)
        }
        .padding(.horizontal, 14)
    }

    private func line<Name: View, Figures: View>(
        @ViewBuilder _ name: () -> Name, @ViewBuilder figures: () -> Figures
    ) -> some View {
        line(name: name, figures: figures) { Color.clear }
    }

    private func columns<Cell: View>(@ViewBuilder _ cell: @escaping (WindowColumn) -> Cell) -> some View {
        HStack(spacing: 7) {
            ForEach(WindowColumn.allCases) { column in
                ZStack {
                    Color.clear.frame(height: 0)
                    cell(column)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func groupAccessibilityLabel(_ group: ProviderGridPresentation.Group) -> String {
        var parts = [group.title, group.subtitle].compactMap { $0 }
        let single = group.pools.count == 1 ? group.pools.first : nil
        if let single, single.windows.isEmpty, let bar = single.nonstandardPlanBar {
            let window = GlancePresentation.window(for: bar, now: presentation.now)
            if window.isSpent {
                parts.append("\(bar.label), \(spentDescription(window))")
            } else if let used = window.used {
                parts.append("\(bar.label), \(used.formatted(.percent)) used")
            }
            if let reset = presentation.countdown(bar.resetsAt, stale: single.isStale) {
                parts.append("resets in \(reset)")
            }
        }
        let spokenColumns = single?.spanningColumn.map { [$0] } ?? WindowColumn.allCases
        for column in spokenColumns {
            guard let summary = group.summary(for: column) else { continue }
            let result: String
            let reset: Date?
            switch summary {
            case .average(let remaining, let reported, let count):
                result = "\((1 - remaining).formatted(.percent)) used across \(reported) of \(count) pools"
                reset = nil
            case .spent(let next, let exhausted, let blocked):
                result = exhausted && !blocked ? "all spent" : "all blocked or spent"
                reset = next
            case .window(let window):
                if window.isSpent {
                    result = spentDescription(window)
                } else if let used = window.used {
                    result = "\(used.formatted(.percent)) used"
                } else {
                    continue
                }
                reset = window.bar.resetsAt
            }
            let resetText = presentation.countdown(reset, stale: single?.isStale == true)
                .map { ", resets in \($0)" } ?? ""
            parts.append("\(column.spokenName), \(result)\(resetText)")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func summaryCell(_ summary: ProviderGridPresentation.Summary, column: WindowColumn, stale: Bool) -> some View {
        switch summary {
        case .window(let window):
            windowCell(window, label: column.label, stale: stale)
        case .spent(let reset, let allMeasuredExhausted, let includesBlocked):
            spentCell(allMeasuredExhausted ? "100%" : "Blocked", reset: presentation.countdown(reset),
                      spoken: "\(column.spokenName), \(includesBlocked ? "all blocked or spent" : "all spent")",
                      showsBlockedGlyph: allMeasuredExhausted && includesBlocked)
        case .average(let remaining, let reported, let count):
            VStack(alignment: .trailing, spacing: 2) {
                Text(1 - remaining, format: .percent.precision(.fractionLength(0...1)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.onSurface)
                Text(reported == 1 ? "\(reported)/\(count)" : "avg · \(reported)/\(count)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.outline)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(column.spokenName): \((1 - remaining).formatted(.percent)) used across \(reported) of \(count) pools")
        }
    }

    @ViewBuilder
    private func windowCell(
        _ window: ProviderGridPresentation.Window, label: String, stale: Bool, showSpentPercent: Bool = false
    ) -> some View {
        let reset = presentation.countdown(window.bar.resetsAt, stale: stale)
        if window.isSpent {
            let exhausted = WindowGridPresentation.isExhausted(window.bar)
            let title = exhausted ? (showSpentPercent ? "100%" : label) : "Blocked"
            spentCell(title, reset: reset, spoken: "\(label), \(spentDescription(window))",
                      showsBlockedGlyph: exhausted && window.bar.isBlocked)
                .opacity(stale ? 0.65 : 1)
        } else if let used = window.used {
            VStack(alignment: .leading, spacing: 3) {
                UsageBar(window: window, height: trackHeight)
                // Always printed, 0% included: an empty bar with no figure
                // reads as "no reading".
                meterCaption(used.formatted(.percent.precision(.fractionLength(0))),
                             reset: reset, color: GlanceColors.text(for: window))
            }
            .opacity(stale ? 0.65 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([ "\(label), \(used.formatted(.percent)) used",
                                 reset.map { "resets in \($0)" } ].compactMap { $0 }.joined(separator: ", "))
        }
    }

    private func spentDescription(_ window: ProviderGridPresentation.Window) -> String {
        if WindowGridPresentation.isExhausted(window.bar) {
            return window.bar.isBlocked ? "100 percent used, blocked" : "100 percent used"
        }
        return "blocked"
    }

    private func spentCell(_ title: String, reset: String?, spoken: String, showsBlockedGlyph: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Capsule()
                .fill(Theme.errorBold.opacity(0.6))
                .overlay(ExhaustionStripes().fill(Theme.errorBold).clipShape(Capsule()))
                .frame(height: trackHeight)
                .accessibilityHidden(true)
            meterCaption(title, reset: reset, color: Theme.error, showsBlockedGlyph: showsBlockedGlyph)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken + (reset.map { ", resets in \($0)" } ?? ""))
    }

    private func meterCaption(_ label: String?, reset: String?, color: Color, showsBlockedGlyph: Bool = false) -> some View {
        HStack(spacing: 3) {
            if showsBlockedGlyph {
                BlockedGlyph(color: color, size: 8)
            }
            if let label {
                Text(label).fontWeight(.semibold).foregroundStyle(color)
            }
            Spacer(minLength: 0)
            if let reset {
                Text(reset).foregroundStyle(Theme.outline)
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .lineLimit(1)
    }
}
