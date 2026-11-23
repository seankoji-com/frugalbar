import SwiftUI
import QuotaBarCore

/// The redesigned popover body: Use now, Back soon, Services, Wallet.
///
/// Layout is design A2 ("Grouped Sections") with B1-F2's hero card for the
/// first pick, chosen on 23 Nov 2026. Every figure is read from
/// `GlancePresentation`, which holds the rules; these views only draw.
struct GlanceSectionsView: View {
    let glance: GlancePresentation
    /// Wallet credit rows, read from the same snapshots so the Wallet speaks
    /// the existing presentations' figures and labels.
    var onSelect: ((QuotaSnapshot) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            UseNowSection(glance: glance, onSelect: onSelect)
            if !glance.backSoon.isEmpty {
                BackSoonSection(glance: glance, onSelect: onSelect)
            }
            if !glance.services.isEmpty || !glance.foldedServices.isEmpty {
                ServicesSection(glance: glance, onSelect: onSelect)
            }
            let wallet = WalletPresentation(snapshots: glance.walletSnapshots, now: glance.now)
            if !wallet.rows.isEmpty {
                WalletSection(presentation: wallet)
            }
        }
    }
}

// MARK: - Shared pieces

/// "Use now" ... "3 of 7 usable · by headroom at risk".
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
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.outlineVariant.opacity(0.35), lineWidth: 0.5))
    }
}

/// A "% left" meter. The fill is what remains; the tick, when the vendor
/// published the window's reset and length, is where an even pace would
/// leave it (`1 − paceMarker`). Nothing is drawn for a figure not received.
struct RemainingBar: View {
    let window: GlancePresentation.Window
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceContainerHighest).frame(height: height)
                if let remaining = window.remaining {
                    Capsule().fill(GlanceColors.fill(for: window))
                        .frame(width: max(0, proxy.size.width * remaining), height: height)
                }
                if let pace = window.bar.paceMarker {
                    Rectangle().fill(Theme.onSurface)
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: proxy.size.width * (1 - pace) - 0.75)
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

private struct AheadOfPaceCaption: View {
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7))
            Text(compact ? "ahead" : "ahead of pace")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Theme.tertiary)
    }
}

private extension GlancePresentation.Pool {
    var avatarStatus: ProviderStatus { snapshot.status }
}

// MARK: - Use now

private struct UseNowSection: View {
    let glance: GlancePresentation
    let onSelect: ((QuotaSnapshot) -> Void)?

    private var meta: String? {
        let usable = glance.services.flatMap(\.pools).filter { $0.state == .usable && !$0.isStale }.count
        guard !glance.ranking.isEmpty else { return nil }
        if glance.ranking.first?.isCaveat == true { return "best available · nothing above 20%" }
        return "\(min(glance.strip.count, usable)) of \(usable) usable · by headroom at risk"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlanceSectionHeader(title: "Use now", meta: meta)
            GlanceCard {
                if let first = glance.strip.first {
                    HeroPickView(pick: first, now: glance.now, onSelect: onSelect)
                    ForEach(Array(glance.strip.dropFirst().enumerated()), id: \.element.pool.id) { index, pick in
                        Divider().overlay(Theme.outlineVariant.opacity(0.4))
                        CompactPickRow(rank: index + 2, pick: pick, onSelect: onSelect)
                    }
                } else {
                    NoPickView(title: glance.menuTitle)
                }
            }
        }
    }
}

/// B1-F2: the first pick as a gauge you read in half a second.
private struct HeroPickView: View {
    let pick: GlancePresentation.Pick
    let now: Date
    let onSelect: ((QuotaSnapshot) -> Void)?

    /// "89% of the monthly allowance left · resets in 29d".
    func heroCaption(reset: Date?) -> String {
        if pick.isCaveat { return pick.reason }
        let percent = GlancePresentation.percent(pick.binding.remaining ?? 0)
        let window = WindowColumn.column(forLabel: pick.binding.bar.label)?.spokenName ?? pick.binding.bar.label
        let resetText = reset.map { "resets in \(GlancePresentation.countdown($0, now: now))" } ?? "reset not published"
        return "\(percent)% of the \(window) allowance left · \(resetText)"
    }

    private var tint: Color { pick.isCaveat ? Theme.tertiary : Theme.healthy }

