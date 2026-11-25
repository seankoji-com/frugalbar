import SwiftUI
import QuotaBarCore

/// The widget's Story layout: one pool, told in plain sentences above the
/// chart of the window the story follows, then what happened lately.
struct ProviderStoryView: View {
    let store: QuotaStore
    @Binding var poolID: String?
    /// Injected by the render harness; live use loads from the store.
    var preloaded: (readings: [QuotaHistoryStore.ReadingRecord], events: [AIEvent])? = nil
    /// The render harness's fixed instant. Live use follows `ticks`.
    var now: Date? = nil
    /// The clock the Story follows: the shared `GlanceClock` ticks, so a
    /// reset that passes while the widget is open turns it on the same tick
    /// as the popover and menu bar. Tests inject their own ticks.
    var ticks: () -> AsyncStream<Date> = { GlanceClock.ticks() }
    /// Told the story the view derives each time its time moves (a tick or
    /// a load). Tests only.
    var timeObserver: ((Date, ProviderStoryPresentation?) -> Void)? = nil

    @State private var readings: [QuotaHistoryStore.ReadingRecord]?
    @State private var events: [AIEvent] = []
    /// The time the Story describes. Moved by every clock tick and every
    /// load, never backwards. It used to move only on a load, keyed on the
    /// pool and the last poll attempt, so a poll served from cache left the
    /// Story describing a window whose published reset had passed.
    @State private var shownAt = Date()

    private struct LoadKey: Equatable {
        let poolID: String?
        let lastAttempt: Date?
    }

    private var instant: Date { now ?? shownAt }

    /// What the Story draws at `instant`: one derivation, read by the body
    /// and reported to `timeObserver`, so neither can describe another time.
    private struct Derived {
        let glance: GlancePresentation
        let pool: GlancePresentation.Pool
        let story: ProviderStoryPresentation
    }

    /// The pinned pool, else the top pick, else the first pool.
    private func derive(at instant: Date) -> Derived? {
        let glance = GlancePresentation(snapshots: store.snapshots, now: instant)
        let pinned = poolID.flatMap { id in glance.pools.first { $0.id == id } }
        guard let pool = pinned ?? glance.ranking.first?.pool ?? glance.pools.first else { return nil }
        return Derived(glance: glance, pool: pool,
                       story: ProviderStoryPresentation(pool: pool, glance: glance, readings: readings, now: instant))
    }

    var body: some View {
        let derived = derive(at: instant)
        VStack(alignment: .leading, spacing: 10) {
            if let derived {
                let pool = derived.pool
                let story = derived.story
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
        .task(id: LoadKey(poolID: derived?.pool.id, lastAttempt: store.summary.lastAttemptAt)) { await load() }
        // The story is a function of the time as well as the poll: every
        // figure, sentence and the burndown re-derive on each shared tick.
        .task {
            for await tick in ticks() { advance(to: tick) }
        }
    }

    private func advance(to time: Date) {
        shownAt = GlanceClock.displayTime(current: shownAt, tick: time)
        timeObserver?(instant, derive(at: instant)?.story)
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
            if let remaining = story.heroRemaining {
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
        let loadTime = Date()
        if let preloaded {
            readings = preloaded.readings
            events = preloaded.events
            advance(to: loadTime)
            return
        }
        guard let pool = derive(at: instant)?.pool else {
            advance(to: loadTime)
            return
        }
        let snapshot = pool.snapshot
        var since = loadTime.addingTimeInterval(-30 * 86_400)
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
        // The reads awaited; a tick may have moved the time past `loadTime`
        // meanwhile, and a load never winds it back.
        advance(to: loadTime)
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
