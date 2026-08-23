import SwiftUI
import QuotaBarCore

/// A categorized section: one card holding the vendor rows for that category,
/// hairline-separated.
struct MetricSectionView: View {

    let category: MetricCategory
    let snapshots: [QuotaSnapshot]
    var onSelect: ((QuotaSnapshot) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snap in
                MetricRowView(snapshot: snap, onSelect: onSelect)

                if index < snapshots.count - 1 {
                    Rectangle()
                        .fill(Theme.outlineVariant.opacity(0.22))
                        .frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 4)
        // Solid, not translucent: the old 50% fill sat on a near-identical
        // ground and the card never read as a separate surface.
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}
