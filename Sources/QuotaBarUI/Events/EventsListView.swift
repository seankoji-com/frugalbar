import SwiftUI
import QuotaBarCore

/// The History window's Events tab: every recorded AI-platform event, filtered
/// by kind, vendor and time range, grouped by day.
///
/// Reads the live history store only. The sample fixture records no events,
/// so sample mode shows a note rather than an empty list that would read as
/// "nothing happened".
struct EventsListView: View {

    let store: QuotaHistoryStore
    let isSampleMode: Bool

    @State private var kinds: Set<AIEventKind> = Set(AIEventKind.allCases)
    @State private var vendor: VendorIdentifier? = nil
    @State private var timeRange: HistoryPresentation.TimeRange = .last7Days
    @State private var events: [AIEvent] = []
    /// True when the store holds no events at all, in any range — the user
    /// is early, not filtering too hard.
    @State private var storeIsEmpty = false
    /// Non-nil when the events could not be read. Never rendered as empty.
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var loadedAt = Date()

    private struct ReloadKey: Hashable {
        let kinds: Set<AIEventKind>
        let vendor: VendorIdentifier?
        let range: HistoryPresentation.TimeRange
        let sampleMode: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isSampleMode {
                        sampleNote
                    } else if let loadError {
                        failureCard(loadError)
                    } else if events.isEmpty {
                        emptyState
                    } else {
                        dayGroups
                    }
                }
                .padding(16)
            }
        }
        .task(id: ReloadKey(kinds: kinds, vendor: vendor, range: timeRange, sampleMode: isSampleMode)) {
            await reload()
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Vendor", selection: $vendor) {
                    Text("All vendors").tag(VendorIdentifier?.none)
                    Divider()
                    ForEach(VendorIdentifier.allCases, id: \.self) { vendor in
                        Text(vendor.displayName).tag(VendorIdentifier?.some(vendor))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                .accessibilityLabel("Vendor")

                Picker("Time range", selection: $timeRange) {
                    ForEach(HistoryPresentation.TimeRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .accessibilityLabel("Time range")

                Spacer(minLength: 0)

                if isLoading {
                    ProgressView().scaleEffect(0.6)
                }
            }

            // Wraps onto a second line in a narrow window rather than clipping.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { kindChips }
                VStack(alignment: .leading, spacing: 6) { kindChips }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.card.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.outlineVariant.opacity(0.25))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var kindChips: some View {
        ForEach(AIEventKind.allCases) { kind in
            kindChip(kind)
        }
    }

    private func kindChip(_ kind: AIEventKind) -> some View {
        let isOn = kinds.contains(kind)
        let tint = EventsPresentation.kindTint(kind)
        return Button {
            if isOn { kinds.remove(kind) } else { kinds.insert(kind) }
        } label: {
            HStack(spacing: 4) {
                // The checkmark is the non-colour channel for "selected".
                Image(systemName: isOn ? "checkmark" : kind.symbolName)
                    .font(.system(size: 10, weight: .bold))
                Text(kind.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? tint : Theme.onSurfaceVariant.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isOn ? tint.opacity(0.16) : Color.clear)
            .overlay(
                Capsule().stroke(isOn ? tint.opacity(0.5) : Theme.outlineVariant.opacity(0.6), lineWidth: 0.75)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.title) events")
        .accessibilityValue(isOn ? "shown" : "hidden")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Content

    private var dayGroups: some View {
        let calendar = Calendar.current
        return ForEach(EventsPresentation.groupedByDay(events, calendar: calendar), id: \.day) { group in
            VStack(alignment: .leading, spacing: 6) {
                Text(EventsPresentation.dayTitle(group.day, now: loadedAt, calendar: calendar))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 0) {
                    ForEach(Array(group.events.enumerated()), id: \.element.id) { index, event in
                        EventRowView(event: event, now: loadedAt, compact: false)
                        if index < group.events.count - 1 {
                            Rectangle()
                                .fill(Theme.outlineVariant.opacity(0.22))
                                .frame(height: 0.5)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 28))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.4))

            Text("No events recorded in this range")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))

            if storeIsEmpty {
                Text("Events accumulate as FrugalBar polls your providers and tracks model catalogs and vendor feeds.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
    }

    private var sampleNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            Text("The sample fixture has no events. Exit sample mode to see events FrugalBar has recorded.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.error)
                Text("Could not read recorded events")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)
            }

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            Text("This is a failure to read, not an absence of events.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.error.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.error.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Could not read recorded events. \(message)")
    }

    // MARK: - Data

    private func reload() async {
        guard !isSampleMode else {
            events = []
            loadError = nil
            return
        }
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        do {
            let fetched = try await store.fetchEvents(
                vendor: vendor,
                since: timeRange.startDate(from: now)
            )
            let filtered = EventsPresentation.filter(
                events: fetched, kinds: kinds, vendor: vendor, range: timeRange, now: now
            )
            storeIsEmpty = filtered.isEmpty ? try await store.fetchEvents(limit: 1).isEmpty : false
            events = filtered
            loadedAt = now
            loadError = nil
        } catch {
            events = []
            storeIsEmpty = false
            loadError = error.localizedDescription
        }
    }
}
