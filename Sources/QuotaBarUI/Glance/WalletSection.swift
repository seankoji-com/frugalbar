import SwiftUI
import QuotaBarCore

// MARK: - Shared pieces

/// A popover section's title, and optionally a quiet right-hand note. Neither
/// the Subscriptions footer legend nor the Wallet note is drawn any more
/// (owner, 26 Nov 2026): the dots, bars and ticks explain themselves, and the
/// row's spoken label still says what each one means.
struct GlanceSectionHeader: View {
    let title: String
    var meta: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let meta {
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.outline)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct GlanceCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Theme.cardRimTop, Theme.outlineVariant.opacity(0.28)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
    }
}

/// A "% used" meter (owner, 24 Nov 2026): empty when nothing is used, full
/// when the window is spent. The tick, when the vendor published the window's
/// reset and length, is where an even pace would have used it (`paceMarker`).
/// Nothing is drawn for a figure not received.
struct UsageBar: View {
    let window: GlancePresentation.Window
    var height: CGFloat = 4
    /// A carried-over reading: the track and fill recede, the pace tick does
    /// not. Dimming the whole bar took the tick to 1.4:1 on the fill.
    var dimmed: Bool = false
    /// Overrides the state fill. The Wallet draws every meter in the
    /// informational colour (owner, 26 Nov 2026), so its four lines share one
    /// anatomy instead of reading green, amber and coral in a column.
    var fill: Color? = nil
    static let knockoutWidth: CGFloat = 3.5
    static let dimmedOpacity = 0.55

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceContainerHighest).frame(height: height)
                    if let used = window.used, used > 0 {
                        Capsule().fill(fill ?? GlanceColors.fill(for: window))
                            .frame(width: max(height, proxy.size.width * used), height: height)
                    }
                }
                .opacity(dimmed ? Self.dimmedOpacity : 1)
                // The track's extent is capacity, drawn even at 0% used: a
                // hairline edge in `trackEdge` gives it 3:1 against the row
                // (the dark fill alone measured 1.38:1), and stays at full
                // strength when a carried-over bar is dimmed.
                Capsule().strokeBorder(GlanceColors.trackEdge, lineWidth: 0.75).frame(height: height)
                // A light core in a dark knockout: over the track the core
                // carries the contrast, over the fill the knockout does. The
                // light line alone measured 1.3:1 on the green and amber fills,
                // so the mark vanished exactly once usage had passed it.
                if let pace = window.bar.paceMarker {
                    ZStack {
                        Rectangle().fill(Theme.surface).frame(width: Self.knockoutWidth, height: height + 4)
                        Rectangle().fill(Theme.onSurface).frame(width: 1.5, height: height + 4)
                    }
                    .offset(x: proxy.size.width * pace - Self.knockoutWidth / 2)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A spent or blocked window's track: errorBold stripes on a dark errorBold
/// wash. The stripes are the state's pattern, so they must stand off their own
/// base: on a 60% wash they measured 1.8:1; on this 22% wash they clear 3:1,
/// and the stripes against the row clear it too, so the bar keeps its shape.
struct SpentTrack: View {
    static let baseOpacity = 0.22

    var body: some View {
        Capsule()
            .fill(Theme.errorBold.opacity(Self.baseOpacity))
            .overlay(ExhaustionStripes().fill(Theme.errorBold).clipShape(Capsule()))
    }
}

enum GlanceColors {
    /// A usage track's hairline edge: `Theme.outline` at this opacity clears
    /// 3:1 against the row and the hovered row.
    static let trackEdgeOpacity = 0.8
    static var trackEdge: Color { Theme.outline.opacity(trackEdgeOpacity) }

    /// Spent is the one red; ahead of pace or under 30% left is amber; low but
    /// not spent is the pale coral; otherwise healthy green.
    static func fill(for window: GlancePresentation.Window) -> Color {
        if window.isSpent { return Theme.errorBold }
        guard let remaining = window.remaining else { return Theme.outline }
        if remaining < 0.10 { return Theme.error }
        if window.isAheadOfPace || remaining < 0.30 { return Theme.tertiary }
        return Theme.healthy
    }

    static func text(for window: GlancePresentation.Window) -> Color {
        window.isAheadOfPace ? Theme.tertiary : Theme.onSurface
    }
}

// MARK: - Wallet

/// Every credit and balance, one line each (`WalletPresentation`). The row's
/// own title names its provider, so there are no group headers.
struct WalletSection: View {
    let presentation: WalletPresentation
    /// Recorded balance history by `BalanceSeries.id`, for each balance's trend.
    var balanceSeries: [String: [BalancePoint]] = [:]
    /// The latest history read failed and these trends are the last good read
    /// (`QuotaStore.balanceSeriesReadFailed`); they recede and say so.
    var trendIsCarriedOver = false
    var now: Date = Date()
    /// Opens the inspector for the snapshot a line came from
    /// (`WalletPresentation.Row.snapshotID`), with the line's own balance
    /// series (`balanceSeriesID`) so the details open on its figure.
    var onSelect: (String, String?) -> Void = { _, _ in }

    @State private var figureColumnWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlanceSectionHeader(title: "Wallet")
            GlanceCard {
                VStack(spacing: 0) {
                    ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(Theme.outlineVariant.opacity(0.28)) }
                        WalletRowView(
                            row: row,
                            trend: row.balanceSeriesID.flatMap {
                                BalanceSparklinePresentation.make(from: balanceSeries[$0] ?? [])
                            },
                            trendIsCarriedOver: trendIsCarriedOver,
                            now: now,
                            figureColumnWidth: figureColumnWidth,
                            onSelect: { onSelect(row.snapshotID, row.balanceSeriesID) }
                        )
                    }
                }
                .onPreferenceChange(WalletFigureWidthKey.self) { width in
                    if width > 0 { figureColumnWidth = width }
                }
            }
        }
    }
}

