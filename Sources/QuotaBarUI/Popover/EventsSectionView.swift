import SwiftUI
import QuotaBarCore

/// The popover's "Latest event" card: the newest recorded event and a way
/// into the full list in the History window.
///
/// One compact row (about 30pt) so it never pushes the quota rows — the
/// reason the popover exists — below the fold.
struct EventsSectionView: View {

    let events: [AIEvent]
    var onSeeAll: () -> Void = { HistoryWindow.show(tab: .events) }

    static let visibleCount = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Latest event")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)

                Button(action: onSeeAll) {
                    HStack(spacing: 2) {
                        Text("See all")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all events in the History window")
            }
            .padding(.top, 8)

            // Ticks once a minute so "just now" ages while the popover is open.
            TimelineView(.everyMinute) { context in
                VStack(spacing: 0) {
                    let shown = Array(events.prefix(Self.visibleCount))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, event in
                        EventRowView(event: event, now: context.date)
                        if index < shown.count - 1 {
                            Rectangle()
                                .fill(Theme.outlineVariant.opacity(0.22))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Latest event")
    }
}