    var body: some View {
        let percent = GlancePresentation.percent(pick.binding.remaining ?? 0)
        let reset = pick.binding.bar.resetsAt
        Button { onSelect?(pick.pool.snapshot) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Text("01")
                        .font(Theme.Typography.token)
                        .foregroundStyle(tint)
                    VendorAvatarView(vendorId: pick.pool.snapshot.vendorId, status: pick.pool.avatarStatus, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pick.pool.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.onSurface)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(pick.pool.service)
                            if pick.pool.isAheadOfPace { AheadOfPaceCaption(compact: true) }
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.onSurfaceVariant)
                    }
                    Spacer(minLength: 6)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(percent)")
                            .font(.system(size: 40, weight: .bold).monospacedDigit())
                        Text("%").font(.system(size: 18, weight: .bold))
                    }
                    .foregroundStyle(tint)
                }
                // One sentence, one countdown: what the big figure is a share
                // of, and when it resets. A second, differently formatted
                // countdown on the right read as a different reset.
                Text(heroCaption(reset: reset))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.onSurfaceVariant)
                RemainingBar(window: pick.binding, height: 6)
            }
            .padding(14)
            .background(tint.opacity(0.07))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Use now, first choice: \(pick.pool.service) \(pick.pool.name). \(heroCaption(reset: reset))"
            + (pick.pool.isAheadOfPace ? ". Ahead of pace" : "")
            + (pick.isCaveat ? ". Best available, not a strong pick" : ""))
        .accessibilityHint("Open usage details")
    }
}

private struct CompactPickRow: View {
    let rank: Int
    let pick: GlancePresentation.Pick
    let onSelect: ((QuotaSnapshot) -> Void)?

