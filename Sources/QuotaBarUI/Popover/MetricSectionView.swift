import SwiftUI
import QuotaBarCore

/// A categorized section showing a header + metric rows with visual separators.
struct MetricSectionView: View {

    let category: MetricCategory
    let snapshots: [QuotaSnapshot]
    var onSelect: ((QuotaSnapshot) -> Void)? = nil

    var body: some View {
        // Vendor rows with subtle alternating card styling & separators
        VStack(spacing: 0) {
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snap in
                MetricRowView(
                    snapshot: snap,
                    isAltRow: index % 2 != 0,
                    onSelect: onSelect
                )

                if index < snapshots.count - 1 {
                    Rectangle()
                        .fill(Theme.outlineVariant.opacity(0.20))
                        .frame(height: 0.5)
                        .padding(.horizontal, 6)
                }
            }
        }
        .background(Theme.surfaceContainerLowest.opacity(0.50))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.outlineVariant.opacity(0.25), lineWidth: 0.5)
        )
    }
}




