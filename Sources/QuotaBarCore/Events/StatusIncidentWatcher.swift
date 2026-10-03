import Foundation

/// A vendor's official status page, read through the Statuspage incident API
/// (`/api/v2/incidents.json`, the newest 50 incidents with their impact,
/// affected components and timestamps).
///
/// Only Anthropic, OpenAI and GitHub publish one FrugalBar can read. OpenRouter
/// and xAI answer the API with 403, and Google, Kiro, OpenCode, Cline,
/// Command Code and LLM Gateway have no machine-readable status history.
public struct StatusPage: Sendable, Equatable {
    /// Which of a page's incidents concern the product FrugalBar tracks.
    public enum Relevance: Sendable, Equatable {
        /// The incident lists one of these components. An incident listing no
        /// components at all counts too when `includeUnscoped` — Anthropic
        /// files platform-wide failures ("Elevated errors across all models")
        /// with an empty component list.
        case components(Set<String>, includeUnscoped: Bool)
        /// OpenAI's page publishes no components. An incident counts when its
        /// name mentions one of these words, or when it is critical, which on
        /// that page means everything is down.
        case nameMentions([String])
    }

    /// Short stable identifier, persisted in the event source (`status:<name>`).
    public let name: String
    public let vendorId: VendorIdentifier
    public let incidentsURL: URL
    /// Base for an incident link when the API gives no shortlink.
    public let pageURL: URL
    public let relevance: Relevance

    public init(name: String, vendorId: VendorIdentifier, incidentsURL: URL, pageURL: URL, relevance: Relevance) {
        self.name = name
        self.vendorId = vendorId
        self.incidentsURL = incidentsURL
        self.pageURL = pageURL
        self.relevance = relevance
    }

    public static let all: [StatusPage] = [
        StatusPage(
            name: "claude",
            vendorId: .claude,
            incidentsURL: URL(string: "https://status.claude.com/api/v2/incidents.json")!,
            pageURL: URL(string: "https://status.claude.com")!,
            relevance: .components(
                ["Claude Code", "Claude API (api.anthropic.com)", "claude.ai"], includeUnscoped: true)),
        StatusPage(
            name: "openai",
            vendorId: .openai,
            incidentsURL: URL(string: "https://status.openai.com/api/v2/incidents.json")!,
            pageURL: URL(string: "https://status.openai.com")!,
            relevance: .nameMentions(["codex"])),
        StatusPage(
            name: "github",
            vendorId: .copilot,
            incidentsURL: URL(string: "https://www.githubstatus.com/api/v2/incidents.json")!,
            pageURL: URL(string: "https://www.githubstatus.com")!,
            relevance: .components(["Copilot", "Copilot AI Model Providers"], includeUnscoped: false)),
    ]

    public static func named(_ name: String) -> StatusPage? {
        all.first { $0.name == name }
    }
}

/// One incident as the status page published it.
public struct StatusIncident: Sendable, Equatable {
    public enum Impact: String, Sendable, Comparable {
        case none, minor, major, critical

        public static func < (a: Impact, b: Impact) -> Bool { a.rank < b.rank }
        private var rank: Int {
            switch self {
            case .none: 0
            case .minor: 1
            case .major: 2
            case .critical: 3
            }
        }
    }

    public let id: String
    public let name: String
    public let impact: Impact
    /// `investigating`, `identified`, `monitoring`, `resolved`, `postmortem`.
    public let status: String
    public let startedAt: Date
    /// Present once the vendor marked it resolved.
    public let resolvedAt: Date?
    public let components: [String]
    public let shortlink: URL?

    public init(
        id: String, name: String, impact: Impact, status: String, startedAt: Date,
        resolvedAt: Date?, components: [String], shortlink: URL?
    ) {
        self.id = id
        self.name = name
        self.impact = impact
        self.status = status
        self.startedAt = startedAt
        self.resolvedAt = resolvedAt
        self.components = components
        self.shortlink = shortlink
    }

    public var isResolved: Bool {
        (status == "resolved" || status == "postmortem") && resolvedAt != nil
    }
}

/// Reads official status pages and records major outages and their recovery.
///
/// Only `major` and `critical` incidents are recorded. Statuspage's `minor`
/// covers a slow dashboard or one model's elevated latency, and on these
/// pages it is filed several times a week; an outage worth a line in the log
/// is one the vendor itself called major.
///
/// Stateless, like the reset trackers: an incident's start and its recovery
/// are keyed on the vendor's incident id, so re-reading the page records each
/// once, and a recovery is recorded on the first poll after the vendor marks
/// the incident resolved.
public struct StatusIncidentWatcher: Sendable {
    public typealias Fetcher = @Sendable (StatusPage) async -> Data?

    public static let minimumImpact: StatusIncident.Impact = .major

    private let pages: [StatusPage]
    private let fetch: Fetcher

    public init(pages: [StatusPage] = StatusPage.all, fetch: @escaping Fetcher = StatusIncidentWatcher.liveFetch) {
        self.pages = pages
        self.fetch = fetch
    }

