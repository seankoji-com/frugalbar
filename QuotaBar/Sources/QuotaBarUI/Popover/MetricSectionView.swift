import SwiftUI
import QuotaBarCore

/// A categorized section showing a header + metric rows.
struct MetricSectionView: View {
    let category: MetricCategory
    let snapshots: [QuotaSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category.rawValue)
                .font(.system(size: 9, weight: .bold, design: .default))
                .kerning(0.8)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(snapshots) { snap in
                MetricRowView(snapshot: snap)
            }
        }
    }
}
