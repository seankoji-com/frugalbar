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
                GlanceSectionHeader(title: "Providers")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                Divider()
                line {
                    Text("% left").foregroundStyle(Theme.outline)
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
                            ForEach(group.balances) { balance in
                                Divider()
                                balanceButton(balance)
                            }
                        }
                        .background(Theme.surfaceContainerHighest.opacity(0.25))
                    }
                }
                Divider()
                Text("Averages use reported windows. Red percentages show % used. Ticks mark even pace.")
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
                    } else if pool.state == .unreadable || (pool.state == .spent && pool.windows.isEmpty) {
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
                        HStack(spacing: 7) {
                            Text(bar.label)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.outline)
                                .frame(width: nameWidth, alignment: .leading)
                            windowCell(window, label: bar.label, stale: pool.isStale)
                        }
                        .padding(.horizontal, 14)
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

    private func balanceButton(_ snapshot: QuotaSnapshot) -> some View {
        Button { onSelect(snapshot) } label: {
            HStack {
                Text(snapshot.vendorId == .deepseek ? "DeepSeek API credit" : snapshot.rowTitle)
                    .font(.system(size: 11.5))
                Spacer()
                if snapshot.staleReading != nil {
                    Text("Last reading")
                        .foregroundStyle(Theme.tertiary)
                        .font(.system(size: 10))
                }
                Text(snapshot.status.unavailableReason?.headline ?? MetricRowPresentation.value(for: snapshot.metric))
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(balanceColor(snapshot.metric))
            }
            .foregroundStyle(Theme.onSurface)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open usage details")
    }

    private func balanceColor(_ metric: MetricType) -> Color {
        if case .currency(let balance, _, _, _) = metric, balance < 0 { return Theme.error }
        return Theme.onSurface
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
        let spokenColumns = single?.spanningColumn.map { [$0] } ?? WindowColumn.allCases
        for column in spokenColumns {
            guard let summary = group.summary(for: column) else { continue }
            let result: String
            let reset: Date?
            switch summary {
            case .average(let fraction, let reported, let count):
                result = "\(fraction.formatted(.percent)) left across \(reported) of \(count) pools"
                reset = nil
            case .spent(let next, let exhausted):
                result = exhausted ? "all spent" : "all blocked or spent"
                reset = next
            case .window(let window):
                if window.isSpent {
                    result = WindowGridPresentation.isExhausted(window.bar) ? "100 percent used" : "blocked"
                } else if let remaining = window.remaining {
                    result = "\(remaining.formatted(.percent)) left"
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
        case .spent(let reset, let allMeasuredExhausted):
            spentCell(allMeasuredExhausted ? "100%" : "Blocked", reset: presentation.countdown(reset),
                      spoken: "\(column.spokenName), \(allMeasuredExhausted ? "all spent" : "all blocked or spent")")
        case .average(let remaining, let reported, let count):
            VStack(alignment: .trailing, spacing: 2) {
                Text(remaining, format: .percent.precision(.fractionLength(0...1)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.onSurface)
                Text(reported == 1 ? "\(reported)/\(count)" : "avg · \(reported)/\(count)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.outline)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(column.spokenName): \(remaining.formatted(.percent)) left across \(reported) of \(count) pools")
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
            spentCell(title, reset: reset, spoken: "\(label), \(exhausted ? "100 percent used" : "blocked")")
        } else if let remaining = window.remaining {
            VStack(alignment: .leading, spacing: 3) {
                RemainingBar(window: window, height: trackHeight)
                meterCaption(remaining == 1 ? nil : remaining.formatted(.percent.precision(.fractionLength(0))),
                             reset: reset, color: GlanceColors.text(for: window))
            }
            .opacity(stale ? 0.65 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([ "\(label), \(remaining.formatted(.percent)) left",
                                 reset.map { "resets in \($0)" } ].compactMap { $0 }.joined(separator: ", "))
        }
    }

    private func spentCell(_ title: String, reset: String?, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Capsule()
                .fill(Theme.errorBold.opacity(0.6))
                .overlay(ExhaustionStripes().fill(Theme.errorBold).clipShape(Capsule()))
                .frame(height: trackHeight)
                .accessibilityHidden(true)
            meterCaption(title, reset: reset, color: Theme.error)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken + (reset.map { ", resets in \($0)" } ?? ""))
    }

    private func meterCaption(_ label: String?, reset: String?, color: Color) -> some View {
        HStack(spacing: 3) {
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
