import Testing
import Foundation
@testable import QuotaBarCore

@Suite("StatusIncidentWatcher")
struct StatusIncidentWatcherTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

    /// The Statuspage `/api/v2/incidents.json` shape, trimmed.
    static let incidents = #"""
    {"page":{"id":"p"},"incidents":[
      {"id":"inc-major","name":"Elevated errors on Claude Code","status":"resolved","impact":"major",
       "created_at":"2027-01-14T10:05:00.000Z","started_at":"2027-01-14T10:00:00.000Z",
       "resolved_at":"2027-01-14T11:30:00.000Z","shortlink":"https://stspg.io/abc",
       "components":[{"name":"Claude Code"},{"name":"claude.ai"}]},
      {"id":"inc-minor","name":"Slow console","status":"resolved","impact":"minor",
       "created_at":"2027-01-14T12:00:00Z","resolved_at":"2027-01-14T12:30:00Z",
       "components":[{"name":"Claude Code"}]},
      {"id":"inc-critical","name":"Elevated errors across all models","status":"investigating",
       "impact":"critical","created_at":"2027-01-15T07:00:00Z","started_at":null,"resolved_at":null,
       "components":[]},
      {"id":"inc-cowork","name":"Cowork degraded on Windows","status":"resolved","impact":"major",
       "created_at":"2027-01-13T12:00:00Z","resolved_at":"2027-01-13T14:00:00Z",
       "components":[{"name":"Claude Cowork"}]}
    ]}
    """#

    static let openIncident = #"""
    {"incidents":[{"id":"inc-1","name":"Elevated errors on Claude Code","status":"investigating",
      "impact":"major","created_at":"2027-01-15T06:00:00Z","started_at":"2027-01-15T06:00:00Z",
      "resolved_at":null,"components":[{"name":"Claude Code"}]}]}
    """#

    static let resolvedIncident = #"""
    {"incidents":[{"id":"inc-1","name":"Elevated errors on Claude Code","status":"resolved",
      "impact":"major","created_at":"2027-01-15T06:00:00Z","started_at":"2027-01-15T06:00:00Z",
      "resolved_at":"2027-01-15T07:30:00Z","components":[{"name":"Claude Code"}]}]}
    """#

    private let claudePage = StatusPage(
        name: "claude", vendorId: .claude,
        incidentsURL: URL(string: "https://example.invalid/api/v2/incidents.json")!,
        pageURL: URL(string: "https://status.example.invalid")!,
        relevance: .components(["Claude Code", "Claude API (api.anthropic.com)", "claude.ai"], includeUnscoped: true))

    private let openAIPage = StatusPage(
        name: "openai", vendorId: .openai,
        incidentsURL: URL(string: "https://example.invalid/openai")!,
        pageURL: URL(string: "https://status.openai.example.invalid")!,
        relevance: .nameMentions(["codex"]))

    @Test("only major and critical incidents on tracked components are recorded")
    func filtersByImpactAndComponent() throws {
        let incidents = try #require(StatusIncidentWatcher.parse(Data(Self.incidents.utf8)))
        #expect(incidents.count == 4)
        let events = StatusIncidentWatcher.events(for: claudePage, incidents: incidents, now: now)
        #expect(events.map(\.id) == [
            "outage_started|claude|claude|inc-major",
            "outage_resolved|claude|claude|inc-major",
            // Unscoped, still open: started only.
            "outage_started|claude|claude|inc-critical",
        ])
    }

    @Test("start and recovery events carry the vendor's own times, impact and link")
    func eventWording() throws {
        let incidents = try #require(StatusIncidentWatcher.parse(Data(Self.incidents.utf8)))
        let events = StatusIncidentWatcher.events(for: claudePage, incidents: incidents, now: now)

        let started = events[0]
        #expect(started.title == "Outage: Elevated errors on Claude Code")
        #expect(started.detail == "Major impact · Claude Code, claude.ai")
        // `started_at`, not the later `created_at`.
        #expect(started.occurredAt == ResetTrackerWatcher.parseDate("2027-01-14T10:00:00.000Z"))
        #expect(started.url == URL(string: "https://stspg.io/abc"))
        #expect(started.source == .statusPage(name: "claude"))
        #expect(started.isSurfaced)

        let resolved = events[1]
        #expect(resolved.title == "Resolved: Elevated errors on Claude Code")
        #expect(resolved.detail == "Resolved after 1h 30m")
        #expect(resolved.occurredAt == ResetTrackerWatcher.parseDate("2027-01-14T11:30:00.000Z"))

        // No shortlink: a link built from the page and the incident id.
        let critical = events[2]
        #expect(critical.detail == "Critical impact")
        #expect(critical.url == URL(string: "https://status.example.invalid/incidents/inc-critical"))
        #expect(critical.occurredAt == ResetTrackerWatcher.parseDate("2027-01-15T07:00:00Z"))
    }

    @Test("a page without components counts an incident naming the product, or a critical one")
    func nameRelevance() {
        func incident(_ name: String, _ impact: StatusIncident.Impact) -> StatusIncident {
            StatusIncident(id: name, name: name, impact: impact, status: "resolved",
                           startedAt: now, resolvedAt: now, components: [], shortlink: nil)
        }
        #expect(StatusIncidentWatcher.isRelevant(incident("Issues with Codex", .major), to: openAIPage))
        #expect(!StatusIncidentWatcher.isRelevant(incident("Issues with login and ads", .major), to: openAIPage))
        #expect(StatusIncidentWatcher.isRelevant(incident("Everything is down", .critical), to: openAIPage))
    }

    @Test("a component-scoped page ignores unscoped incidents unless told otherwise")
    func unscopedPolicy() {
        let copilot = StatusPage(
            name: "github", vendorId: .copilot,
            incidentsURL: URL(string: "https://example.invalid/g")!, pageURL: URL(string: "https://example.invalid")!,
            relevance: .components(["Copilot"], includeUnscoped: false))
        let unscoped = StatusIncident(id: "x", name: "Incident with GitHub.com", impact: .critical,
                                      status: "resolved", startedAt: now, resolvedAt: now,
                                      components: [], shortlink: nil)
        #expect(!StatusIncidentWatcher.isRelevant(unscoped, to: copilot))
        #expect(StatusIncidentWatcher.isRelevant(unscoped, to: claudePage))
    }

    @Test("a page for a vendor the user does not have is never fetched")
    func vendorFiltering() async {
        let log = FetchLog()
        let watcher = StatusIncidentWatcher(pages: [claudePage, openAIPage]) { page in
            log.hit(page.name)
            return Data(Self.incidents.utf8)
        }
        let pending = await watcher.prepare(vendors: [.claude], now: now)
        #expect(pending.fetched)
        #expect(log.count("openai") == 0)
        #expect(pending.events.allSatisfy { $0.vendorId == .claude })
    }

    @Test("an unreadable payload is a failed read")
    func unreadable() async {
        #expect(StatusIncidentWatcher.parse(Data("<html>".utf8)) == nil)
        let watcher = StatusIncidentWatcher(pages: [claudePage]) { _ in Data("<html>".utf8) }
        let pending = await watcher.prepare(vendors: [.claude], now: now)
        #expect(!pending.fetched)
        #expect(pending.events.isEmpty)
    }

    @Test("the production pages are the three official ones")
    func productionPages() {
        #expect(StatusPage.all.map(\.vendorId) == [.claude, .openai, .copilot])
        #expect(StatusPage.all.allSatisfy { $0.incidentsURL.path == "/api/v2/incidents.json" })
        #expect(AIEventSource.statusPage(name: "claude").label == "From status.claude.com")
    }
}
