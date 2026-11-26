import Foundation
import QuotaBarCore

/// Pure logic behind the History window's at-a-glance strip and its
/// provider picker.
///
/// The strip is small multiples: one card per provider instance, each with
/// that instance's own longest window drawn from its own readings. Nothing is
/// summed or averaged across cards — vendors meter different things over
/// different windows — and a card's figure is always the latest reading the
/// store holds for that window, never one carried over from an older poll.
public enum HistoryOverviewPresentation {

    /// One thing the History window can chart: a vendor, or one OpenCode Go
    /// workspace.
    public struct Subject: Identifiable, Sendable, Equatable, Hashable {
        /// The instance key readings are stored under.
        public let id: String
        public let vendor: VendorIdentifier
        public let name: String
        /// Every stored key that belongs to this subject. The workspace that
        /// inherited the pre-workspace `opencode` key also owns the readings an
        /// install recorded under that key before workspaces existed.
        public let keys: [String]
        public let historicalOnly: Bool
        public init(id: String, vendor: VendorIdentifier, name: String, keys: [String]? = nil,
                    historicalOnly: Bool = false) {
            self.id = id
            self.vendor = vendor
            self.name = name
            self.keys = keys ?? [id]
            self.historicalOnly = historicalOnly
        }

        public func owns(_ key: String) -> Bool {
            keys.contains(key)
        }
    }

    /// The subjects to offer, in the user's provider order and, for OpenCode
    /// Go, the user's workspace order — the same order the popover draws.
    ///
    /// A hidden provider is left out, as it is everywhere else: it is not
    /// polled, so a History entry for it would chart readings that stopped
    /// arriving the moment it was hidden. A disabled workspace is left out
    /// for the same reason.
    public static func subjects(
        order: [VendorIdentifier],
        hidden: Set<VendorIdentifier>,
        workspaces: [OpenCodeGoWorkspace],
        claudeAccounts: [ClaudeAccount] = ClaudeAccountStore.all(),
        antigravityAccounts: [AntigravityAccount] = AntigravityAccountStore.all(),
        openDesignConnections: OpenDesignConnections? = nil,
        goAccounts: GoWorkspaceAccountSettings = GoWorkspaceAccountSettings()
    ) -> [Subject] {
        order.filter { !hidden.contains($0) }.flatMap { vendor -> [Subject] in
            if vendor == .claude, !claudeAccounts.isEmpty {
                return claudeAccounts.map { Subject(id: $0.id, vendor: .claude, name: $0.name, keys: $0.historyKeys) }
                    + [Subject(id: vendor.rawValue, vendor: .claude, name: "Claude (unattributed)")]
            }
            if let allowance = AntigravityAccount.allowance(for: vendor), !antigravityAccounts.isEmpty {
                var subjects = antigravityAccounts.map { account in
                    Subject(
                        id: account.poolInstanceID(for: allowance),
                        vendor: vendor,
                        name: antigravityAccounts.count > 1
                            ? "\(vendor.displayName) · \(account.name)"
                            : vendor.displayName,
                        keys: account.poolHistoryKeys(for: allowance)
                    )
                }
                // When only proxy accounts are active (no local primary owns the
                // legacy bare vendor key), keep a fallback unattributed subject
                // so pre-existing legacy readings on disk remain accessible.
                if !antigravityAccounts.contains(where: \.isPrimary) {
                    subjects.append(Subject(
                        id: vendor.rawValue,
                        vendor: vendor,
                        name: "\(vendor.displayName) (unattributed)"
                    ))
                }
                return subjects
            }
            if vendor == .opendesign {
                let accountSubjects = goAccountSubjects(.openDesign, settings: goAccounts)
                let accountIDs = Set(accountSubjects.map(\.id))
                let linked = OpenDesignConnection.allCases.compactMap { connection -> Subject? in
                    guard let workspace = openDesignConnections?.workspace(for: connection),
                          !accountIDs.contains(workspace.seriesID) else { return nil }
                    return Subject(id: workspace.seriesID, vendor: vendor, name: connection.displayName,
                                   historicalOnly: goAccounts.usesAccount(.openDesign))
                }
                let subjects = accountSubjects + linked
                return subjects.isEmpty ? [Subject(id: vendor.rawValue, vendor: vendor, name: vendor.displayName)] : subjects
            }
            guard vendor == .opencode else {
                return [Subject(id: vendor.rawValue, vendor: vendor, name: vendor.displayName)]
            }
            let accountSubjects = goAccountSubjects(.openCode, settings: goAccounts)
            return accountSubjects + workspaces.filter(\.isEnabled).map { workspace in
                Subject(
                    id: workspace.instanceID,
                    vendor: .opencode,
                    name: accountSubjects.isEmpty ? workspace.name : "\(workspace.name) · Earlier connection",
                    keys: workspace.id == OpenCodeGoWorkspaceStore.legacyID
                        ? [workspace.instanceID, VendorIdentifier.opencode.rawValue]
                        : [workspace.instanceID],
                    historicalOnly: goAccounts.usesAccount(.openCode)
                )
            }
        }
    }

