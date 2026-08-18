import SwiftUI
import QuotaBarCore

/// A categorized section showing a header + metric rows.
struct MetricSectionView: View {
    let category: MetricCategory
    let snapshots: [QuotaSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category.rawValue)
                .font(.caption2)
                .fontWeight(.bold)
                .kerning(0.8)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(snapshots) { snap in
                MetricRowView(snapshot: snap)
            }
        }
    }
}
