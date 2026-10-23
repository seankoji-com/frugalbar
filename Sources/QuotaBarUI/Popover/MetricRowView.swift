import SwiftUI
import QuotaBarCore

/// A single provider row: vendor mark, name and plan, then one cell per
/// window column (5H / WK / MO, see `WindowColumn`) so the same window lines
/// up down the card. Pools that are not a window (bonus credits, overage,
/// on-demand) get their own line under the row.
struct MetricRowView: View {

    let snapshot: QuotaSnapshot
    var onSelect: ((QuotaSnapshot) -> Void)? = nil
    /// Recent-pace forecast from history, when there is enough of it. Shown
    /// only while the row is hovered.
    var forecast: BurnRateForecast? = nil
    /// The last row in its card shows the hover forecast above itself, so the
    /// card's bottom edge and the scroll view never clip it.
    var forecastAbove: Bool = false
    /// Recorded balance-over-time points for this row's money series, oldest
    /// first. Empty when the row is not a money row, or its series has no
    /// history yet — in which case nothing is drawn rather than a flat line.
    var balancePoints: [BalancePoint] = []

    var isGrouped: Bool = false
    var suppressPlan: Bool = false

    @ScaledMetric(relativeTo: .caption) private var barWidth: CGFloat = 84
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isHovered = false

    private func urgencyColor(_ p: MetricRowPresentation) -> Color {
        switch p.urgency {
        case .none:     Theme.secondary
        case .warning:  Theme.tertiary
        case .critical: Theme.error
        }
    }

    /// The second line of the name column. Published exhausted reset text wins.
    /// Otherwise draw the plan unless `suppressPlan`, when the header already
    /// states it. A suppressed, exhausted workspace without reset text leaves
    /// this slot empty too; it must not repeat the plan.
    private func subtitle(_ p: MetricRowPresentation) -> String {
        PopoverRowGrouping.subtitle(for: snapshot, suppressPlan: suppressPlan, presentation: p)
    }

    private func subtitleColor(_ p: MetricRowPresentation) -> Color {
        p.isExhausted ? Theme.error : Theme.onSurfaceVariant.opacity(0.85)
    }

