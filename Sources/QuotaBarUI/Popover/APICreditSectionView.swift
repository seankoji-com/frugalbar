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

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                APICreditEntryRowView(entry: entry)

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

    private var p: APICreditEntryPresentation { APICreditEntryPresentation(entry: entry) }

    var body: some View {
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
                Text(entry.label)
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
        .padding(.vertical, 8)
        .frame(minHeight: Theme.rowMinHeight)
        .contentShape(Rectangle())
        .help(p.source ?? p.spoken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.spoken)
    }
}