    var body: some View {
        Button { onSelect?(pick.pool.snapshot) } label: {
            HStack(spacing: 10) {
                Text("\(rank)")
                    .font(Theme.Typography.gridPercent)
                    .foregroundStyle(Theme.outline)
                    .frame(width: 14)
                VendorAvatarView(vendorId: pick.pool.snapshot.vendorId, status: pick.pool.avatarStatus, size: 22)
                // The reason never truncates; the service name gives way first.
                HStack(spacing: 5) {
                    Text(pick.pool.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onSurface)
                        .layoutPriority(1)
                    Text(pick.pool.service).font(.system(size: 11.5)).foregroundStyle(Theme.outline)
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                if pick.pool.isAheadOfPace { AheadOfPaceCaption(compact: true) }
                Text(pick.reason)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Use now, choice \(rank): \(pick.pool.service) \(pick.pool.name). \(pick.reason)"
            + (pick.pool.isAheadOfPace ? ". Ahead of pace" : ""))
        .accessibilityHint("Open usage details")
    }
}

private struct NoPickView: View {
    let title: GlancePresentation.MenuTitle
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: title.tone == .critical ? "nosign" : "questionmark.circle")
                .foregroundStyle(title.tone == .critical ? Theme.errorBold : Theme.outline)
            Text(title.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(title.tone == .critical ? Theme.errorBold : Theme.onSurfaceVariant)
            Spacer()
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Back soon

private struct BackSoonSection: View {
    let glance: GlancePresentation
    let onSelect: ((QuotaSnapshot) -> Void)?

    private var meta: String {
        let count = glance.backSoon.count
        let next = glance.backSoon.first.map { $0.pool.returnsAt != nil ? " · next in \($0.returnText)" : "" } ?? ""
        return "\(count) spent or blocked\(next)"
    }

    var body: some View {
        // Column-major: soonest first down the left column, then the right.
        let entries = glance.backSoon
        let split = (entries.count + 1) / 2
        let left = Array(entries.prefix(split)), right = Array(entries.dropFirst(split))
        VStack(alignment: .leading, spacing: 6) {
            GlanceSectionHeader(title: "Back soon", meta: meta)
            GlanceCard {
                HStack(alignment: .top, spacing: 0) {
                    column(left)
                    if !right.isEmpty {
                        // A sized rule, not `Divider`: a vertical Divider takes
                        // every point offered and left a band under the card.
                        Rectangle().fill(Theme.outlineVariant.opacity(0.4)).frame(width: 0.5)
                        column(right)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
            }
        }
    }

    private func column(_ entries: [GlancePresentation.ReturnEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries, id: \.pool.id) { entry in
                BackSoonRow(entry: entry, onSelect: onSelect)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BackSoonRow: View {
    let entry: GlancePresentation.ReturnEntry
    let onSelect: ((QuotaSnapshot) -> Void)?

    var body: some View {
        let published = entry.pool.returnsAt != nil && !entry.returnText.hasPrefix("Reset passed")
        Button { onSelect?(entry.pool.snapshot) } label: {
            HStack(spacing: 5) {
                // Red, and in the Back soon section: being here is the
                // non-colour statement that the pool is spent or blocked.
                Text(published ? entry.returnText : "—")
                    .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.errorBold)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 30, alignment: .trailing)
                VendorAvatarView(vendorId: entry.pool.snapshot.vendorId, status: entry.pool.snapshot.status, size: 14)
                Text(entry.pool.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.onSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                // Blocked says so in words (spent and blocked share the red
                // and the glyph); a spent window names its token.
                Text(entry.isBlocked ? "blocked" : (entry.windowLabel ?? ""))
                    .font(Theme.Typography.token)
                    .foregroundStyle(Theme.outline)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.returnText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(published: published))
    }

    private func spoken(published: Bool) -> String {
        var parts = ["\(entry.pool.service) \(entry.pool.name), \(entry.isBlocked ? "blocked" : "spent")"]
        if let label = entry.windowLabel { parts[0] += " on \(label)" }
        parts.append(published ? "back in \(entry.returnText)" : entry.returnText)
        if entry.pool.isStale { parts.append("figures from an earlier poll") }
        if entry.pool.hasPaidOverage { parts.append("paid overage available") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Services

private struct ServicesSection: View {
    let glance: GlancePresentation
    let onSelect: ((QuotaSnapshot) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlanceSectionHeader(title: "Services", meta: "bar = % left · tick = even pace")
            GlanceCard {
                // One shared column header, so each block's own header row can
                // carry its counts in full.
                HStack(spacing: 0) {
                    Spacer().frame(width: ServiceBlockView.nameWidth + 24)
                    ForEach(WindowColumn.allCases) { column in
                        Text(column.label)
                            .font(Theme.Typography.token)
                            .foregroundStyle(Theme.outline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .accessibilityHidden(true)
                ForEach(Array(glance.services.enumerated()), id: \.element.id) { index, block in
                    if index > 0 { Divider().overlay(Theme.outlineVariant.opacity(0.4)) }
                    ServiceBlockView(block: block, now: glance.now, onSelect: onSelect)
                }
                if !glance.foldedServices.isEmpty {
                    if !glance.services.isEmpty { Divider().overlay(Theme.outlineVariant.opacity(0.4)) }
                    Text("\(ListFormatter.localizedString(byJoining: glance.foldedServices)): nothing usable (see Back soon)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.errorBold)
                        .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct ServiceBlockView: View {
    let block: GlancePresentation.ServiceBlock
    let now: Date
    let onSelect: ((QuotaSnapshot) -> Void)?

    static let nameWidth: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(block.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.onSurface)
                Text(usableText).font(.system(size: 10.5)).foregroundStyle(Theme.outline)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(block.pools) { pool in
                ServicePoolRow(pool: pool, now: now, onSelect: onSelect)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var usableText: String {
        let usable = block.pools.filter { $0.state == .usable }.count
        return block.spentCount > 0 ? "\(usable) usable · \(block.spentCount) back soon" : "\(usable) usable"
    }
}

private struct ServicePoolRow: View {
    let pool: GlancePresentation.Pool
    let now: Date
    let onSelect: ((QuotaSnapshot) -> Void)?

    private var columns: [WindowColumn: GlancePresentation.Window] {
        var map: [WindowColumn: GlancePresentation.Window] = [:]
        for window in pool.windows {
            if let column = WindowColumn.column(forLabel: window.bar.label), map[column] == nil { map[column] = window }
        }
        return map
    }

    /// Plan windows with no grid column ("1D", "PLAN"): named in the caption.
    private var others: [GlancePresentation.Window] {
        pool.windows.filter { WindowColumn.column(forLabel: $0.bar.label) == nil }
    }

    var body: some View {
        Button { onSelect?(pool.snapshot) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 0) {
                    HStack(alignment: .top, spacing: 6) {
                        VendorAvatarView(vendorId: pool.snapshot.vendorId, status: pool.snapshot.status, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pool.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.onSurface)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            caption
                        }
                    }
                    .frame(width: ServiceBlockView.nameWidth + 24, alignment: .leading)
                    if pool.state == .unreadable {
                        Text(pool.snapshot.status.unavailableReason?.headline ?? "No reading")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.outline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(WindowColumn.allCases) { column in
                            cell(columns[column])
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, 6)
                        }
                    }
                }
                scopedCaptions
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Open usage details")
    }

    @ViewBuilder private var caption: some View {
        if pool.isStale, let stale = pool.snapshot.staleReading {
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.system(size: 8))
                Text("figures from \(MetricDetailPresentation.clockText(pool.snapshot.lastUpdated, now: now))")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .help("Last poll failed: \(stale.reason.headline)")
        } else if pool.state == .onBonus {
            Text("plan spent · on bonus").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
        } else if pool.isAheadOfPace {
            AheadOfPaceCaption()
        } else if !others.isEmpty {
            Text(others.map { "\($0.bar.label) \(GlancePresentation.percent($0.remaining ?? 0))% left" }.joined(separator: " · "))
                .font(.system(size: 10.5)).foregroundStyle(Theme.outline)
        }
    }

    /// Model-scoped windows (Fable) as an indented caption: never a pick, never a gate.
    @ViewBuilder private var scopedCaptions: some View {
        ForEach(Array(pool.snapshot.scopedBars.enumerated()), id: \.offset) { _, bar in
            if let used = bar.primaryFraction {
                Text("└ \(bar.label) · model cap · WK \(Int((used * 100).rounded()))% used")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.outline)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder private func cell(_ window: GlancePresentation.Window?) -> some View {
        if let window {
            VStack(alignment: .leading, spacing: 2) {
                RemainingBar(window: window)
                HStack(spacing: 3) {
                    if window.isSpent {
                        Image(systemName: "nosign").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.errorBold)
                    } else if let remaining = window.remaining {
                        Text("\(GlancePresentation.percent(remaining))%")
                            .font(Theme.Typography.gridPercent)
                            .foregroundStyle(GlanceColors.text(for: window))
                    } else {
                        Text(window.bar.isBlocked ? "Blocked" : "—")
                            .font(Theme.Typography.gridReset).foregroundStyle(Theme.outline)
                    }
                    Spacer(minLength: 0)
                    if let reset = window.bar.resetsAt {
                        Text(GlancePresentation.countdown(reset, now: now))
                            .font(Theme.Typography.gridReset)
                            .foregroundStyle(Theme.outline)
                    }
                }
            }
        } else {
            // Not published: a faint dash, never a track that reads as 0%.
            Text("—").font(Theme.Typography.gridReset).foregroundStyle(Theme.outlineVariant)
        }
    }

    private var spoken: String {
        var parts = ["\(pool.service) \(pool.name)"]
        switch pool.state {
        case .unreadable: parts.append(pool.snapshot.status.unavailableReason?.headline ?? "no reading")
        case .onBonus: parts.append("plan spent, on bonus allowance")
        default: break
        }
        for window in pool.windows {
            guard let remaining = window.remaining else { continue }
            var text = "\(window.bar.label) \(GlancePresentation.percent(remaining)) percent left"
            if let reset = window.bar.resetsAt {
                text += ", resets in \(GlancePresentation.countdownSpoken(reset, now: now))"
            }
            if window.isAheadOfPace { text += ", ahead of pace" }
            parts.append(text)
        }
        if pool.isStale { parts.append("figures from an earlier poll") }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Wallet

/// Every credit and balance, one line each (`WalletPresentation`). The row's
/// own title names its provider, so there are no group headers.
struct WalletSection: View {
    let presentation: WalletPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlanceSectionHeader(title: "Wallet", meta: "credits and balances · never in rankings")
            GlanceCard {
                ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().overlay(Theme.outlineVariant.opacity(0.3)) }
                    WalletRowView(row: row)
                }
            }
        }
    }
}

private struct WalletRowView: View {
    let row: WalletPresentation.Row

    var body: some View {
        HStack(spacing: 8) {
            VendorAvatarView(vendorId: row.vendor, status: .measured(.none), size: 16)
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.78, blue: 0.29))
            }
            Text(row.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.onSurface)
                .lineLimit(1)
                .layoutPriority(1)
            if let context = row.context {
                Text(context)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.outline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if let figure = row.figure {
                Text(figure)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color(row.tone))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken.isEmpty ? row.title : row.spoken)
        .help([row.title, row.context, row.figure].compactMap { $0 }.joined(separator: " · "))
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