    private static func goAccountSubjects(_ service: GoWorkspaceAccount, settings: GoWorkspaceAccountSettings) -> [Subject] {
        guard settings.usesAccount(service) else { return [] }
        let active = settings.activeHistoryIDs(for: service)
        return settings.knownWorkspaces(for: service).map {
            let id = service.seriesID(for: $0)
            return Subject(id: id, vendor: service.vendor, name: $0.name, historicalOnly: !active.contains(id))
        }
    }

    static func includingHistoricalSubjects(_ subjects: [Subject], readings: [QuotaHistoryStore.ReadingRecord]) -> [Subject] {
        let recorded = Set(readings.map(\.vendor))
        return subjects.filter { !$0.historicalOnly || $0.keys.contains(where: recorded.contains) }
    }

    /// Older and disconnected workspace series remain chartable by their own
    /// keys, even when the current connections no longer name them.
    static func includingOpenDesignHistory(_ subjects: [Subject], readings: [QuotaHistoryStore.ReadingRecord]) -> [Subject] {
        let vendor = VendorIdentifier.opendesign
        guard var insertion = subjects.lastIndex(where: { $0.vendor == vendor }) else { return subjects }
        let recorded = Set(readings.map(\.vendor))
        let workspaceKeys = recorded.filter { $0.hasPrefix(OpenDesignQuotaProvider.instancePrefix) }
        var result = subjects
        let replacesLegacyPlaceholder = result[insertion].id == vendor.rawValue && !workspaceKeys.isEmpty
        if replacesLegacyPlaceholder {
            result.remove(at: insertion)
        } else {
            insertion += 1
        }
        let known = Set(result.filter { $0.vendor == vendor }.flatMap(\.keys))
        var unlinked = workspaceKeys.subtracting(known).sorted().map { key in
            let reference = key.dropFirst(OpenDesignQuotaProvider.instancePrefix.count).prefix(8)
            let name = replacesLegacyPlaceholder && workspaceKeys.count == 1
                ? vendor.displayName : "OpenDesign · Workspace \(reference)"
            return Subject(id: key, vendor: vendor, name: name)
        }
        if recorded.contains(vendor.rawValue), !known.contains(vendor.rawValue) {
            unlinked.append(Subject(id: vendor.rawValue, vendor: vendor, name: "OpenDesign · Unattributed"))
        }
        result.insert(contentsOf: unlinked, at: insertion)
        return result
    }

    /// Local Claude Code activity does not identify the subscription account.
    /// It cannot explain either named account's quota history.
    public static func localActivitySources(for subject: Subject) -> Set<String> {
        if subject.id.hasPrefix(ClaudeAccount.instancePrefix) { return [] }
        return AttributionEngine.localSourceIdentifiers(for: subject.vendor)
    }

    public static func activityExplanation(for subject: Subject) -> String {
        if subject.id.hasPrefix(ClaudeAccount.instancePrefix) {
            return "Local Claude Code tokens are not attributed to a Claude account, so no project breakdown can be assigned to this account's allowance."
        }
        return "FrugalBar has no local activity adapter for \(subject.vendor.displayName), so no project breakdown can be attributed to its allowance."
    }

    /// The names of hidden providers, in the user's order, so the window can
    /// say why they are absent rather than leave the user hunting for them.
    public static func hiddenNames(order: [VendorIdentifier], hidden: Set<VendorIdentifier>) -> [String] {
        order.filter { hidden.contains($0) }.map(\.displayName)
    }

    /// One small-multiple card.
    public struct Card: Identifiable, Sendable, Equatable {
        public var id: String { subject.id }
        public let subject: Subject
        /// The window drawn: the longest one with a measured reading in range.
        public let barLabel: String
        /// The window's readings in range, oldest first. Gaps and resets
        /// break the line exactly as on the main chart.
        public let segments: [HistoryPresentation.TimelineSegment]
        /// The newest reading for the window, whatever it said.
        public let latest: QuotaHistoryStore.ReadingRecord
        /// The subject's newest poll of any kind, the failed ones included: a
        /// poll that could not be read is recorded under `DEFAULT`, not under
        /// the window, so `latest` alone would keep showing the figure from
        /// before it.
        public let lastPoll: QuotaHistoryStore.ReadingRecord
        /// How many readings with a figure the thinned query kept for the
        /// window: at most one per time bucket, not every reading recorded in
        /// range. The failed polls it also keeps, to break the line, are not
        /// counted as readings.
        public let sampleCount: Int

