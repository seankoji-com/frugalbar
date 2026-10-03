import SwiftUI
import QuotaBarCore

/// A categorized section: one card holding the vendor rows for that category,
/// hairline-separated.
struct MetricSectionView: View {

    let category: MetricCategory
    let snapshots: [QuotaSnapshot]
    var forecasts: [VendorIdentifier: BurnRateForecast] = [:]
    var onSelect: ((QuotaSnapshot) -> Void)? = nil

    /// The column header shows only when a row actually uses the grid.
    private var showsColumnHeader: Bool {
        snapshots.contains { WindowGridPresentation(snapshot: $0).usesGrid }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsColumnHeader {
                columnHeader
            }
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snap in
                MetricRowView(
                    snapshot: snap,
                    onSelect: onSelect,
                    forecast: forecasts[snap.vendorId],
                    forecastAbove: index == snapshots.count - 1
                )

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
        // ground and the card never read as a separate surface. A shaped
        // background rather than a clip, so a row's hover forecast can float
        // past the card's edge instead of being cut off by it.
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.card)
        )
    }

    /// "5H  WK  MO" over the grid columns, aligned with the cells below.
    private var columnHeader: some View {
        HStack(spacing: Theme.rowSpacing) {
            Color.clear
                .frame(width: Theme.rowAvatarSize + Theme.rowSpacing + Theme.nameColumnWidth, height: 1)
            HStack(spacing: Theme.gridColumnSpacing) {
                ForEach(WindowColumn.allCases) { column in
                    Text(column.label)
                        .font(Theme.Typography.token)
                        .tracking(Theme.Tracking.token)
                        .foregroundStyle(Theme.outline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 8)
        .accessibilityHidden(true)
    }
}
