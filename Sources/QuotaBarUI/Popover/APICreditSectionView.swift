import SwiftUI
import QuotaBarCore

/// The prepaid API credit balances the vendors published alongside their quota:
/// OpenAI's credit count, Anthropic's monthly extra-usage credit and promo
/// credit.
///
/// One card of its own rather than rows folded into each vendor's quota card,
/// because these are not quotas: no window, no denominator, no pace, and no
/// part in the advice engine or the menu-bar icon. A card that draws no bars
/// says that structurally.
struct APICreditSectionView: View {

    let entries: [APICreditEntry]
    /// The vendors whose newest poll failed, so their entries' figures here are
    /// carried over from an earlier poll. Keyed by vendor rather than held per
    /// entry, because a failed poll is the vendor's failure: every entry that
    /// poll retained is equally old.
    ///
    /// The popover's footer counts stale providers, but this card is *entirely*
    /// figures, and a balance that looks current when no poll produced it is the
    /// failure this project treats as the worst kind. Each affected row says so.
    var staleVendors: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                APICreditEntryRowView(
                    entry: entry,
                    isStale: staleVendors.contains(entry.vendorId.rawValue)
                )

                if index < entries.count - 1 {
                    Rectangle()
                        .fill(Theme.outlineVariant.opacity(0.22))
                        .frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.card)
        )
    }
}

/// One credit entry: the vendor's mark, the entry's name, and the figure in the
/// vendor's own unit. No bar, no marker, no countdown.
struct APICreditEntryRowView: View {

    let entry: APICreditEntry
    /// The vendor's newest poll failed, so this figure is carried over from an
    /// earlier one. The same fact the vendor's own quota row states, said here
    /// too: the two surfaces draw the same figure, so neither may present it as
    /// current while the other says it is old.
    var isStale: Bool = false

    private var p: APICreditEntryPresentation { APICreditEntryPresentation(entry: entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: Theme.rowSpacing) {
                // The vendor's own mark, so the row reads as that account's money.
                // Unmeasured status: this is a balance, not a quota with a state,
                // and the dot's job is to flag pressure that does not exist here.
                VendorAvatarView(
                    vendorId: entry.vendorId,
                    status: .measured(.none),
                    isExhausted: false,
                    size: Theme.rowAvatarSize
                )

                VStack(alignment: .leading, spacing: 1) {
                    // The presented title, not the bare label: the row speaks
                    // `p.title` and sets it as its tooltip, and a visible name
                    // that dropped the vendor would leave the three surfaces
                    // disagreeing about what the figure belongs to.
                    Text(p.title)
                        .font(Theme.Typography.title)
                        .tracking(Theme.Tracking.title)
                        .foregroundStyle(Theme.onSurface)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let detail = p.detail {
                        Text(detail)
                            .font(Theme.Typography.subtitle)
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .truncationMode(.tail)
                    }
                }
                .frame(width: Theme.nameColumnWidth, alignment: .leading)

                Spacer(minLength: 0)

                Text(p.figure)
                    .font(Theme.Typography.chip)
                    .foregroundStyle(Theme.onSurface)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surfaceContainerHighest.opacity(0.50))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            if isStale { staleRow }
        }
        .padding(.vertical, 8)
        .frame(minHeight: Theme.rowMinHeight)
        .contentShape(Rectangle())
        .help(p.source ?? p.spoken(stale: isStale))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.spoken(stale: isStale))
    }

    /// One line saying the figure above is not this poll's reading.
    ///
    /// No clock and no reason, unlike the quota row's note: the vendor's own row
    /// in this popover already gives both, and the two would only drift apart.
    /// What this card must never do is *not* say it. The triangle carries the
    /// meaning as a shape, not colour alone (WCAG 1.4.1), and the row's
    /// accessibility label speaks the same sentence.
    private var staleRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            Text("Stale — last poll failed")
                .font(Theme.Typography.subtitle)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHidden(true)
    }
}