        /// The last poll reported this window. When it did not — the provider
        /// could not be read, or stopped publishing the window — the card
        /// leads with that rather than an older figure.
        public var latestIsCurrent: Bool { lastPoll.measuredAt <= latest.measuredAt }

        /// The figure the card leads with, or nil when the latest poll had
        /// none.
        public var latestPercent: Int? {
            guard latestIsCurrent else { return nil }
            return latest.fraction.map { Int((min(max($0, 0), 1) * 100).rounded()) }
        }

        /// Why there is no figure, when there is none.
        public var noFigureText: String? {
            guard latestPercent == nil else { return nil }
            if !latestIsCurrent, lastPoll.confidence != .measured { return "Could not be read at the last poll" }
            return "No \(barLabel) figure at the last poll"
        }
    }

    /// A subject that was polled in range but never returned a figure to
    /// draw. It is not "no readings": the polls happened and failed, and the
    /// strip says so instead of explaining an absence.
    public struct Unread: Identifiable, Sendable, Equatable {
        public var id: String { subject.id }
        public let subject: Subject
        /// The subject's newest poll in range.
        public let lastPoll: QuotaHistoryStore.ReadingRecord

        public var explanation: String { HistoryOverviewPresentation.polledWithoutFigureText(lastPoll: lastPoll) }

        /// A warning only when the last poll failed; a provider that answered
        /// without a usage window has nothing wrong with it.
        public var symbol: String { lastPoll.confidence == .measured ? "minus.circle" : "exclamationmark.triangle" }
    }

    /// Cards for the subjects that have a consumption reading in `readings`,
    /// in subject order; `unread` names the ones that were polled but returned
    /// no figure, and `empty` the ones with no poll recorded at all.
    ///
    /// `bucketSeconds` is the width the readings were thinned to. Points that
    /// far apart are neighbours, not an outage, so the line breaks only on a
    /// gap of more than two and a half buckets (and never under the main
    /// chart's two hours), or on a reset.
    public static func overview(
        subjects: [Subject],
        readings: [QuotaHistoryStore.ReadingRecord],
        bucketSeconds: Int = 0
    ) -> (cards: [Card], unread: [Unread], empty: [Subject]) {
        let maxGap = sparklineMaxGap(bucketSeconds: bucketSeconds)
        var cards: [Card] = []
        var unread: [Unread] = []
        var empty: [Subject] = []
        for subject in subjects {
            let all = readings.filter { subject.owns($0.vendor) }.map { $0.namingInstance(subject.id) }
            let own = HistoryPresentation.consumptionReadings(all)
            guard let label = longestMeasuredLabel(own) else {
                if let lastPoll = all.max(by: { $0.measuredAt < $1.measuredAt }) {
                    unread.append(Unread(subject: subject, lastPoll: lastPoll))
                } else {
                    empty.append(subject)
                }
                continue
            }
            let window = own.filter { $0.barLabel == label }.sorted { $0.measuredAt < $1.measuredAt }
            guard let latest = window.last,
                  let lastPoll = all.max(by: { $0.measuredAt < $1.measuredAt }) else {
                empty.append(subject)
                continue
            }
            cards.append(Card(
                subject: subject,
                barLabel: label,
                segments: HistoryPresentation.segments(from: own, barLabel: label, maxGap: maxGap),
                latest: latest,
                lastPoll: lastPoll,
                sampleCount: window.filter { $0.fraction != nil }.count
            ))
        }
        return (cards, unread, empty)
    }

    /// The longest silence a sparkline bridges, for readings thinned to
    /// `bucketSeconds`.
    static func sparklineMaxGap(bucketSeconds: Int) -> TimeInterval {
        max(7200, Double(bucketSeconds) * 2.5)
    }

    /// The longest window that has at least one measured reading; ties and
    /// windows of unpublished length fall back to the label, so the choice is
    /// stable from one reload to the next.
    static func longestMeasuredLabel(_ readings: [QuotaHistoryStore.ReadingRecord]) -> String? {
        var lengths: [String: TimeInterval] = [:]
        for record in readings where record.fraction != nil {
            lengths[record.barLabel] = max(lengths[record.barLabel] ?? -1, record.windowLength ?? -1)
        }
        return lengths.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key
    }

    /// Bucket width for the overview read: about 120 points per sparkline
    /// whatever the range, never finer than a poll.
    public static func sampleBucketSeconds(range: HistoryPresentation.TimeRange, retention: TimeInterval) -> Int {
        let span: TimeInterval = switch range {
        case .last24Hours: 86_400
        case .last7Days: 7 * 86_400
        case .last30Days: 30 * 86_400
        case .allTime: retention
        }
        return max(120, Int(span / 120))
    }

