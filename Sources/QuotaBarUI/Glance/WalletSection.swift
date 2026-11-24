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

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceContainerHighest).frame(height: height)
                if let used = window.used, used > 0 {
                    Capsule().fill(GlanceColors.fill(for: window))
                        .frame(width: max(height, proxy.size.width * used), height: height)
                }
                if let pace = window.bar.paceMarker {
                    Rectangle().fill(Theme.onSurface)
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: proxy.size.width * pace - 0.75)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

enum GlanceColors {
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
                    Capsule()
                        .fill(Theme.errorBold.opacity(0.6))
                        .overlay(ExhaustionStripes().fill(Theme.errorBold).clipShape(Capsule()))
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
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceContainerHighest)
                        Capsule().fill(Theme.primary)
                            .frame(width: max(0, proxy.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: trackHeight)
                caption("MO \(Int((fraction * 100).rounded()))%", reset: countdown, color: Theme.primary)
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
        .accessibilityLabel(row.spoken.isEmpty ? row.title : row.spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Open usage details")
        .help(row.spoken.isEmpty ? [row.title, row.figure].compactMap { $0 }.joined(separator: " · ") : row.spoken)
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
                    title.fixedSize()
                    if let tag = row.tag { tagCapsule { Text(tag.uppercased()) } }
                }
                HStack(spacing: 6) {
                    title
                    if let tag = row.tag { tagCapsule { Image(systemName: Self.glyph(for: tag)) } }
                }
            }
        }
    }

    private var title: some View {
        Text(row.title)
            .font(.system(size: 12))
            .foregroundStyle(Theme.onSurface)
            .lineLimit(1)
            .truncationMode(.middle)
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
        case .exhausted: Theme.errorBold
        case .unknown: Theme.outline
        }
    }
}
