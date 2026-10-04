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

    @ScaledMetric(relativeTo: .caption) private var barWidth: CGFloat = 84
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isHovered = false

    private var p: MetricRowPresentation { MetricRowPresentation(snapshot: snapshot) }

    private var urgencyColor: Color {
        switch p.urgency {
        case .none:     Theme.secondary
        case .warning:  Theme.tertiary
        case .critical: Theme.error
        }
    }

    /// The second line of the name column. An exhausted provider spends it on
    /// the vendor's own reset text — the plan name is the least useful thing to
    /// print about a quota you cannot currently use. Falls back to the plan
    /// when the vendor published no reset rather than inventing one.
    private var subtitle: String {
        if p.isExhausted, let reset = p.exhaustedResetText, !reset.isEmpty {
            return reset
        }
        return snapshot.shortPlanName
    }

    private var subtitleColor: Color {
        p.isExhausted ? Theme.error : Theme.onSurfaceVariant.opacity(0.85)
    }

    /// OpenRouter's own catalog badges (free-tier + cheap large-context
    /// model). Reached through the row's own leading column rather than
    /// either of the three layout branches below (bars / spend windows /
    /// no-reading chip fallback) so the badges render identically whichever
    /// of those a given snapshot lands in — including the chip-fallback
    /// branch a no-key OpenRouter reading always takes.
    private var hasOpenRouterBadges: Bool {
        snapshot.vendorId == .openrouter &&
        (snapshot.freeTierModelBadge != nil || snapshot.cheapestLargeContextModelBadge != nil)
    }

    /// A catalog failure surfaces a muted placeholder instead of silently
    /// omitting the badge row. Deliberately gated on *no badges being present*:
    /// `openRouterCatalogUnavailable` means "the catalog could not be read at
    /// all this poll", so if badges did come through the failure is moot and
    /// the real badges win. Distinct from a genuine zero-match (`failed ==
    /// false`, no badges), which is a real "nothing qualified" answer and
    /// draws nothing.
    private var showOpenRouterCatalogPlaceholder: Bool {
        snapshot.vendorId == .openrouter &&
        snapshot.openRouterCatalogUnavailable == true &&
        !hasOpenRouterBadges
    }

    var body: some View {
        // The windows actually drawn, placed in their columns. The
        // exhausted-window collapse lives on the model
        // (`QuotaSnapshot.displayBars`) so the popover and the inspector agree
        // on which windows a spent longer period makes redundant; a collapsed
        // window leaves its cell empty.
        //
        // Built once per render, and it carries the instant: every countdown
        // the row draws or speaks reads `grid.now`, never its own clock.
        let grid = WindowGridPresentation(snapshot: snapshot)
        let label = combinedAccessibilityLabel(grid: grid)
        VStack(alignment: .leading, spacing: 4) {
            row(grid)
            ForEach(Array(grid.extras.enumerated()), id: \.offset) { _, bar in
                extraRow(bar)
            }
            if hasOpenRouterBadges {
                openRouterBadgesRow
            } else if showOpenRouterCatalogPlaceholder {
                openRouterCatalogPlaceholderRow
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: Theme.rowMinHeight)
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
        .zIndex(isHovered ? 1 : 0)
        .onTapGesture {
            onSelect?(snapshot)
        }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// The row collapses into a single accessibility element via
    /// `.accessibilityElement(children: .ignore)` above, which means any
    /// `.accessibilityLabel` set on a child (the badge pills below) is never
    /// reached by VoiceOver — only this one label is announced. The badges'
    /// descriptions are folded in here rather than left on the pills, where
    /// they would silently be discarded (AGENTS.md, WCAG 1.4.1: colour/pill
    /// styling alone is not an accessible status channel).
    private func combinedAccessibilityLabel(grid: WindowGridPresentation) -> String {
        // Every countdown in the label, including the headline's own, is
        // measured from the grid's instant: the same one the cells draw.
        let presentation = MetricRowPresentation(snapshot: snapshot, now: grid.now)
        let windows = grid.spokenSummary()
        // With the grid speaking each window, the headline percentage would
        // be the same figure twice.
        var parts = [windows == nil ? presentation.accessibilityLabel : presentation.accessibilityLabelOmittingPercentage]
        if let windows {
            parts.append(windows)
        }
        if let forecastText = forecastText(now: grid.now) {
            parts.append(forecastText)
        }
        if let free = snapshot.freeTierModelBadge {
            parts.append("Free tier model: \(free)")
        }
        if let cheap = snapshot.cheapestLargeContextModelBadge {
            parts.append("Cheapest model with 1 million or more context: \(cheap)")
        }
        if showOpenRouterCatalogPlaceholder {
            // Mirror how the badges are folded in: the placeholder is not a
            // pill with its own reachable label, so it must be spoken here.
            parts.append(catalogUnavailableText)
        }
        return parts.joined(separator: ". ")
    }

    /// Only for a provider we are currently reading: a forecast under an
    /// unavailable row would describe usage we can no longer see.
    private func forecastText(now: Date) -> String? {
        guard snapshot.status.confidence == .measured else { return nil }
        return forecast?.summary(now: now)
    }

    /// How far the hover bubble sits past the row edge: it overlaps the row
    /// by a few points so it reads as belonging to it.
    private static let bubbleOffset: CGFloat = 16

    private func forecastBubble(_ text: String) -> some View {
        PaceForecastBubble(text: text, isUrgent: forecastIsUrgent)
    }

    /// Limit projected inside the reset window at the recent pace.
    private var forecastIsUrgent: Bool {
        if case .limitAt = forecast?.outcome { return true }
        return false
    }

    /// One badge per line, each free to use the full card width.
    ///
    /// Side by side they got half the row each and truncated mid-model-name
    /// ("Google: Lyria…", "DeepSeek: D…"), which is the half that carries the
    /// information. A second line costs less than a name nobody can read.
    ///
    /// The pills themselves carry no accessibility label: the parent row
    /// ignores child accessibility elements entirely, so any label set here
    /// would be silently discarded. `combinedAccessibilityLabel` above is
    /// where the badge text actually reaches VoiceOver.
    private var openRouterBadgesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let free = snapshot.freeTierModelBadge {
                HStack(spacing: 0) {
                    BadgePillView(text: free)
                    Spacer(minLength: 0)
                }
            }
            if let cheap = snapshot.cheapestLargeContextModelBadge {
                HStack(spacing: 0) {
                    BadgePillView(text: cheap, tint: Theme.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Muted placeholder shown when OpenRouter's catalog could not be read at
    /// all this poll. Deliberately a faint text line, not a filled pill: a
    /// real badge would read as a real model ranking, and this is the honest
    /// absence of one. Copy frames it as transient/harmless (it's a
    /// supplementary nicety, not the whole row failing) and the face is the
    /// subtitle — the same tier of secondary text as the plan/reset line, not
    /// the monospaced two-character token face. Spoken via
    /// `combinedAccessibilityLabel`, never a colour-only channel (WCAG 1.4.1).
    private var openRouterCatalogPlaceholderRow: some View {
        HStack(spacing: 0) {
            Text(catalogUnavailableText)
                .font(Theme.Typography.subtitle)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// The spoken and visible wording for a catalog that could not be read.
    private var catalogUnavailableText: String {
        "Model info unavailable — will retry"
    }

    private func row(_ grid: WindowGridPresentation) -> some View {
        HStack(alignment: .center, spacing: Theme.rowSpacing) {
            VendorAvatarView(
                vendorId: snapshot.vendorId,
                status: snapshot.status,
                isExhausted: p.isExhausted,
                size: Theme.rowAvatarSize
            )

            // Two lines: vendor, then the plan the provider actually reported.
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.shortVendorName)
                    .font(Theme.Typography.title)
                    .tracking(Theme.Tracking.title)
                    .foregroundStyle(Theme.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typography.subtitle)
                        .foregroundStyle(subtitleColor)
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
                    Text(formatCurrency(balance, code: code))
                        .font(Theme.Typography.numeric)
                        .tracking(Theme.Tracking.numeric)
                        .foregroundStyle(snapshot.status.urgency == .none
                                         ? Theme.healthy : Theme.error)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(width: Theme.nameColumnWidth, alignment: .leading)

            if grid.usesGrid {
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
                    MicroProgressBar(fraction: 1.0 - fraction, statusColor: urgencyColor)
                        .frame(width: barWidth)
                }

                Text(p.valueLabel)
                    .font(Theme.Typography.chip)
                    .foregroundStyle(p.isMeasured ? (p.fraction != nil ? urgencyColor : Theme.secondary) : Theme.outline)
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
            VStack(spacing: 3) {
                DualBarProgressView(metrics: bar, showsLabel: false)
                // The share used on the left, in the bar's colour; the time to
                // reset on the right, dim. Together they answer "how much, and
                // until when" without opening the row.
                HStack(spacing: 2) {
                    // Blocked yet measured: a shape, since the vendor's
                    // blocked colour is too close to amber to carry it.
                    if WindowGridPresentation.showsBlockedGlyph(for: bar) {
                        BlockedGlyph(color: DualBarProgressView.stateColor(for: bar), size: 8)
                    }
                    Text(WindowGridPresentation.percentText(for: bar)
                         ?? WindowGridPresentation.unmeasuredText(for: bar))
                        .font(Theme.Typography.token)
                        .tracking(Theme.Tracking.token)
                        .foregroundStyle(DualBarProgressView.stateColor(for: bar))
                    Spacer(minLength: 0)
                    if let reset = grid.compactReset(for: column) {
                        Text(reset)
                            .font(.system(size: 10, weight: .regular).monospaced())
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.6))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        } else if let spend = grid.spend[column] {
            // Spend per window. Deliberately not a bar: spend has no cap to
            // measure against, so drawing one would invent a denominator.
            Text(spend.amount.map { formatCurrency($0, code: spend.currencyCode) } ?? "—")
                .font(Theme.Typography.chip)
                .foregroundStyle(Theme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

    private func formatCurrency(_ value: Decimal, code: String) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        if code == "AUD" {
            return String(format: "A$%.2f", d)
        } else if code == "USD" {
            return String(format: "$%.2f", d)
        } else {
            return String(format: "%.2f %@", d, code)
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