private struct WalletFigureWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A Wallet line's meter, in the provider rows' anatomy: the bar, then one
/// caption line under it. All four kinds share that anatomy (owner, 26 Nov
/// 2026): the same informational blue, the same "MO 14%" label with no "used"
/// suffix, the same even-use tick, and the line's figure between the percentage
/// and the countdown. A credit's bar is `UsageBar`; a time-only meter is built
/// from the elapsed share of the calendar month, where even use *is* the
/// elapsed share.
///
/// The figure sits on the caption row in that caption's size: with the figure
/// column vacated the bar runs to the card's edge, so a 180pt track shows the
/// window's shape instead of an 84pt stub.
private struct WalletMeterCell: View {
    let meter: WalletPresentation.Meter
    /// The line's figure ("$200.00", "60k credits"), drawn between its used
    /// share and its countdown.
    let figure: String?
    let figureColor: Color
    let now: Date
    private let trackHeight: CGFloat = 3
    /// Every Wallet meter is informational: a credit column in green, amber and
    /// coral read as four different verdicts, and the Wallet is not a ranking.
    /// A spent credit keeps `SpentTrack` and its red label — an exhausted
    /// allowance must not render as a calm blue bar.
    private let meterColor = Theme.primary

    var body: some View {
        switch meter {
        case .credit(let bar):
            let window = GlancePresentation.window(for: bar, now: now)
            let reset = bar.resetsAt.flatMap { ResetCountdownBadge.compact($0, now: now) }
            if window.isSpent {
                VStack(alignment: .leading, spacing: 3) {
                    SpentTrack()
                        .frame(height: trackHeight)
                    caption("MO 100%", reset: reset, color: Theme.error, size: 10)
                }
            } else if let used = window.used {
                VStack(alignment: .leading, spacing: 3) {
                    UsageBar(window: window, height: trackHeight, fill: meterColor)
                    caption("MO \(GlancePresentation.usedPercentText(used))",
                            reset: reset, color: meterColor, size: 10)
                }
            }
        case .elapsed(let fraction, let countdown, let resetsAt, let windowLength):
            let elapsed = min(max(fraction, 0), 1)
            // No spend was published for a time-only meter, so it carries no
            // fill — an empty tinted track would read as "nothing used". What is
            // known is where the month is, so the track carries *only* its
            // even-use mark at that share: the same tick the credit rows draw,
            // and the one mark an elapsed month can honestly place. The reset
            // and span come from the cycle the share was measured in, because
            // `evenPace` refuses a position with nothing behind it.
            let monthly = DualBarMetrics(primaryFraction: nil, expectedPaceFraction: elapsed,
                                         label: "MO", resetsAt: resetsAt, windowLength: windowLength)
            VStack(alignment: .leading, spacing: 3) {
                UsageBar(window: GlancePresentation.window(for: monthly, now: now),
                         height: trackHeight, fill: meterColor)
                caption("MO \(Int((elapsed * 100).rounded()))%",
                        reset: countdown, color: meterColor, size: 9.5)
            }
        }
    }

    private func caption(_ label: String, reset: String?, color: Color, size: CGFloat) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "calendar")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 2)
            figureText(size: size)
            Spacer(minLength: 2)
            if let reset {
                Text(reset).foregroundStyle(Theme.outline).fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.system(size: size).monospacedDigit())
        .lineLimit(1)
    }

    /// The figure, in the caption's size, still publishing the shared figure
    /// width so the rows that keep a figure column measure against it too.
    @ViewBuilder
    private func figureText(size: CGFloat) -> some View {
        if let figure {
            Text(figure)
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(figureColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: WalletFigureWidthKey.self, value: proxy.size.width)
                    }
                )
        }
    }
}

/// A Wallet line's spoken words for its balance trend.
enum WalletRowViewSpeech {
    nonisolated static func trendPhrase(base: String, trend: BalanceSparklinePresentation,
                                        carriedOver: Bool, now: Date) -> String {
        let when = MetricDetailPresentation.clockText(trend.lastMeasuredAt, now: now)
        let kept = carriedOver ? " (kept from an earlier read; the latest history read failed)" : ""
        return "\(base), recorded balance \(trend.spokenTrend), last recorded \(when)\(kept)"
    }
}

