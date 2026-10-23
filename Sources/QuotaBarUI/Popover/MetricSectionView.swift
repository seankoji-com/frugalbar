import SwiftUI
import QuotaBarCore

/// A categorized section: one card holding the vendor rows for that category,
/// with hairlines between vendor groups and standalone rows.
struct MetricSectionView: View {

    let category: MetricCategory
    let snapshots: [QuotaSnapshot]
    var ordering: ProviderOrdering = .automatic
    var forecasts: [String: BurnRateForecast] = [:]
    /// Recorded balance-over-time points per `BalanceSeries.id`, for the rows
    /// that carry a money figure. Empty when the history loader was not
    /// injected or no series has history.
    var balanceSeries: [String: [BalancePoint]] = [:]
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
            let groups = PopoverRowGrouping.groups(for: snapshots, ordering: ordering)
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                VStack(spacing: 0) {
                    if let header = group.header {
                        Text(header)
                            .font(Theme.Typography.title)
                            .tracking(Theme.Tracking.title)
                            .foregroundStyle(Theme.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, Theme.rowAvatarSize + Theme.rowSpacing)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(group.snapshots) { snap in
                        MetricRowView(
                            snapshot: snap,
                            onSelect: onSelect,
                            forecast: forecasts[snap.id],
                            // Only this card's final row draws its hover forecast above
                            // itself: every other row has a row or group header below it.
                            // A card rendered below this one puts content there, so this
                            // is a per-card rule, not a per-popover one.
                            forecastAbove: index == groups.count - 1
                                && snap.id == group.snapshots.last?.id,
                            balancePoints: BalanceSeries.of(snap).flatMap { balanceSeries[$0.id] } ?? [],
                            isGrouped: group.isGrouped,
                            suppressPlan: group.suppressPlan
                        )
                    }
                }
                // Header and rows read as one element in VoiceOver; the
                // header trait on its own left the text floating among
                // unrelated rows. Ungrouped rows keep the structure they
                // had, so a single-instance vendor is untouched.
                .modifier(GroupAccessibilityContainer(isGrouped: group.isGrouped))
                // The hairline sits between groups, outside the container, so
                // it never becomes part of a group's spoken element.
                if index < groups.count - 1 {
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

    /// Only when some bar here actually draws a pace tick: the same
    /// `paceMarker` rule the bars use, so the legend never names a marker
    /// that is absent (all bars at an end, spent, or unread).
    nonisolated static func showsPaceLegend(for snapshots: [QuotaSnapshot]) -> Bool {
        snapshots.contains { $0.displayBars.contains { $0.paceMarker != nil } }
    }

    private var hasPace: Bool { Self.showsPaceLegend(for: snapshots) }

    /// Names the one marker on the bars, in the header's empty leading space.
    @ViewBuilder
    private var paceLegend: some View {
        if hasPace {
            HStack(spacing: 4) {
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 9)
                Text("even pace")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.outline)
            }
            .padding(.leading, Theme.rowAvatarSize + Theme.rowSpacing)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// "5H  WK  MO" over the grid columns, aligned with the cells below.
    private var columnHeader: some View {
        HStack(spacing: Theme.rowSpacing) {
            paceLegend
                .frame(width: Theme.gridLeadingInset, alignment: .leading)
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

/// Ties a grouped run's header to the rows beneath it for VoiceOver, and leaves
/// an ungrouped row exactly as it was.
private struct GroupAccessibilityContainer: ViewModifier {
    let isGrouped: Bool

    func body(content: Content) -> some View {
        if isGrouped {
            content.accessibilityElement(children: .contain)
        } else {
            content
        }
    }
}
