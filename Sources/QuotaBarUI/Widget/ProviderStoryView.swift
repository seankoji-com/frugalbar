import SwiftUI
import QuotaBarCore

/// The widget's Story layout: one pool, told in plain sentences above the
/// chart of the window the story follows, then what happened lately.
struct ProviderStoryView: View {
    let store: QuotaStore
    @Binding var poolID: String?
    /// Injected by the render harness; live use loads from the store.
    var preloaded: (readings: [QuotaHistoryStore.ReadingRecord], events: [AIEvent])? = nil
    var now: Date? = nil

    @State private var readings: [QuotaHistoryStore.ReadingRecord]?
    @State private var events: [AIEvent] = []
    @State private var loadedAt = Date()

    private struct LoadKey: Equatable {
        let poolID: String?
        let lastAttempt: Date?
    }

    private var instant: Date { now ?? loadedAt }
    private var glance: GlancePresentation { GlancePresentation(snapshots: store.snapshots, now: instant) }

    /// The pinned pool, else the top pick, else the first pool.
    private var pool: GlancePresentation.Pool? {
        let g = glance
        if let poolID, let pinned = g.pools.first(where: { $0.id == poolID }) { return pinned }
        return g.ranking.first?.pool ?? g.pools.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pool {
                let story = ProviderStoryPresentation(pool: pool, glance: glance, readings: readings, now: instant)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        header(story, pool: pool)
                        storyLines(story)
                        chart(story, pool: pool)
                        lately
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Text("No pools to tell a story about yet.")
                    .font(.system(size: 12)).foregroundStyle(Theme.outline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LoadKey(poolID: pool?.id, lastAttempt: store.summary.lastAttemptAt)) { await load() }
    }

    // MARK: Pieces

    private func header(_ story: ProviderStoryPresentation, pool: GlancePresentation.Pool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VendorAvatarView(vendorId: pool.snapshot.vendorId, status: pool.snapshot.status, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.onSurface)
                    .lineLimit(1)
                Text(story.subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.onSurfaceVariant).lineLimit(1)
                Text(story.standing)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color(story.tone))
            }
            Spacer(minLength: 6)
            if let w = story.window, let remaining = w.remaining, !w.isSpent {
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(GlancePresentation.percent(remaining))")
                            .font(.system(size: 34, weight: .bold).monospacedDigit())
                        Text("%").font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(color(story.tone))
                    Text("\(story.windowName ?? "") left")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.outline)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func storyLines(_ story: ProviderStoryPresentation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(story.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(color(line.tone))
                        .frame(width: 14)
                    Text(line.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(line.tone == .good ? Theme.onSurface : color(line.tone))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    @ViewBuilder
    private func chart(_ story: ProviderStoryPresentation, pool: GlancePresentation.Pool) -> some View {
        if let label = story.window?.bar.label, let readings,
           // The same gate as the inspector: a recorded projection is drawn
           // only while the live snapshot shows that usable window.
           let burndown = BurndownPresentation.burndown(readings: readings, instanceID: pool.id,
                                                       barLabel: label, now: instant)?
               .current(for: pool.snapshot, now: instant) {
            VStack(alignment: .leading, spacing: 12) {
                Text("This \(story.windowName ?? label) window")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onSurfaceVariant)
                BurndownChartView(burndown: burndown, now: instant)
                    .frame(height: 120)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        }
    }

    @ViewBuilder
    private var lately: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lately").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onSurfaceVariant)
                ForEach(events.prefix(3)) { EventRowView(event: $0, now: instant, compact: true) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        }
    }

    private func color(_ tone: ProviderStoryPresentation.Tone) -> Color {
        switch tone {
        case .good: Theme.healthy
        case .caution: Theme.tertiary
        case .spent: Theme.errorBold
        case .unknown: Theme.outline
        }
    }

    // MARK: Data

    private func load() async {
        if let preloaded {
            readings = preloaded.readings
            events = preloaded.events
            return
        }
        loadedAt = Date()
        guard let pool else { return }
        let snapshot = pool.snapshot
        var since = loadedAt.addingTimeInterval(-30 * 86_400)
        for bar in snapshot.quotaBars {
            if let reset = bar.resetsAt, let length = bar.windowLength { since = min(since, reset.addingTimeInterval(-length)) }
        }
        let raw = await store.readings(for: snapshot.vendorId, since: since)
        // An account's readings may be filed under earlier keys; name them as
        // this instance, as the inspector does.
        let aliases: [String] = (snapshot.claudeAccount?.historyAliases ?? [])
            + (snapshot.antigravityAccount.flatMap { account in
                AntigravityAccount.allowance(for: snapshot.vendorId).map { account.poolHistoryAliases(for: $0) }
            } ?? [])
        let recent = await store.events(for: snapshot.vendorId, instanceId: snapshot.id,
                                        kinds: QuotaStore.recentEventKinds, since: nil, limit: 3) ?? []
        guard !Task.isCancelled else { return }
        readings = raw.map { $0.map { aliases.contains($0.vendor) ? $0.namingInstance(snapshot.id) : $0 } }
        events = recent
    }
}

/// The story's pool picker: follow the top pick, or pin one pool.
struct StoryPoolMenu: View {
    let glance: GlancePresentation
    @Binding var poolID: String?

    var body: some View {
        Menu {
            Button("Follow the top pick") { poolID = nil }
            Divider()
            ForEach(serviceGroups, id: \.0) { service, pools in
                Section(service) {
                    ForEach(pools) { pool in
                        Button(pool.name == pool.service ? pool.service : pool.name) { poolID = pool.id }
                    }
                }
            }
        } label: {
            Label(label, systemImage: poolID == nil ? "sparkles" : "pin.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Story about: \(label)")
    }

    private var label: String {
        if let poolID, let pool = glance.pools.first(where: { $0.id == poolID }) { return pool.name }
        return "Top pick"
    }

    private var serviceGroups: [(String, [GlancePresentation.Pool])] {
        var order: [String] = []
        var map: [String: [GlancePresentation.Pool]] = [:]
        for pool in glance.pools {
            if map[pool.service] == nil { order.append(pool.service) }
            map[pool.service, default: []].append(pool)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}