private struct WalletRowView: View {
    let row: WalletPresentation.Row
    let trend: BalanceSparklinePresentation?
    let trendIsCarriedOver: Bool
    let now: Date
    let figureColumnWidth: CGFloat
    let onSelect: () -> Void

    @State private var isHovered = false

    /// The meter column's width, before the figure's own column is added to it
    /// on a line that has a bar. Combined with the measured shared figure
    /// column width, every line's amount still ends in the same place, and a
    /// bar line's track runs through that vacated column to the card's edge.
    /// Wide enough for "29% used" and a countdown beside it (at 76pt "used"
    /// truncated to "us…"), narrow enough that a mid-length account name
    /// ("Claude Extra usage · Ops") keeps one line (at 92pt it wrapped).
    private let meterWidth: CGFloat = 84

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                nameCell
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let meter = row.meter {
                    // The meter takes the vacated figure column and runs to the
                    // card's edge; its figure is drawn in the caption between
                    // the used share and the countdown (owner, 26 Nov 2026).
                    WalletMeterCell(meter: meter, figure: row.figure,
                                    figureColor: color(row.tone), now: now)
                        .frame(width: meterWidth + (figureColumnWidth > 0 ? 8 + figureColumnWidth : 0))
                } else if let trend {
                    // A trend kept from an earlier read recedes and wears the
                    // carried-over clock, so it is not taken for fresh evidence.
                    HStack(spacing: 3) {
                        if trendIsCarriedOver {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Theme.tertiary)
                        }
                        BalanceSparklineView(presentation: trend)
                            .opacity(trendIsCarriedOver ? 0.45 : 1)
                    }
                    .frame(width: meterWidth)
                }
                // A line with neither a meter nor a trend draws nothing in the
                // meter column, so the name takes that width instead of leaving
                // it empty: a ticket line ("Claude Fable reset ticket ·
                // Primary") was squeezed into three broken lines beside a blank
                // column (owner, 26 Nov 2026). The shared figure column is
                // measured separately, so every amount still ends together.
                // The amount alone (owner, 26 Nov 2026): the role word under it
                // ("left", "grant", "credit", "cap") was a second line of 9.5pt
                // text on every line of the Wallet, and the rows read as a
                // stack of captions. The role is still spoken and in the
                // tooltip (`row.spoken`, `spokenLabel`), so a remaining count
                // and a grant stay distinguishable without being drawn.
                if row.meter == nil {
                    Text(row.figure ?? "")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(color(row.tone))
                        .lineLimit(1)
                        .fixedSize()
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: WalletFigureWidthKey.self, value: proxy.size.width)
                            }
                        )
                        .frame(minWidth: figureColumnWidth > 0 ? figureColumnWidth : nil, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8.5)
            .background(isHovered ? Theme.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Open usage details")
        .help(spokenLabel)
    }

    /// The line's own words plus the drawn strip's direction and when it was
    /// last recorded, when a strip is drawn (a meter speaks for itself).
    private var spokenLabel: String {
        let base = row.spoken.isEmpty
            ? [row.title, [row.figure, row.figureRole].compactMap { $0 }.joined(separator: " ")]
                .joined(separator: " · ")
            : row.spoken
        guard row.meter == nil, let trend else { return base }
        return WalletRowViewSpeech.trendPhrase(base: base, trend: trend, carriedOver: trendIsCarriedOver, now: now)
    }

    private var nameCell: some View {
        HStack(spacing: 8) {
            VendorAvatarView(vendorId: row.vendor, status: .measured(.none), size: 16)
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.78, blue: 0.29))
            }
            // The tag says its word when the title fits beside it, and shrinks
            // to its glyph when it does not, so an account name is never cut
            // to make room for "CONFIGURED". The tooltip and spoken label
            // always carry the word.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    title(lineLimit: 1).fixedSize()
                    if let tag = row.tag { tagCapsule { Text(tag.uppercased()) } }
                }
                HStack(alignment: .top, spacing: 6) {
                    title(lineLimit: nil)
                    if let tag = row.tag {
                        tagCapsule { Image(systemName: Self.glyph(for: tag)) }
                            .padding(.top, 1)
                    }
                }
            }
        }
    }

    private func title(lineLimit: Int?) -> some View {
        Text(row.title)
            .font(.system(size: 12))
            .foregroundStyle(Theme.onSurface)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: lineLimit != 1)
            .layoutPriority(1)
    }

    private func tagCapsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(Theme.outline)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(Theme.outlineVariant, lineWidth: 0.75))
            .lineLimit(1)
            .fixedSize()
    }

    /// The compact form of a tag: a pencil for a figure the user typed, a
    /// clock for a carried-over reading.
    static func glyph(for tag: String) -> String {
        tag == "configured" ? "pencil" : "clock.arrow.circlepath"
    }

    private func color(_ tone: WalletPresentation.Tone) -> Color {
        switch tone {
        case .normal: Theme.onSurface
        case .negative: Theme.error
        case .exhausted: Theme.error
        case .unknown: Theme.outline
        }
    }
}