    public func prepare(vendors: Set<VendorIdentifier>, now: Date) async -> PendingPoll {
        var events: [AIEvent] = []
        var fetched = false
        for page in pages where vendors.contains(page.vendorId) {
            guard let data = await fetch(page) else { continue }
            guard let incidents = Self.parse(data) else {
                NSLog("frugalbar: status page \(page.name) returned an unreadable payload")
                continue
            }
            fetched = true
            events += Self.events(for: page, incidents: incidents, now: now)
        }
        return PendingPoll(events: events, fetched: fetched, commit: {})
    }

    // MARK: - Events

    static func events(for page: StatusPage, incidents: [StatusIncident], now: Date) -> [AIEvent] {
        incidents
            .filter { $0.impact >= minimumImpact && isRelevant($0, to: page) }
            .flatMap { incident -> [AIEvent] in
                var out = [started(incident, page: page, now: now)]
                if incident.isResolved, let resolvedAt = incident.resolvedAt {
                    out.append(resolved(incident, at: resolvedAt, page: page, now: now))
                }
                return out
            }
    }

    static func isRelevant(_ incident: StatusIncident, to page: StatusPage) -> Bool {
        switch page.relevance {
        case .components(let names, let includeUnscoped):
            if incident.components.isEmpty { return includeUnscoped }
            return incident.components.contains { names.contains($0) }
        case .nameMentions(let words):
            if incident.impact == .critical { return true }
            let name = incident.name.lowercased()
            return words.contains { name.contains($0) }
        }
    }

    private static func link(_ incident: StatusIncident, page: StatusPage) -> URL? {
        incident.shortlink ?? page.pageURL.appendingPathComponent("incidents").appendingPathComponent(incident.id)
    }

    static func started(_ incident: StatusIncident, page: StatusPage, now: Date) -> AIEvent {
        let impact = incident.impact == .critical ? "Critical" : "Major"
        let scope = incident.components.isEmpty ? "" : " · \(incident.components.joined(separator: ", "))"
        return AIEvent(
            id: AIEvent.makeID(kind: .outageStarted, vendorId: page.vendorId, components: [page.name, incident.id]),
            kind: .outageStarted,
            vendorId: page.vendorId,
            title: "Outage: \(incident.name.trimmingCharacters(in: .whitespacesAndNewlines))",
            detail: "\(impact) impact\(scope)",
            occurredAt: min(incident.startedAt, now),
            observedAt: now,
            source: .statusPage(name: page.name),
            url: link(incident, page: page)
        )
    }

    static func resolved(_ incident: StatusIncident, at resolvedAt: Date, page: StatusPage, now: Date) -> AIEvent {
        let duration = max(0, resolvedAt.timeIntervalSince(incident.startedAt))
        return AIEvent(
            id: AIEvent.makeID(kind: .outageResolved, vendorId: page.vendorId, components: [page.name, incident.id]),
            kind: .outageResolved,
            vendorId: page.vendorId,
            title: "Resolved: \(incident.name.trimmingCharacters(in: .whitespacesAndNewlines))",
            detail: "Resolved after \(BurnRateForecast.formatDuration(duration))",
            occurredAt: min(resolvedAt, now),
            observedAt: now,
            source: .statusPage(name: page.name),
            url: link(incident, page: page)
        )
    }

    // MARK: - Parsing

    private struct Payload: Decodable {
        struct Component: Decodable { let name: String? }
        struct Incident: Decodable {
            let id: String?
            let name: String?
            let status: String?
            let impact: String?
            let created_at: String?
            let started_at: String?
            let resolved_at: String?
            let shortlink: String?
            let components: [Component]?
        }
        let incidents: [Incident]
    }

    /// nil when the payload is not a Statuspage incident list.
    static func parse(_ data: Data) -> [StatusIncident]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return payload.incidents.compactMap { raw in
            guard let id = raw.id, !id.isEmpty,
                  let name = raw.name, !name.isEmpty,
                  let impact = raw.impact.flatMap(StatusIncident.Impact.init(rawValue:)),
                  // `started_at` is the vendor's own start time and is often
                  // earlier than the post; `created_at` is the fallback.
                  let started = (raw.started_at ?? raw.created_at).flatMap(ResetTrackerWatcher.parseDate)
            else { return nil }
            return StatusIncident(
                id: id,
                name: name,
                impact: impact,
                status: raw.status ?? "",
                startedAt: started,
                resolvedAt: raw.resolved_at.flatMap(ResetTrackerWatcher.parseDate),
                components: (raw.components ?? []).compactMap(\.name),
                shortlink: raw.shortlink.flatMap(URL.init(string:))
            )
        }
    }

    public static func liveFetch(_ page: StatusPage) async -> Data? {
        guard let (data, http) = try? await QuotaHTTP.get(
            url: page.incidentsURL.absoluteString, headers: ["Accept": "application/json"])
        else {
            NSLog("frugalbar: status page \(page.name) fetch failed")
            return nil
        }
        guard QuotaHTTP.failureReason(for: http.statusCode) == nil else {
            NSLog("frugalbar: status page \(page.name) returned HTTP \(http.statusCode)")
            return nil
        }
        return data
    }
}