    @ViewBuilder
    var body: some View {
        if let onSelect {
            Button { onSelect(snapshot) } label: { rowContent }
                .buttonStyle(.plain)
                .accessibilityHint("Open usage details")
                .zIndex(isHovered ? 1 : 0)
        } else {
            rowContent
                .zIndex(isHovered ? 1 : 0)
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        // The windows actually drawn, placed in their columns. The
        // exhausted-window collapse lives on the model
        // (`QuotaSnapshot.displayBars`) so the popover and the inspector agree
        // on which windows a spent longer period makes redundant; a collapsed
        // window leaves its cell empty.
        //
        // Built once per render, and it carries the instant: every countdown
        // the row draws or speaks reads `grid.now`, never its own clock.
        let grid = WindowGridPresentation(snapshot: snapshot)
        // One presentation per render, built from the grid's instant. Every
        // string below that names a time — the stale note's "figures from
        // 14:12", the spoken label — is therefore measured from the same clock
        // the cells draw their countdowns from, and none of them can straddle a
        // minute boundary and disagree with the others.
        let p = MetricRowPresentation(snapshot: snapshot, now: grid.now)
        let label = combinedAccessibilityLabel(grid: grid, presentation: p)
        VStack(alignment: .leading, spacing: 4) {
            row(grid, presentation: p)
            ForEach(Array(grid.extras.enumerated()), id: \.offset) { _, bar in
                extraRow(bar)
            }
            if let staleNote = p.staleNote {
                staleReadingRow(staleNote)
            }
            if let credits = p.resetCredits {
                resetCreditRow(credits)
            }
            if let monthly = p.monthlyCreditLine {
                VStack(alignment: .leading, spacing: 2) {
                    Label(monthly, systemImage: "calendar")
                    if let detail = p.monthlyCreditDetail { Text(detail) }
                }
                .font(Theme.Typography.subtitle)
                .foregroundStyle(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(p.subscriptionCredits.enumerated()), id: \.offset) { _, credit in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "plus.circle")
                    Text("Usage credits: \(credit.figure)")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(Theme.Typography.subtitle)
                .foregroundStyle(Theme.onSurfaceVariant)
                .padding(.leading, Theme.gridLeadingInset)
            }
        }
        .padding(.vertical, isGrouped ? 4 : 8)
        .frame(minHeight: isGrouped ? Theme.groupedRowMinHeight : Theme.rowMinHeight)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
                .padding(.horizontal, -6)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // The recent-pace forecast floats over the neighbouring row instead
        // of taking a line of its own: shown on hover only, and without
        // moving anything, so the popover never resizes under the pointer.
        .overlay(alignment: forecastAbove ? .top : .bottom) {
            if isHovered, let forecastText = forecastText(now: grid.now) {
                forecastBubble(forecastText)
                    .offset(y: forecastAbove ? -Self.bubbleOffset : Self.bubbleOffset)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// The row collapses into a single accessibility element via
    /// `.accessibilityElement(children: .ignore)` above, which means any
    /// `.accessibilityLabel` set on a child (the reset-credit tickets and the
    /// stale note below) is never reached by VoiceOver — only this one label is
    /// announced. The credits' count is folded in here rather than left on the
    /// glyph strip, where a shape channel alone would silently be the only
    /// carrier (AGENTS.md, WCAG 1.4.1).
    ///
    /// Internal rather than `private` only so the layout check in the default
    /// test suite can compose the same label from its own presentations; the
    /// row's `body` is the sole production caller.
    func combinedAccessibilityLabel(
        grid: WindowGridPresentation, presentation: MetricRowPresentation
    ) -> String {
        let label = presentation.combinedAccessibilityLabel(windows: grid.spokenSummary(),
            forecast: forecastText(now: grid.now), creditsStale: snapshot.staleReading != nil)
        return PopoverRowGrouping.accessibilityPrefix(for: snapshot).map { "\($0). \(label)" } ?? label
    }

    /// Only for a provider we are currently reading: a forecast under an
    /// unavailable row would describe usage we can no longer see, and a
    /// reading carried over from a failed poll is exactly that.
    private func forecastText(now: Date) -> String? {
        guard snapshot.status.confidence == .measured, snapshot.staleReading == nil else { return nil }
        return forecast?.summary(now: now)
    }

    /// How far the hover bubble sits past the row edge: it overlaps the row
    /// by a few points so it reads as belonging to it.
    private static let bubbleOffset: CGFloat = 16

    /// Shared with the default-suite layout check at the actual name width.
    var titleView: some View {
        Text(isGrouped ? PopoverRowGrouping.rowTitle(for: snapshot) : snapshot.rowTitle)
            .font(isGrouped ? Theme.Typography.subtitle : Theme.Typography.title)
            .tracking(isGrouped ? 0 : Theme.Tracking.title)
            .foregroundStyle(isGrouped ? Theme.onSurfaceVariant : Theme.onSurface)
            .lineLimit(snapshot.instanceIdOrNil == nil && snapshot.vendorId != .antigravityClaude ? 1 : 2)
            .fixedSize(horizontal: false, vertical: true)
            .minimumScaleFactor(0.85)
    }

    private func forecastBubble(_ text: String) -> some View {
        PaceForecastBubble(text: text, isUrgent: forecastIsUrgent)
    }

    /// Limit projected inside the reset window at the recent pace.
    private var forecastIsUrgent: Bool {
        if case .limitAt = forecast?.outcome { return true }
        return false
    }

    /// Banked reset credits the vendor granted, one ticket glyph each, capped
    /// at `ResetCredits.maxTickets` with a "+n" for the remainder — so a large
    /// grant still states its exact count instead of running off the row.
    ///
    /// Its own line under the row, like the non-window pools above it: a reset
    /// credit is not a window and has no bar, and the row's 332pt budget has no
    /// column left to put it in. Carries no accessibility label of its own —
    /// the parent row ignores child elements, so the count is spoken by
    /// `combinedAccessibilityLabel`.
    private func resetCreditRow(_ credits: MetricRowPresentation.ResetCredits) -> some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: Theme.gridLeadingInset, height: 1)
            ForEach(0..<credits.tickets, id: \.self) { _ in
                Image(systemName: "ticket")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onSurface)
            }
            if credits.overflow > 0 {
                Text("+\(credits.overflow)")
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    /// Under the row when this poll could not read the provider and the figures
    /// above are carried over from an earlier one.
    ///
    /// A percentage that arrived an hour ago is drawn exactly like one that
    /// arrived a second ago, so without this line the row reports the last
    /// known state as the current one — the failure that left the footer's
    /// "oldest reading" frozen while every figure on screen looked live. The
    /// triangle carries the meaning as a shape, not colour alone (WCAG 1.4.1),
    /// and the whole row's accessibility label speaks the same sentence.
    private func staleReadingRow(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            Text(text)
                .font(Theme.Typography.subtitle)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                // Let the failure and reading time wrap in full. Both were
                // clipped away in the narrow window grid's trailing column.
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.rowAvatarSize + Theme.rowSpacing)
    }

    private func row(_ grid: WindowGridPresentation, presentation p: MetricRowPresentation) -> some View {
        HStack(alignment: .center, spacing: Theme.rowSpacing) {
            VendorAvatarView(
                vendorId: snapshot.vendorId,
                status: snapshot.status,
                isExhausted: p.isExhausted,
                size: Theme.rowAvatarSize
            )

            // The name, then the row's second line: the vendor's reset text for
            // an exhausted row, otherwise the plan unless a group header
            // already carries it.
            VStack(alignment: .leading, spacing: 1) {
                titleView

                if !subtitle(p).isEmpty {
                    Text(subtitle(p))
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(subtitleColor(p))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.tail)
                }
                // A money provider has no plan, but it does have the one figure
                // that matters at a glance: what is left. It takes the subtitle
                // slot rather than competing for the row's right-hand side.
                if case .currency(let balance, _, _, let code) = snapshot.metric,
                   snapshot.status.confidence == .measured {
                    // Set as a figure, not as a second title. Two 17pt bolds
                    // stacked made this the heaviest row in the popover for no
                    // reason other than that it happens to hold money.
                    Text(MoneyText.format(balance, code: code))
                        .font(Theme.Typography.numeric)
                        .tracking(Theme.Tracking.numeric)
                        .foregroundStyle(snapshot.status.urgency == .none
                                         ? Theme.healthy : Theme.error)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(width: Theme.nameColumnWidth, alignment: .leading)

            if let sole = grid.soleColumn {
                // One meter takes the whole grid, rather than a single bar in
                // a third of the row with a dash either side (GitHub Copilot's
                // monthly, OpenAI's weekly). `soleColumn` decides when; the
                // bar's own track fills whatever width the cell is given.
                gridCell(sole, grid: grid)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if grid.usesGrid {
                HStack(alignment: .center, spacing: Theme.gridColumnSpacing) {
                    ForEach(WindowColumn.allCases) { column in
                        gridCell(column, grid: grid)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                // Subscription & count fallback layout (no progress bar unless a genuine denominator exists)
                Spacer()

                if let fraction = p.fraction, !typeSize.isAccessibilitySize {
                    MicroProgressBar(fraction: 1.0 - fraction, statusColor: urgencyColor(p))
                        .frame(width: barWidth)
                }

                // A money row's trend, in the free space beside its figure. The
                // strip only answers "which way is this moving" — the exact
                // figure is already on the row, in the name column's subtitle
                // and in the chip below, so the strip itself is speakable
                // nothing and carries no label.
                if let trend = BalanceSparklinePresentation.make(from: balancePoints) {
                    BalanceSparklineView(presentation: trend)
                        .padding(.trailing, 2)
                }

                Text(p.valueLabel)
                    .font(Theme.Typography.chip)
                    .foregroundStyle(p.isMeasured ? urgencyColor(p) : Theme.outline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surfaceContainerHighest.opacity(0.50))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    /// One window's cell: the bar with its pace carets, and the share used
    /// beneath it in the bar's state colour. A column the vendor does not
    /// publish stays empty — never a 0% bar.
    @ViewBuilder
    private func gridCell(_ column: WindowColumn, grid: WindowGridPresentation) -> some View {
        if let bar = grid.bars[column] {
            VStack(spacing: 4) {
                DualBarProgressView(metrics: bar, showsLabel: false)
                // The share used on the left, in the bar's colour; the time to
                // reset on the right, high-contrast. Together they answer "how much,
                // and until when" without opening the row.
                HStack(spacing: 2) {
                    // Blocked yet measured: a shape, since the vendor's
                    // blocked colour is too close to amber to carry it.
                    if WindowGridPresentation.showsBlockedGlyph(for: bar) {
                        BlockedGlyph(color: DualBarProgressView.stateColor(for: bar), size: 8)
                    }
                    Text(WindowGridPresentation.percentText(for: bar)
                         ?? WindowGridPresentation.unmeasuredText(for: bar))
                        .font(Theme.Typography.gridPercent)
                        .foregroundStyle(DualBarProgressView.stateColor(for: bar))
                    Spacer(minLength: 0)
                    if let reset = grid.compactReset(for: column) {
                        Text(reset)
                            .font(Theme.Typography.gridReset)
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.78))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
        } else {
            // A window this vendor does not publish: a faint dash keeps the
            // columns aligned. Not a track, which would read as 0% used.
            Text("–")
                .font(Theme.Typography.token)
                .foregroundStyle(Theme.outline.opacity(0.35))
                .frame(maxWidth: .infinity)
        }
    }

    /// A pool that is not a window — Kiro's bonus or overage credits, Grok's
    /// on-demand budget — on its own line under the grid, with its own token.
    private func extraRow(_ bar: DualBarMetrics) -> some View {
        HStack(spacing: Theme.rowSpacing) {
            Color.clear.frame(width: Theme.gridLeadingInset, height: 1)
            DualBarProgressView(metrics: bar)
        }
    }
}

/// The recent-pace forecast as a floating chip, shown while a row is
/// hovered. The hourglass is the non-colour channel; the row's accessibility
/// label carries the same text whether or not the row is hovered.
struct PaceForecastBubble: View {
    let text: String
    let isUrgent: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isUrgent ? "hourglass.bottomhalf.filled" : "hourglass")
            Text(text)
                .lineLimit(1)
        }
        .font(Theme.Typography.subtitle)
        .foregroundStyle(isUrgent ? Theme.tertiary : Theme.onSurface)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Theme.surfaceContainerHighest)
                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
        )
        .overlay(Capsule().stroke(Theme.outlineVariant.opacity(0.6), lineWidth: 0.5))
        .fixedSize()
    }
}