    /// Why polls that happened left nothing to draw. `lastPoll` is the
    /// subject's newest recorded poll of any kind.
    public static func polledWithoutFigureText(lastPoll: QuotaHistoryStore.ReadingRecord) -> String {
        lastPoll.confidence == .measured
            ? "Polled in this range, but no poll reported a usage figure to chart."
            : "Polled in this range, but no poll returned a figure. The last poll could not be read."
    }

    /// What the timeline says when it has nothing to draw. `readings` is
    /// everything the subject recorded in range, every label included: a
    /// failed poll recorded under `DEFAULT` is not an absence of data, so
    /// neither the title nor the detail may call it one.
    public static func timelineEmptyState(
        readings: [QuotaHistoryStore.ReadingRecord],
        isSampleMode: Bool,
        range: HistoryPresentation.TimeRange
    ) -> (title: String, detail: String) {
        if let lastPoll = readings.max(by: { $0.measuredAt < $1.measuredAt }) {
            return ("Nothing to chart in this time range", polledWithoutFigureText(lastPoll: lastPoll))
        }
        return ("No readings recorded in this time range", emptyExplanation(isSampleMode: isSampleMode, range: range))
    }

    /// Why a subject has no card, in words: the window is being asked to
    /// explain an absence, not to draw one.
    public static func emptyExplanation(isSampleMode: Bool, range: HistoryPresentation.TimeRange) -> String {
        if isSampleMode {
            return "The sample data has no readings for these in this range."
        }
        return range == .allTime
            ? "No readings recorded yet. FrugalBar records a reading each time it polls a configured provider."
            : "No readings in the last \(range.title.lowercased()). FrugalBar records a reading each time it polls a configured provider."
    }

    // MARK: - Inspecting a point

    /// One poll as a chart readout shows it: the instant it was recorded and
    /// each window's reading from that same poll.
    public struct InspectedPoll: Equatable, Sendable {
        public struct Row: Equatable, Sendable {
            public let barLabel: String
            public let point: HistoryPresentation.TimelinePoint
        }
        public let timestamp: Date
        public let rows: [Row]
    }

    /// The poll nearest to `date`, for the chart's hover readout; nil when
    /// nothing was recorded within `tolerance`, so the readout never names a
    /// reading from hours away as "this point".
    ///
    /// Windows are grouped only when they came from the same poll, which
    /// writes every window at one instant. Picking each window's nearest
    /// reading separately put a 5H figure under a WK reading's timestamp when
    /// the two were five minutes apart.
    public static func nearestPoll(
        to date: Date,
        in segments: [HistoryPresentation.TimelineSegment],
        tolerance: TimeInterval
    ) -> InspectedPoll? {
        let nearest = segments.lazy.flatMap(\.points)
            .map(\.timestamp)
            .filter { abs($0.timeIntervalSince(date)) <= tolerance }
            .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
        return nearest.flatMap { poll(at: $0, in: segments) }
    }

    /// Every window's reading recorded at exactly `timestamp`.
    public static func poll(
        at timestamp: Date,
        in segments: [HistoryPresentation.TimelineSegment]
    ) -> InspectedPoll? {
        var rows: [InspectedPoll.Row] = []
        for segment in segments where !rows.contains(where: { $0.barLabel == segment.barLabel }) {
            if let point = segment.points.first(where: { $0.timestamp == timestamp }) {
                rows.append(InspectedPoll.Row(barLabel: segment.barLabel, point: point))
            }
        }
        return rows.isEmpty ? nil : InspectedPoll(timestamp: timestamp, rows: rows)
    }

    /// The poll `offset` steps from `current`, for stepping through a chart
    /// with the arrow keys or VoiceOver's adjust action. With nothing selected
    /// the first step lands on the newest poll, the one most worth reading;
    /// stepping stops at either end rather than wrapping.
    public static func steppedPoll(
        from current: Date?,
        by offset: Int,
        in segments: [HistoryPresentation.TimelineSegment]
    ) -> Date? {
        let instants = Array(Set(segments.flatMap { $0.points.map(\.timestamp) })).sorted()
        guard let last = instants.indices.last else { return nil }
        guard let current else { return instants[last] }
        // Between two polls (the pointer left it there), a step goes to the
        // neighbour on that side.
        let index = instants.firstIndex { $0 >= current } ?? instants.count
        let onPoll = index < instants.count && instants[index] == current
        let at = onPoll ? index + offset : (offset < 0 ? index - 1 : index)
        return instants[min(max(at, 0), last)]
    }

    /// How close the pointer must be to a reading for the readout to claim
    /// it: a fiftieth of the visible span, at least five minutes.
    public static func inspectionTolerance(range: HistoryPresentation.TimeRange, now: Date, earliest: Date?) -> TimeInterval {
        let start = range.startDate(from: now) ?? earliest ?? now.addingTimeInterval(-86_400)
        return max(300, now.timeIntervalSince(start) / 50)
    }
}
