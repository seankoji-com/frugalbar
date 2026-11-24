import SwiftUI
import QuotaBarCore

// MARK: - Shared pieces

/// A popover section's title and its quiet right-hand note:
/// "Wallet" ... "credits and balances · never in rankings".
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
    static let knockoutWidth: CGFloat = 3.5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceContainerHighest).frame(height: height)
                if let used = window.used, used > 0 {
                    Capsule().fill(GlanceColors.fill(for: window))
                        .frame(width: max(height, proxy.size.width * used), height: height)
                }
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
    /// The elapsed-month meter's outline (`Theme.primary` at this opacity).
    static let elapsedOutlineOpacity = 0.75

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
    var now: Date = Date()
    /// Opens the inspector for the snapshot a line came from
    /// (`WalletPresentation.Row.snapshotID`), as a Subscriptions row does.
    var onSelect: (String) -> Void = { _ in }

    @State private var figureColumnWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlanceSectionHeader(title: "Wallet", meta: "credits and balances · never in rankings")
            GlanceCard {
                VStack(spacing: 0) {
                    ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(Theme.outlineVariant.opacity(0.28)) }
                        WalletRowView(
                            row: row,
                            trend: row.balanceSeriesID.flatMap {
                                BalanceSparklinePresentation.make(from: balanceSeries[$0] ?? [])
                            },
                            now: now,
                            figureColumnWidth: figureColumnWidth,
                            onSelect: { onSelect(row.snapshotID) }
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

/// A Wallet line's meter, in the provider rows' anatomy: the bar, then "% used"
/// and the countdown under it. A credit's bar is `UsageBar`, so its fill,
/// colour and even-use tick follow the same rules as a quota window; a
/// time-only meter is drawn in the informational colour and says "MO 63%".
private struct WalletMeterCell: View {
    let meter: WalletPresentation.Meter
    let now: Date
    private let trackHeight: CGFloat = 3

    var body: some View {
        switch meter {
        case .credit(let bar):
            let window = GlancePresentation.window(for: bar, now: now)
            let reset = bar.resetsAt.flatMap { ResetCountdownBadge.compact($0, now: now) }
            if window.isSpent {
                VStack(alignment: .leading, spacing: 3) {
                    SpentTrack()
                        .frame(height: trackHeight)
                    caption("100%", reset: reset, color: Theme.error)
                }
            } else if let used = window.used {
                VStack(alignment: .leading, spacing: 3) {
                    UsageBar(window: window, height: trackHeight)
                    caption(GlancePresentation.usedPercentText(used),
                            reset: reset, color: GlanceColors.text(for: window))
                }
            }
        case .elapsed(let fraction, let countdown):
            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        // The outline is the remaining month's only edge, so
                        // it clears 3:1 against the row (at 35% it was 2.67:1).
                        Capsule()
                            .strokeBorder(Theme.primary.opacity(GlanceColors.elapsedOutlineOpacity), lineWidth: 0.75)
                            .background(Capsule().fill(Theme.surfaceContainerHighest.opacity(0.5)))
                        Capsule().fill(Theme.primary)
                            .frame(width: max(0, proxy.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: trackHeight)
                HStack(spacing: 2) {
                    Image(systemName: "calendar")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text("MO \(Int((fraction * 100).rounded()))%")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 1)
                    if let countdown {
                        Text(countdown)
                            .foregroundStyle(Theme.outline)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .font(.system(size: 9.5).monospacedDigit())
                .lineLimit(1)
                Text("month elapsed")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Theme.outline)
                    .lineLimit(1)
            }
        }
    }

    private func caption(_ label: String, reset: String?, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).fontWeight(.semibold).foregroundStyle(color)
            Spacer(minLength: 0)
            if let reset { Text(reset).foregroundStyle(Theme.outline) }
        }
        .font(.system(size: 10).monospacedDigit())
        .lineLimit(1)
    }
}

private struct WalletRowView: View {
    let row: WalletPresentation.Row
    let trend: BalanceSparklinePresentation?
    let now: Date
    let figureColumnWidth: CGFloat
    let onSelect: () -> Void

    @State private var isHovered = false

    /// The meter column's width. Combined with the measured shared figure
    /// column width, every line's bar starts and ends in the same place.
    private let meterWidth: CGFloat = 76

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                nameCell
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let meter = row.meter {
                    WalletMeterCell(meter: meter, now: now)
                        .frame(width: meterWidth)
                } else if let trend {
                    BalanceSparklineView(presentation: trend)
                        .frame(width: meterWidth)
                } else {
                    Color.clear.frame(width: meterWidth, height: 1)
                }
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
        .help(row.spoken.isEmpty ? [row.title, row.figure].compactMap { $0 }.joined(separator: " · ") : row.spoken)
    }

    /// The line's own words plus the drawn strip's direction, when a strip
    /// is drawn (a meter, when present, already speaks for itself).
    private var spokenLabel: String {
        let base = row.spoken.isEmpty ? row.title : row.spoken
        guard row.meter == nil, let trend else { return base }
        return "\(base), recorded balance \(trend.spokenTrend)"
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
